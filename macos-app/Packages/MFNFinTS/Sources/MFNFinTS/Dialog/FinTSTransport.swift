import CryptoKit
import Foundation
import MFNCore
import Security

/// Sends one FinTS message and returns the answer (raw bytes, base64 handled by the transport).
public protocol FinTSTransport: Sendable {
    func exchange(_ message: [UInt8]) async throws(ConnectorError) -> [UInt8]
}

/// HTTPS POST with base64 body (FinTS 3.0 PIN/TAN). Optional public-key pinning.
public final class HTTPSFinTSTransport: NSObject, FinTSTransport, URLSessionDelegate {
    private let url: URL
    /// SHA-256 (base64) of the DER public key of any certificate in the chain. Empty = system
    /// trust only. ING/DKB pass their pins (`INGConnector.pinnedKeyHashes`, `DKBConnector.pinnedKeyHashes`).
    private let pinnedKeyHashes: Set<String>
    private let session: URLSession

    private static let log = Log.logger("fints")

    public init(url: URL, pinnedKeyHashes: Set<String> = [], timeout: TimeInterval = 60) {
        self.url = url
        self.pinnedKeyHashes = pinnedKeyHashes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: configuration, delegate: PinningDelegate(pins: pinnedKeyHashes), delegateQueue: delegateQueue)
        super.init()
    }

    public func exchange(_ message: [UInt8]) async throws(ConnectorError) -> [UInt8] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(message).base64EncodedData()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch {
            Self.log.error("FinTS-Verbindung fehlgeschlagen: \(String(describing: type(of: error)), privacy: .public)")
            throw .bankUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw .bankUnavailable }
        switch http.statusCode {
        case 200: break
        case 429: throw .rateLimited(retryAfter: Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        default: throw .bankUnavailable
        }
        let compact = data.filter { !Set([0x0A, 0x0D, 0x20]).contains($0) }
        guard let decoded = Data(base64Encoded: compact) else {
            throw .formatChanged(detail: "FinTS-Antwort ist kein Base64")
        }
        return [UInt8](decoded)
    }

    private final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
        let pins: Set<String>

        init(pins: Set<String>) {
            self.pins = pins
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
            guard !pins.isEmpty else { return (.performDefaultHandling, nil) }
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            for certificate in chain {
                guard let key = SecCertificateCopyKey(certificate),
                      let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { continue }
                if pins.contains(Data(SHA256.hash(data: data)).base64EncodedString()) {
                    return (.useCredential, URLCredential(trust: trust))
                }
            }
            Log.logger("fints").fault("Zertifikats-Pinning fehlgeschlagen für \(challenge.protectionSpace.host, privacy: .public)")
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Test transport: answers from a script, records every request. Never talks to a bank.
public actor ScriptedFinTSTransport: FinTSTransport {
    public typealias Responder = @Sendable (_ request: [FinTSSegment], _ index: Int) throws(ConnectorError) -> [UInt8]

    private let responder: Responder
    public private(set) var requests: [[FinTSSegment]] = []

    /// Answers with `responses` in order (raw FinTS or base64, as stored in fixtures).
    public init(responses: [Data]) {
        let decoded = responses.map(Self.decode)
        self.responder = { _, index throws(ConnectorError) in
            guard decoded.indices.contains(index) else { throw ConnectorError.bankUnavailable }
            return decoded[index]
        }
    }

    /// Answers by inspecting the request (e.g. reply to HKEND with an end confirmation).
    public init(responder: @escaping Responder) {
        self.responder = responder
    }

    public func exchange(_ message: [UInt8]) async throws(ConnectorError) -> [UInt8] {
        let segments = Self.flatten(message)
        requests.append(segments)
        return try responder(segments, requests.count - 1)
    }

    /// All request segment types per message, e.g. `[["HKIDN","HKVVB","HKTAN"], ["HKSAL"], ["HKEND"]]`.
    public var requestTypes: [[String]] {
        requests.map { $0.map(\.type).filter { !$0.hasPrefix("HN") } }
    }

    static func flatten(_ message: [UInt8]) -> [FinTSSegment] {
        guard let response = try? FinTSResponse(bytes: message) else { return [] }
        return response.segments
    }

    static func decode(_ data: Data) -> [UInt8] {
        let compact = data.filter { !Set([0x0A, 0x0D, 0x20]).contains($0) }
        if !data.starts(with: Data("HNHBK".utf8)), let decoded = Data(base64Encoded: compact) {
            return [UInt8](decoded)
        }
        return [UInt8](data)
    }
}
