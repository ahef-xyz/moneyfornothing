import Foundation
import MFNCore

/// The one WebSocket to `wss://api.traderepublic.com` of a connector.
///
/// Unverified against recordings (the HAR in `Fixtures/TradeRepublic` has no WebSocket frames):
/// message format from pytr. Used only for cash balance, depot positions and transfer details.
///
/// - Handshake `connect 35 {…}` → `connected`, web-session cookies in the upgrade request.
/// - Multiplexes subscriptions over the socket: `sub <n> {json}`; answers `<n> A <json>`,
///   deltas `<n> D <delta>` (applied to the last full answer), `<n> C` complete, `<n> E <json>` error.
/// - `request` waits for the first (full or delta-patched) answer, then sends `unsub <n>`.
/// - Lost connection: reconnect with exponential backoff, at most `maxAttempts` tries per request.
/// - Cancelled task: the waiting request ends at once with `cancelled`, no reconnect.
/// - Never opens a second socket while one is open or opening.
actor TRWebSocketClient {
    struct Configuration: Sendable {
        var url: URL
        var connectMessage: String
        var requestTimeout: TimeInterval = 30
        var maxAttempts = 3
        var backoffSeconds: TimeInterval = 1
    }

    /// Returns the `Cookie` header of the web session for the upgrade request.
    typealias SessionProvider = @Sendable (URL) async throws(ConnectorError) -> String

    private enum Failure: Error {
        case connectionLost
        case connector(ConnectorError)
    }

    private let configuration: Configuration
    private let transport: any TRWebSocketTransport
    private let sleeper: any TRSleeper
    private let sessionProvider: SessionProvider

    private var connection: (any TRWebSocketConnection)?
    private var connecting: Task<any TRWebSocketConnection, any Error>?
    private var generation = 0
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<String, any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var lastFull: [Int: String] = [:]
    private var receiveTask: Task<Void, Never>?

    init(configuration: Configuration, transport: any TRWebSocketTransport, sleeper: any TRSleeper, sessionProvider: @escaping SessionProvider) {
        self.configuration = configuration
        self.transport = transport
        self.sleeper = sleeper
        self.sessionProvider = sessionProvider
    }

    deinit {
        receiveTask?.cancel()
        connection?.close()
    }

    /// Subscribes, returns the first answer as JSON and unsubscribes.
    func request(_ payload: JSONValue) async throws(ConnectorError) -> JSONValue {
        var attempt = 0
        while true {
            do {
                let text = try await requestOnce(payload)
                guard let json = JSONValue.parse(text) else {
                    throw ConnectorError.formatChanged(detail: "Trade-Republic-Antwort ist kein JSON")
                }
                return json
            } catch let error as ConnectorError {
                throw error
            } catch Failure.connector(let error) {
                throw error
            } catch is CancellationError {
                throw .cancelled
            } catch {
                if Task.isCancelled { throw .cancelled }
                attempt += 1
                disconnect()
                guard attempt < configuration.maxAttempts else {
                    TRLog.log.error("Trade-Republic-WebSocket: Verbindung nach \(attempt, privacy: .public) Versuchen verloren")
                    throw .bankUnavailable
                }
                let delay = configuration.backoffSeconds * pow(2, Double(attempt - 1))
                TRLog.log.info("Trade-Republic-WebSocket getrennt, neuer Versuch in \(delay, privacy: .public) s")
                do { try await sleeper.sleep(seconds: delay) } catch { throw .cancelled }
            }
        }
    }

    /// Closes the socket (end of sync).
    func close() {
        disconnect()
    }

    // MARK: - One attempt

    private func requestOnce(_ payload: JSONValue) async throws -> String {
        try Task.checkCancellation()
        let connection = try await connected()
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        let message = "sub \(id) \(payload.text)"
        TRLog.log.debug("TR → sub \(id, privacy: .public) \(payload["type"]?.string ?? "?", privacy: .public)")

        let answer: String
        do {
            answer = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    waiting[id] = continuation
                    let timeout = configuration.requestTimeout
                    timeouts[id] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(timeout))
                        guard !Task.isCancelled else { return }
                        await self?.resolve(id, with: .failure(Failure.connectionLost))
                    }
                    Task { [weak self] in
                        do {
                            try await connection.send(message)
                        } catch let error as ConnectorError {
                            await self?.resolve(id, with: .failure(Failure.connector(error)))
                        } catch {
                            await self?.resolve(id, with: .failure(Failure.connectionLost))
                        }
                    }
                }
            } onCancel: {
                // Runs on the actor after the continuation is stored (the body above is synchronous
                // on the actor). `resolve` removes it first, so it is resumed exactly once.
                Task { [weak self] in await self?.resolve(id, with: .failure(CancellationError())) }
            }
        } catch is CancellationError {
            await unsubscribe(id, on: connection)
            throw CancellationError()
        }
        await unsubscribe(id, on: connection)
        return answer
    }

    private func unsubscribe(_ id: Int, on connection: any TRWebSocketConnection) async {
        lastFull[id] = nil
        // Best effort: a failed unsub surfaces with the next request.
        try? await connection.send("unsub \(id)")
    }

    // MARK: - Connection

    private func connected() async throws -> any TRWebSocketConnection {
        if let connection { return connection }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.openConnection() }
        connecting = task
        defer { connecting = nil }
        let connection = try await task.value
        return connection
    }

    private func openConnection() async throws -> any TRWebSocketConnection {
        let cookieHeader: String
        do {
            cookieHeader = try await sessionProvider(configuration.url)
        } catch {
            throw Failure.connector(error)
        }
        var request = URLRequest(url: configuration.url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let connection: any TRWebSocketConnection
        do {
            connection = try await transport.open(request)
            try await connection.send(configuration.connectMessage)
            let greeting = try await connection.receive()
            guard greeting.hasPrefix("connected") else {
                connection.close()
                throw Failure.connector(.formatChanged(detail: "Trade-Republic-WebSocket ohne 'connected'"))
            }
        } catch let failure as Failure {
            throw failure
        } catch let error as ConnectorError {
            // e.g. certificate pin mismatch from the transport: not worth a reconnect.
            throw Failure.connector(error)
        } catch {
            throw Failure.connectionLost
        }
        generation += 1
        let current = generation
        self.connection = connection
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    await self?.handle(message)
                }
            } catch {
                await self?.connectionDropped(generation: current)
            }
        }
        TRLog.log.info("Trade-Republic-WebSocket verbunden")
        return connection
    }

    private func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.close()
        connection = nil
        lastFull.removeAll()
        failAll(Failure.connectionLost)
    }

    private func connectionDropped(generation dropped: Int) {
        guard dropped == generation, connection != nil else { return }
        connection = nil
        receiveTask = nil
        lastFull.removeAll()
        failAll(Failure.connectionLost)
    }

    private func failAll(_ error: any Error) {
        for id in Array(waiting.keys) { resolve(id, with: .failure(error)) }
    }

    // MARK: - Messages

    private func handle(_ message: String) {
        if message.hasPrefix("connected") || message == "echo" { return }
        let parts = message.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let id = Int(parts[0]) else {
            TRLog.log.debug("TR ← unbekannte Nachricht \(message, privacy: .private)")
            return
        }
        let payload = parts.count > 2 ? String(parts[2]) : ""
        TRLog.log.debug("TR ← \(id, privacy: .public) \(parts[1], privacy: .public) \(payload, privacy: .private)")
        switch parts[1] {
        case "A":
            lastFull[id] = payload
            resolve(id, with: .success(payload))
        case "D":
            guard let previous = lastFull[id] else {
                resolve(id, with: .failure(Failure.connector(.formatChanged(detail: "Trade-Republic-Delta ohne Vollstand"))))
                return
            }
            do {
                let full = try TRDelta.apply(payload, to: previous)
                lastFull[id] = full
                resolve(id, with: .success(full))
            } catch {
                resolve(id, with: .failure(Failure.connector(error)))
            }
        case "C":
            resolve(id, with: .failure(Failure.connector(.formatChanged(detail: "Trade-Republic-Abo ohne Antwort beendet"))))
        case "E":
            resolve(id, with: .failure(Failure.connector(Self.error(from: payload))))
        default:
            TRLog.log.debug("TR ← unbekannter Nachrichtentyp \(parts[1], privacy: .public)")
        }
    }

    private func resolve(_ id: Int, with result: Result<String, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    static func error(from payload: String) -> ConnectorError {
        let json = JSONValue.parse(payload)
        let errors = json?["errors"]?.array ?? []
        let codes = errors.compactMap { $0["errorCode"]?.string } + [json?["errorCode"]?.string, json?["message"]?.string].compactMap(\.self)
        let joined = codes.joined(separator: ",").uppercased()
        if joined.contains("AUTH") || joined.contains("UNAUTHORIZED") || joined.contains("SESSION") {
            return .sessionExpired
        }
        if joined.contains("TOO_MANY") || joined.contains("RATE") {
            let retry = errors.first?["meta"]?["nextAttemptInSeconds"]?.int
            return .rateLimited(retryAfter: TimeInterval(retry ?? 60))
        }
        let code = codes.first.map { String($0.prefix(40)).filter { $0.isLetter || $0.isNumber || $0 == "_" } } ?? "unbekannt"
        return .formatChanged(detail: "Trade-Republic-Abo abgelehnt (\(code))")
    }
}
