import Foundation

/// Loads the favicon of each bank from the bank's **own** website (never a third-party favicon
/// service, which would learn which banks the user has) and caches it on disk.
///
/// Requests use an ephemeral session without cookies or cache, so the bank's public website
/// learns nothing beyond an anonymous icon fetch. Failure is not an error for the UI: it falls
/// back to the monogram badge, so `icon(for:)` returns `nil` and logs the reason.
///
/// Every request (page, icon, each redirect) must stay on the homepage's registrable domain,
/// and bodies are read with a hard byte cap. The cache holds only these public favicons, as
/// plain files in the app's caches directory: nothing bank- or user-specific, so it stays
/// outside the encrypted database on purpose.
public actor BankIconStore {
    /// Icons are refreshed after this age; a stale icon is still used if the refresh fails.
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let maximumIconBytes = 1 << 20
    static let maximumPageBytes = 4 << 20

    private let cacheDirectory: URL
    private let session: URLSession
    private var inFlight: [ConnectorID: Task<Data?, Never>] = [:]

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    /// `~/Library/Caches/<container>/BankIcons`
    public static func defaultCacheDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BankIcons", isDirectory: true)
    }

    /// The bank's public homepage. `nil` for connectors without a website (mock).
    public static func homepage(for connector: ConnectorID) -> URL? {
        switch connector {
        case .ing: URL(string: "https://www.ing.de/")
        case .dkb: URL(string: "https://www.dkb.de/")
        case .tradeRepublic: URL(string: "https://traderepublic.com/")
        case .c24: URL(string: "https://www.c24.de/")
        case .easybank: URL(string: "https://www.easybank.de/")
        case .n26: URL(string: "https://n26.com/")
        case .paypal: URL(string: "https://www.paypal.com/")
        // v12: no single homepage behind YAXI (and no extra host for YAXI's logos).
        case .mock, .manual, .yaxi: nil
        }
    }

    /// Image data (PNG, ICO, SVG is skipped) or `nil` if none could be loaded.
    public func icon(for connector: ConnectorID) async -> Data? {
        let file = cacheDirectory.appendingPathComponent("\(connector.rawValue).icon")
        let cached = try? Data(contentsOf: file)
        if let cached, let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.maximumAge {
            return cached
        }
        if let running = inFlight[connector] { return await running.value }
        let task = Task { await self.download(connector) }
        inFlight[connector] = task
        let fresh = await task.value
        inFlight[connector] = nil
        guard let fresh else { return cached }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try fresh.write(to: file, options: .atomic)
        } catch {
            Log.core.error("Bank-Symbol nicht gespeichert: \(error.localizedDescription, privacy: .public)")
        }
        return fresh
    }

    private func download(_ connector: ConnectorID) async -> Data? {
        guard let homepage = Self.homepage(for: connector) else { return nil }
        guard let site = Self.registrableDomain(of: homepage) else { return nil }
        var candidates: [URL] = []
        if let (page, response) = await fetch(homepage, site: site, limit: Self.maximumPageBytes),
           let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) {
            // Redirects (easybank.de → /easybank-de) change the base for relative links.
            candidates = Self.iconCandidates(inHTML: html, base: response.url ?? homepage, site: site)
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: homepage)?.absoluteURL, !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        for candidate in candidates {
            if let (data, response) = await fetch(candidate, site: site, limit: Self.maximumIconBytes),
               Self.looksLikeImage(data, mimeType: response.mimeType) {
                return data
            }
        }
        Log.core.notice("Kein Bank-Symbol für \(connector.rawValue, privacy: .public)")
        return nil
    }

    /// GET restricted to `site` (also across redirects), body streamed and capped at `limit` bytes.
    private func fetch(_ url: URL, site: String, limit: Int) async -> (Data, URLResponse)? {
        guard Self.isAllowed(url, site: site) else { return nil }
        do {
            let (bytes, response) = try await session.bytes(from: url, delegate: SameSiteRedirectGuard(site: site))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url.map({ Self.isAllowed($0, site: site) }) ?? true,
                  http.expectedContentLength <= Int64(limit) else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < limit else {
                    bytes.task.cancel()
                    return nil
                }
                data.append(byte)
            }
            return (data, response)
        } catch {
            Log.core.debug("Bank-Symbol: \(url.host() ?? "", privacy: .public) nicht erreichbar")
            return nil
        }
    }

    // MARK: - Same-site rule (internal for tests)

    /// The last two host labels (`www.ing.de` → `ing.de`). Enough for the fixed homepages, which
    /// all sit directly under a one-label public suffix (`.de`, `.com`).
    static func registrableDomain(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        return labels.suffix(2).joined(separator: ".")
    }

    /// HTTPS on `site` itself or one of its subdomains.
    static func isAllowed(_ url: URL, site: String) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == site || host.hasSuffix("." + site)
    }

    // MARK: - Parsing (internal for tests)

    /// `<link rel="… icon …" href="…">` targets, best first: apple-touch-icon, then by declared
    /// size (largest first), SVG last (NSImage cannot draw every SVG favicon).
    /// Links off `site` (the homepage's registrable domain) are dropped; `nil` = derive from `base`.
    static func iconCandidates(inHTML html: String, base: URL, site: String? = nil) -> [URL] {
        guard let site = site ?? registrableDomain(of: base) else { return [] }
        struct Candidate { let url: URL; let rank: Int }
        var result: [Candidate] = []
        for tag in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let attributes = Self.attributes(String(tag.output))
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"),
                  let href = attributes["href"], !href.hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, isAllowed(url, site: site) else { continue }
            let size = attributes["sizes"].flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 16
            var rank = min(size, 512)
            if rel.contains("apple-touch-icon") { rank += 1_000 }
            if url.pathExtension.lowercased() == "svg" || attributes["type"]?.contains("svg") == true { rank -= 2_000 }
            result.append(Candidate(url: url, rank: rank))
        }
        var seen = Set<URL>()
        return result.sorted { $0.rank > $1.rank }.map(\.url).filter { seen.insert($0).inserted }
    }

    private static func attributes(_ tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in tag.matches(of: /([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/) {
            attributes[String(match.output.1).lowercased()] = String(match.output.2 ?? match.output.3 ?? "")
        }
        return attributes
    }

    static func looksLikeImage(_ data: Data, mimeType: String?) -> Bool {
        if let mimeType, mimeType.hasPrefix("text/") { return false }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let ico: [UInt8] = [0x00, 0x00, 0x01, 0x00]
        let head = Array(data.prefix(4))
        return head == png || head == ico || data.starts(with: [0xFF, 0xD8]) || data.starts(with: Array("GIF8".utf8))
    }
}

/// Refuses redirects that leave the bank's registrable domain (or HTTPS).
private final class SameSiteRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let site: String

    init(site: String) {
        self.site = site
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, BankIconStore.isAllowed(url, site: site) else {
            Log.core.notice("Bank-Symbol: Weiterleitung auf fremde Domain abgelehnt")
            return nil
        }
        return request
    }
}
