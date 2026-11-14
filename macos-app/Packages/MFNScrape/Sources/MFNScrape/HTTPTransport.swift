import Foundation
import MFNCore

/// Sends one HTTP request. `URLSessionTransport` in production, `ScriptedHTTPTransport` in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral `URLSession`: no shared cookie storage, no cache. Cookies are managed by `ScrapeClient`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Test transport: answers from a closure, records requests. Never talks to a bank.
public actor ScriptedHTTPTransport: HTTPTransport {
    public typealias Responder = @Sendable (_ request: URLRequest, _ index: Int) throws -> (Data, HTTPURLResponse)

    private let responder: Responder
    public private(set) var requests: [URLRequest] = []

    public init(responder: @escaping Responder) {
        self.responder = responder
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try responder(request, requests.count - 1)
    }

    /// Convenience for building responses in tests.
    public static func response(_ url: URL?, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) -> (Data, HTTPURLResponse) {
        let url = url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) ?? HTTPURLResponse()
        return (body, response)
    }
}

/// Pauses between retries. Injected so tests never really sleep.
public protocol Sleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Exponential backoff for 429/5xx/network errors (CLAUDE.md §1: backoff, stop after 3 errors).
public struct BackoffPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Delay before attempt `attempt` (1-based, attempt 1 has no delay), ±20 % jitter.
    public func delay(beforeAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(retryAfter, maxDelay) }
        let exponential = baseDelay * pow(2, Double(max(0, attempt - 2)))
        return min(exponential, maxDelay) * Double.random(in: 0.8...1.2)
    }
}
