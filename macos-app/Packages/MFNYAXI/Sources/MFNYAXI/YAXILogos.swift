import Foundation
import MFNCore

/// Bank logos from YAXI's logo service (`https://logos.yaxi.tech/banks/<logoId>-64.png`, documented
/// under "Bank logos" at docs.yaxi.tech/integrations.html). Only for banks the user reaches over
/// YAXI, which knows these banks anyway; approved by the human on 2026-11-25.
///
/// Like `BankIconStore`: ephemeral session without cookies, only this host (also on redirects),
/// a hard byte cap, PNG only, cached on disk as plain public files and refreshed after 30 days.
/// A failure is no error: the UI keeps its monogram.
public actor YAXILogos {
    public static let host = "logos.yaxi.tech"
    static let maximumBytes = 512 * 1024
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private let cacheDirectory: URL
    private let session: URLSession
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    /// The URL of a logo; `nil` for an ID that is not a plain file name.
    static func url(for logoID: String) -> URL? {
        guard isValid(logoID) else { return nil }
        return URL(string: "https://\(host)/banks/\(logoID)-64.png")
    }

    static func isValid(_ logoID: String) -> Bool {
        !logoID.isEmpty && logoID.count <= 80 && logoID.first != "." && logoID.first != "_"
            && logoID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// PNG bytes of the logo, from the cache or the service. `keep`: written to the disk cache (only
    /// for banks the user connected; a search hit stays in memory, so the cache does not show which
    /// banks were looked at).
    public func logo(for logoID: String, keep: Bool) async -> Data? {
        guard let url = Self.url(for: logoID) else { return nil }
        let file = file(for: logoID)
        let cached = try? Data(contentsOf: file)
        if let cached, let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.maximumAge {
            return cached
        }
        if let running = inFlight[logoID] { return await running.value }
        let task = Task { await self.download(url) }
        inFlight[logoID] = task
        let fresh = await task.value
        inFlight[logoID] = nil
        guard let fresh else { return cached }
        guard keep else { return fresh }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try fresh.write(to: file, options: .atomic)
        } catch {
            YAXIMapper.log.error("YAXI-Logo nicht gespeichert")
        }
        return fresh
    }

    /// "Bank entfernen": the logo of that bank leaves the cache.
    public func remove(_ logoID: String) {
        Self.remove(logoID, cacheDirectory: cacheDirectory)
    }

    /// File-only variant of `remove(_:)`: no instance, no URLSession.
    public static func remove(_ logoID: String, cacheDirectory: URL) {
        guard isValid(logoID) else { return }
        try? FileManager.default.removeItem(at: file(for: logoID, in: cacheDirectory))
    }

    private func file(for logoID: String) -> URL {
        Self.file(for: logoID, in: cacheDirectory)
    }

    private static func file(for logoID: String, in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent("yaxi-\(logoID).png")
    }

    private func download(_ url: URL) async -> Data? {
        do {
            // One request, checked after it: a logo is a few kB, the cap only guards against a bad answer.
            let (data, response) = try await session.data(from: url, delegate: SameHostRedirectGuard())
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.host() == Self.host, data.count <= Self.maximumBytes, Self.isPNG(data) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

/// Redirects only within the logo host.
private final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme == "https" && request.url?.host() == YAXILogos.host ? request : nil
    }
}
