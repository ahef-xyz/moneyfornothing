import CryptoKit
import Foundation
import MFNCore
import Security
import Synchronization

/// Sends one HTTPS request (REST login, session refresh).
public protocol TRHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Opens the one WebSocket of a connector.
public protocol TRWebSocketTransport: Sendable {
    func open(_ request: URLRequest) async throws -> any TRWebSocketConnection
}

/// A text WebSocket. `receive` throws once the connection is gone.
public protocol TRWebSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// Pauses between reconnect attempts. Injected so tests never sleep.
public protocol TRSleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TRTaskSleeper: TRSleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Production transport: one ephemeral `URLSession` (no shared cookies, no cache) for REST and
/// WebSocket, with optional public-key pinning for `api.traderepublic.com`.
///
/// A refused pin makes URLSession fail the task with `URLError.cancelled`, which would look like
/// a user cancel. The delegate records the host, and the transport reports the failure as
/// `ConnectorError.formatChanged(detail: pinMismatchDetail)` instead.
public final class TRURLSessionTransport: TRHTTPTransport, TRWebSocketTransport {
    static let pinMismatchDetail = "Trade-Republic-Zertifikat passt nicht zum Pin (certificate pin mismatch)"

    private let session: URLSession
    private let delegate: PinningDelegate

    /// - Parameter pinnedKeyHashes: base64 of SHA-256 over the bytes `SecKeyCopyExternalRepresentation`
    ///   returns for the public key of any certificate in the chain (`SecCertificateCopyKey`). That is
    ///   **not** the SPKI hash (`openssl … pubkey -outform der | sha256`): for RSA it is the PKCS#1
    ///   `RSAPublicKey` DER, for EC the raw ANSI X9.63 point `04‖X‖Y`, both without the
    ///   `SubjectPublicKeyInfo` algorithm header. Empty = the default pins
    ///   (`TradeRepublicConnector.pinnedKeyHashes`): there is no unpinned mode (fail closed).
    public init(pinnedKeyHashes: Set<String> = TradeRepublicConnector.pinnedKeyHashes, timeout: TimeInterval = 30) {
        let pinnedKeyHashes = pinnedKeyHashes.isEmpty ? TradeRepublicConnector.pinnedKeyHashes : pinnedKeyHashes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let delegate = PinningDelegate(pins: pinnedKeyHashes)
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw translated(error, host: request.url?.host())
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func open(_ request: URLRequest) async throws -> any TRWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return Connection(task: task, host: request.url?.host(), transport: self)
    }

    func translated(_ error: any Error, host: String?) -> any Error {
        Self.translated(error, pinFailed: host.map(delegate.pinFailed) ?? false, taskCancelled: Task.isCancelled)
    }

    /// `URLError.cancelled` without a cancelled task after a recorded pin failure → pin mismatch.
    static func translated(_ error: any Error, pinFailed: Bool, taskCancelled: Bool) -> any Error {
        guard let urlError = error as? URLError, urlError.code == .cancelled, !taskCancelled, pinFailed else { return error }
        return ConnectorError.formatChanged(detail: pinMismatchDetail)
    }

    private final class Connection: TRWebSocketConnection {
        let task: URLSessionWebSocketTask
        let host: String?
        let transport: TRURLSessionTransport

        init(task: URLSessionWebSocketTask, host: String?, transport: TRURLSessionTransport) {
            self.task = task
            self.host = host
            self.transport = transport
        }

        func send(_ text: String) async throws {
            do { try await task.send(.string(text)) } catch { throw transport.translated(error, host: host) }
        }

        func receive() async throws -> String {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { throw transport.translated(error, host: host) }
            switch message {
            case let .string(text): return text
            case let .data(data): return String(decoding: data, as: UTF8.self)
            @unknown default: throw URLError(.cannotParseResponse)
            }
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    private final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
        let pins: Set<String>
        /// Hosts whose last server trust failed the pin check (cleared by the next good one).
        private let failedHosts = Mutex<Set<String>>([])

        init(pins: Set<String>) {
            self.pins = pins
        }

        func pinFailed(host: String) -> Bool {
            failedHosts.withLock { $0.contains(host.lowercased()) }
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            let host = challenge.protectionSpace.host.lowercased()
            // System trust refused: default handling fails the task with a certificate URLError.
            guard SecTrustEvaluateWithError(trust, nil) else { return (.performDefaultHandling, nil) }
            guard !pins.isEmpty else { return (.performDefaultHandling, nil) }
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            for certificate in chain {
                guard let key = SecCertificateCopyKey(certificate),
                      let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { continue }
                if pins.contains(Data(SHA256.hash(data: data)).base64EncodedString()) {
                    _ = failedHosts.withLock { $0.remove(host) }
                    return (.useCredential, URLCredential(trust: trust))
                }
            }
            failedHosts.withLock { _ = $0.insert(host) }
            TRLog.log.fault("Zertifikats-Pinning fehlgeschlagen für \(host, privacy: .public)")
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}

enum TRLog {
    static let log = Log.logger("traderepublic")
}
