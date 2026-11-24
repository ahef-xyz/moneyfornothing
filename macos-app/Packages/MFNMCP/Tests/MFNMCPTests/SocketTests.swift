import Darwin
import Foundation
import MFNCore
import Testing
@testable import MFNMCP

/// A test client: connects to the socket and speaks newline-delimited JSON-RPC.
private final class LineClient {
    let fd: Int32
    private var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(fd) }

    func send(_ data: Data) {
        var line = data
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The next line, or `nil` on EOF / timeout.
    func receive() -> JSONValue? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                return JSONValue.decode(Data(line))
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }
}

private func socketPath() -> String {
    // sun_path is short: keep it in /tmp-like temp dir with a short name.
    NSTemporaryDirectory() + "mfn-\(UUID().uuidString.prefix(8)).sock"
}

@Suite(.serialized) struct SocketTests {
    @Test func endToEndOverTheSocket() async throws {
        let host = FakeHost()
        let clients = ClientLog()
        let server = MCPServer(host: host, serverVersion: "0.6.0") { clients.set($0) }
        let path = socketPath()
        try await server.start(path: path) { _ in true }
        defer { Task { await server.stop() } }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let client = try #require(LineClient(path: path))
        client.send(JSONValue.object(["jsonrpc": "2.0", "method": "mfn/hello", "params": ["parent": ["name": "Tester"]]]).encoded())
        client.send(request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "Socket Test"]]))
        #expect(client.receive()?["result"]?["serverInfo"]?["name"] == "moneyfornothing")
        client.send(request(2, "tools/call", ["name": "get_balances", "arguments": [:]]))
        let balances = client.receive()
        #expect(balances?["result"]?["isError"] == false)
        #expect((balances?["result"]?["structuredContent"]?["accounts"]?.arrayValue?.count ?? 0) > 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(clients.last.map { $0.map(\.displayName) } == ["Socket Test"])

        // Lock: the server closes the connection, the client sees EOF.
        await server.closeAll()
        #expect(client.receive() == nil)
    }

    @Test func refusedPeerIsClosedAtOnce() async throws {
        let server = MCPServer(host: FakeHost(), serverVersion: "0.6.0")
        let path = socketPath()
        try await server.start(path: path) { _ in false }
        defer { Task { await server.stop() } }
        let client = try #require(LineClient(path: path))
        client.send(request(1, "ping"))
        #expect(client.receive() == nil)
    }

    @Test func peerTokenIsReadable() async throws {
        let seen = TokenLog()
        let server = MCPServer(host: FakeHost(), serverVersion: "0.6.0")
        let path = socketPath()
        try await server.start(path: path) { token in
            seen.set(token.map { audit_token_to_pid($0) })
            return true
        }
        defer { Task { await server.stop() } }
        let client = try #require(LineClient(path: path))
        client.send(request(1, "ping"))
        _ = client.receive()
        #expect(seen.pid == getpid())
        // A test runner is not MFN's helper.
        #expect(PeerVerifier.isHelper(nil, teamID: "ABCDE12345") == false)
    }

    @Test func stopRemovesTheSocketFile() async throws {
        let server = MCPServer(host: FakeHost(), serverVersion: "0.6.0")
        let path = socketPath()
        try await server.start(path: path) { _ in true }
        await server.stop()
        #expect(access(path, F_OK) != 0)
    }
}

private final class ClientLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [MCPClientInfo]?
    func set(_ clients: [MCPClientInfo]) { lock.withLock { value = clients } }
    var last: [MCPClientInfo]? { lock.withLock { value } }
}

private final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?
    func set(_ pid: pid_t?) { lock.withLock { value = pid } }
    var pid: pid_t? { lock.withLock { value } }
}
