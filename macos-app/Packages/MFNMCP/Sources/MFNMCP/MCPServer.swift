import Darwin
import Foundation
import os

/// The app's side of the MCP channel: listens on the socket, runs one `MCPSession` per helper
/// connection and reports how many clients are connected. Off unless the user switched it on;
/// the app closes all connections when it locks.
public actor MCPServer {
    /// At most this many helpers at once.
    public static let maxConnections = 8

    private let host: any MCPHost
    private let serverVersion: String
    private let onConnections: @Sendable ([MCPClientInfo]) -> Void
    private var listener: MCPSocketListener?
    private let limiter = RateLimiter()
    private var connections: [UUID: (connection: MCPSocketConnection, session: MCPSession, task: Task<Void, Never>)] = [:]
    private static let logger = Logger(subsystem: "xyz.ahef.mfn", category: "mcp")

    public init(host: any MCPHost, serverVersion: String, onConnections: @escaping @Sendable ([MCPClientInfo]) -> Void = { _ in }) {
        self.host = host
        self.serverVersion = serverVersion
        self.onConnections = onConnections
    }

    /// Starts listening at `path`. `accepts` checks the peer (`PeerVerifier.isHelper`).
    public func start(path: String, accepts: @escaping @Sendable (audit_token_t?) -> Bool) throws(MCPSocketListener.ListenError) {
        guard listener == nil else { return }
        let listener = MCPSocketListener(path: path, accepts: accepts) { [weak self] connection in
            Task { await self?.adopt(connection) }
        }
        try listener.start()
        self.listener = listener
        Self.logger.info("MCP: listening")
    }

    public func stop() {
        listener?.stop()
        listener = nil
        closeAll()
        Self.logger.info("MCP: stopped")
    }

    public var isListening: Bool { listener != nil }

    /// Ends every connection (lock, switch off). Helpers reconnect on the client's next request.
    public func closeAll() {
        for entry in connections.values {
            entry.task.cancel()
            entry.connection.close()
        }
        connections = [:]
        report()
    }

    /// Drops the approval of every open session (an approved client was removed in Settings).
    public func revokeApprovals() async {
        for entry in connections.values { await entry.session.revokeApproval() }
    }

    /// Serves an already connected transport; for tests (socket pairs) and `adopt`.
    func adopt(_ connection: MCPSocketConnection) {
        guard listener != nil, connections.count < Self.maxConnections else {
            connection.close()
            return
        }
        let session = MCPSession(host: host, serverVersion: serverVersion, limiter: limiter)
        let id = session.id
        let task = Task { [weak self] in
            var handled = 0
            for await line in connection.lines {
                if let answer = await session.handle(line) { connection.send(answer) }
                handled += 1
                // After hello and initialize the client's name is known: report it.
                if handled <= 3 { await self?.report() }
            }
            await self?.ended(id)
        }
        connections[id] = (connection, session, task)
        report()
    }

    private func ended(_ id: UUID) {
        guard let entry = connections.removeValue(forKey: id) else { return }
        entry.connection.close()
        report()
    }

    private func report() {
        let sessions = connections.values.map(\.session)
        let callback = onConnections
        Task {
            var clients: [MCPClientInfo] = []
            for session in sessions { clients.append(await session.clientInfo) }
            callback(clients)
        }
    }
}
