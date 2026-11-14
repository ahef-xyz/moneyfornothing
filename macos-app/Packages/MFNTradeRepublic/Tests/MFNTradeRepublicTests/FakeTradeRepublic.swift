import Foundation
import MFNCore
import Synchronization
@testable import MFNTradeRepublic

// MARK: - Fake WebSocket + REST server (never talks to Trade Republic)

enum Reply: Sendable {
    case answer(String)
    case delta(String)
    case error(String)
    case complete
    /// Closes the socket without answering.
    case drop
}

/// Plays Trade Republic: REST login/session endpoints and a WebSocket that answers `sub` messages.
final class FakeTRServer: TRHTTPTransport, TRWebSocketTransport, Sendable {
    typealias HTTPHandler = @Sendable (_ method: String, _ path: String, _ query: [String: String], _ headers: [String: String]) -> (Int, [String: String], String)
    typealias SubHandler = @Sendable (_ payload: JSONValue, _ connection: Int) -> [Reply]

    struct State {
        var failOpens = 0
        var opened = 0
        var openCookies: [String] = []
        var httpPaths: [String] = []
        var httpRequests: [URLRequest] = []
        var versionRequests = 0
        var subs: [JSONValue] = []
        var unsubs: [Int] = []
        var connections: [FakeConnection] = []
    }

    let http: HTTPHandler
    let sub: SubHandler
    let state = Mutex(State())

    init(failOpens: Int = 0, http: @escaping HTTPHandler, sub: @escaping SubHandler) {
        self.http = http
        self.sub = sub
        state.withLock { $0.failOpens = failOpens }
    }

    /// Served for `app.traderepublic.com/app-version.txt` (public, no session).
    static let webAppVersion = "2.9999.1"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host() == "app.traderepublic.com", request.url?.path == "/app-version.txt" {
            state.withLock { $0.versionRequests += 1 }
            let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) ?? HTTPURLResponse()
            return (Data((Self.webAppVersion + "\n").utf8), response)
        }
        let path = request.url?.path ?? ""
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        state.withLock {
            $0.httpPaths.append("\(request.httpMethod ?? "GET") \(path)")
            $0.httpRequests.append(request)
        }
        let (status, headers, text) = http(request.httpMethod ?? "GET", path, query, request.allHTTPHeaderFields ?? [:])
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) ?? HTTPURLResponse()
        return (Data(text.utf8), response)
    }

    func open(_ request: URLRequest) async throws -> any TRWebSocketConnection {
        let (fail, index) = state.withLock { state -> (Bool, Int) in
            state.openCookies.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
            if state.failOpens > 0 {
                state.failOpens -= 1
                return (true, 0)
            }
            state.opened += 1
            return (false, state.opened)
        }
        if fail { throw URLError(.cannotConnectToHost) }
        let connection = FakeConnection(server: self, index: index)
        state.withLock { $0.connections.append(connection) }
        return connection
    }

    var subs: [JSONValue] { state.withLock { $0.subs } }
    var subTypes: [String] { subs.compactMap { $0["type"]?.string } }
    var opened: Int { state.withLock { $0.opened } }
    var httpPaths: [String] { state.withLock { $0.httpPaths } }
    var httpRequests: [URLRequest] { state.withLock { $0.httpRequests } }
    var versionRequests: Int { state.withLock { $0.versionRequests } }
    var openCookies: [String] { state.withLock { $0.openCookies } }
    var unsubs: [Int] { state.withLock { $0.unsubs } }

    fileprivate func handle(_ text: String, on connection: FakeConnection) {
        if text.hasPrefix("connect 35 ") {
            connection.push("connected")
            return
        }
        let parts = text.split(separator: " ", maxSplits: 2)
        if parts.first == "unsub", parts.count == 2, let id = Int(parts[1]) {
            state.withLock { $0.unsubs.append(id) }
            return
        }
        guard parts.count == 3, parts[0] == "sub", let id = Int(parts[1]), let payload = JSONValue.parse(String(parts[2])) else { return }
        state.withLock { $0.subs.append(payload) }
        for reply in sub(payload, connection.index) {
            switch reply {
            case let .answer(json): connection.push("\(id) A \(json)")
            case let .delta(delta): connection.push("\(id) D \(delta)")
            case let .error(json): connection.push("\(id) E \(json)")
            case .complete: connection.push("\(id) C")
            case .drop: connection.close()
            }
        }
    }
}

final class FakeConnection: TRWebSocketConnection {
    struct Mailbox {
        var queue: [String] = []
        var waiter: CheckedContinuation<String, any Error>?
        var closed = false
    }

    let server: FakeTRServer
    let index: Int
    private let mailbox = Mutex(Mailbox())

    init(server: FakeTRServer, index: Int) {
        self.server = server
        self.index = index
    }

    func send(_ text: String) async throws {
        if mailbox.withLock({ $0.closed }) { throw URLError(.networkConnectionLost) }
        server.handle(text, on: self)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let result = mailbox.withLock { box -> Result<String, any Error>? in
                if !box.queue.isEmpty { return .success(box.queue.removeFirst()) }
                if box.closed { return .failure(URLError(.networkConnectionLost)) }
                box.waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func push(_ message: String) {
        let waiter = mailbox.withLock { box -> CheckedContinuation<String, any Error>? in
            guard !box.closed else { return nil }
            if let waiter = box.waiter {
                box.waiter = nil
                return waiter
            }
            box.queue.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }

    func close() {
        let waiter = mailbox.withLock { box -> CheckedContinuation<String, any Error>? in
            box.closed = true
            defer { box.waiter = nil }
            return box.waiter
        }
        waiter?.resume(throwing: URLError(.networkConnectionLost))
    }
}

final class NoSleep: TRSleeper {
    init() {}
    let slept = Mutex<[TimeInterval]>([])
    func sleep(seconds: TimeInterval) async throws { slept.withLock { $0.append(seconds) } }
}

final class FakePresenter: AuthChallengePresenter {
    enum Behaviour: Sendable { case webSession([SessionCookie]), code(String), cancel, confirm }
    let behaviour: Behaviour
    let challenges = Mutex<[AuthChallenge]>([])

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        challenges.withLock { $0.append(challenge) }
        switch behaviour {
        case let .webSession(cookies): return .webSession(cookies)
        case let .code(code): return .code(code)
        case .cancel: throw ConnectorError.cancelled
        case .confirm: return .confirmed
        }
    }

    var count: Int { challenges.withLock { $0.count } }
}
