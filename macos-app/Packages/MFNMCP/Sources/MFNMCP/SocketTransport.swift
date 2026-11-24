import Darwin
import Foundation
import os
import Security

/// A Unix domain socket that accepts MCP connections from the helper (`mfn-mcp`), one line of
/// JSON per message. The file lives in the App Group container, mode 0600.
public final class MCPSocketListener: @unchecked Sendable {
    public enum ListenError: Error, Equatable {
        case pathTooLong
        case system(String, Int32)
    }

    /// Longest message accepted; a longer line closes the connection.
    static let maxLineLength = 4 << 20

    private let path: String
    private let accepts: @Sendable (audit_token_t?) -> Bool
    private let onConnection: @Sendable (MCPSocketConnection) -> Void
    private let queue = DispatchQueue(label: "xyz.ahef.mfn.mcp.listen")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private static let logger = Logger(subsystem: "xyz.ahef.mfn", category: "mcp")

    /// `accepts`: the peer check (audit token of the connecting process, `nil` if unreadable).
    public init(path: String, accepts: @escaping @Sendable (audit_token_t?) -> Bool, onConnection: @escaping @Sendable (MCPSocketConnection) -> Void) {
        self.path = path
        self.accepts = accepts
        self.onConnection = onConnection
    }

    public func start() throws(ListenError) {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw .system("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketFD)
            throw .pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // A socket file left by a crashed run.
        unlink(path)
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else {
            let error = errno
            close(socketFD)
            throw .system("bind", error)
        }
        chmod(path, 0o600)
        guard listen(socketFD, 8) == 0 else {
            let error = errno
            close(socketFD)
            unlink(path)
            throw .system("listen", error)
        }
        fd = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(socketFD) }
        self.source = source
        source.resume()
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if fd >= 0 { unlink(path) }
            fd = -1
        }
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let token = Self.peerToken(client)
        guard accepts(token) else {
            Self.logger.notice("MCP: connection from a process that is not MFN's helper refused")
            close(client)
            return
        }
        onConnection(MCPSocketConnection(fd: client, token: token))
    }

    static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length)
        return result == 0 ? token : nil
    }
}

/// One accepted connection: lines in as an `AsyncStream`, lines out through `send`.
public final class MCPSocketConnection: @unchecked Sendable {
    public let token: audit_token_t?
    public let lines: AsyncStream<Data>
    private let fd: Int32
    private let continuation: AsyncStream<Data>.Continuation
    private let readQueue = DispatchQueue(label: "xyz.ahef.mfn.mcp.read")
    private let writeQueue = DispatchQueue(label: "xyz.ahef.mfn.mcp.write")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32, token: audit_token_t?) {
        self.fd = fd
        self.token = token
        // Lines waiting for the session are capped; past the cap the connection closes (a
        // dropped line would leave a request unanswered, so none is dropped silently).
        (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(MCPSocketConnection.maxPendingLines))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// The peer's process ID (from the audit token).
    public var peerPID: pid_t? {
        token.map { audit_token_to_pid($0) }
    }

    /// Lines read but not yet handled by the session (it may wait on the approval prompt).
    static let maxPendingLines = 256
    /// Reused for every read (only touched on `readQueue`).
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    private func readAvailable() {
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            close()
            return
        }
        buffer.append(contentsOf: chunk[0 ..< count])
        // Walk the buffer once, trim once.
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start ..< newline]
            start = buffer.index(after: newline)
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
            if case .dropped = continuation.yield(Data(line)) {
                close()
                return
            }
        }
        buffer.removeSubrange(buffer.startIndex ..< start)
        if buffer.count > MCPSocketListener.maxLineLength { close() }
    }

    /// Sends one message; a newline is added.
    public func send(_ line: Data) {
        guard !closed.withLock({ $0 }) else { return }
        writeQueue.async { [fd, closed] in
            // Closed meanwhile: the descriptor may already belong to something else.
            guard !closed.withLock({ $0 }) else { return }
            var data = line
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let written = write(fd, pointer, left)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return }
                    left -= written
                    pointer += written
                }
            }
        }
    }

    public func close() {
        let wasClosed = closed.withLock { state in
            defer { state = true }
            return state
        }
        guard !wasClosed else { return }
        continuation.finish()
        // Pending writes first, then the descriptor goes with the read source. Strong
        // captures: the connection must live until its descriptor is closed.
        writeQueue.async {
            self.readQueue.async {
                self.source?.cancel()
                self.source = nil
            }
        }
    }
}

/// Checks that the peer is MFN's own helper: signed by the same team as the running app, with
/// the helper's signing identifier.
public enum PeerVerifier {
    public static let helperIdentifier = "xyz.ahef.mfn.mcp"

    /// The team of the running app's signature; `nil` for ad hoc or unsigned builds.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether the process behind `token` is the helper signed by `teamID`.
    public static func isHelper(_ token: audit_token_t?, teamID: String) -> Bool {
        guard let token else { return false }
        var tokenCopy = token
        let tokenData = withUnsafeBytes(of: &tokenCopy) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        let text = "identifier \"\(helperIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
