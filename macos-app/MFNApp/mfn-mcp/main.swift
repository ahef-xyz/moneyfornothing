// mfn-mcp: the MCP server process an assistant (Claude Desktop, Claude Code, a local model's
// client) starts. A thin proxy: it forwards newline-delimited JSON-RPC between stdin/stdout and
// MoneyForNothing's Unix socket in the App Group container. It holds no data and no keys and
// cannot open the database. When MFN is not reachable it answers by itself, so the client gets
// a clear error instead of a hang. It never launches MFN. See docs/v0.6.0.md.

import Darwin
import Foundation
import Security

let socketName = "mcp.sock"
let notRunning = "MoneyForNothing is not running, or access for AI assistants is off (MFN settings, tab \"MCP\"). Ask the user to open MFN on this Mac, unlock it and switch the access on, then try again."
let refusedByMFN = "MoneyForNothing refused this helper. This happens when MFN was updated while this MCP server kept running. Ask the user to restart or reconnect the MoneyForNothing MCP server in this program, then try again."
let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

// MARK: - Output

let outputLock = NSLock()

func emit(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    emitLine(data)
}

func emitLine(_ data: Data) {
    outputLock.withLock {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("mfn-mcp: \(message)\n".utf8))
}

// MARK: - Where the app listens

/// The App Group from this binary's own entitlements; the app has the same one.
func appGroup() -> String? {
    guard let task = SecTaskCreateFromSelf(nil),
          let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
    else { return nil }
    return value.first
}

func socketPath() -> String? {
    guard let group = appGroup(), let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
    return String(cString: home) + "/Library/Group Containers/\(group)/\(socketName)"
}

// MARK: - Who started us

/// Processes that only launch the real client: look past them.
let launchers: Set<String> = ["node", "npx", "npm", "bun", "bunx", "deno", "uv", "uvx", "python", "python3", "sh", "bash", "zsh", "fish", "dash", "env", "login", "sudo", "mcp-remote"]

func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

func path(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// Signing identifier and team of a running process (team `nil` for Apple, ad hoc, unsigned).
/// The team counts only if the signature chains to Apple and its leaf names that team: a
/// self-made certificate claiming a known team must never match a stored "allow always".
func signature(of pid: pid_t) -> (identifier: String?, team: String?) {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
          SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return (nil, nil) }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil) }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dictionary = info as? [String: Any] else { return (nil, nil) }
    let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
    guard let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
          satisfies(code, "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"") else { return (identifier, nil) }
    return (identifier, team)
}

func satisfies(_ code: SecCode, _ requirementText: String) -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

/// The team of this helper's own signature; MFN must be signed by the same one.
func ownTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dictionary = info as? [String: Any] else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}

/// Whether the process listening on the socket is MoneyForNothing signed by our team, so the
/// client's questions never go to a process that took over the socket while MFN was down.
func listenerIsMFN(_ socketFD: Int32) -> Bool {
    guard let team = ownTeam() else { return false }
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
          let code else { return false }
    return satisfies(code, "identifier \"xyz.ahef.mfn\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
}

/// "Claude" for /Applications/Claude.app/…, else the file name; a bare version number
/// ("2.1.331", Claude Code's binary) gives way to the signing identifier.
func displayName(path: String?, fallback: String, identifier: String?) -> String {
    if let path, let range = path.range(of: ".app/") {
        return ((String(path[..<range.lowerBound])) as NSString).lastPathComponent
    }
    if fallback.allSatisfy({ $0.isNumber || $0 == "." }), let identifier {
        return identifier.split(separator: ".").last.map(String.init) ?? identifier
    }
    return fallback
}

func parentIdentity() -> [String: Any] {
    var pid = getppid()
    var via: [String] = []
    for _ in 0 ..< 6 {
        let executable = path(of: pid)
        let name = executable.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        if launchers.contains(name.lowercased()), let next = parentPID(of: pid), next > 1 {
            via.append(name)
            pid = next
            continue
        }
        let signed = signature(of: pid)
        // The process may have ended and its PID been reused while we looked: the path read
        // before the signature must still be the one now, and a direct parent still ours.
        guard path(of: pid) == executable, !via.isEmpty || getppid() == pid else { return ["name": "unknown", "via": via] }
        var identity: [String: Any] = ["name": displayName(path: executable, fallback: name, identifier: signed.identifier), "via": via]
        if let executable { identity["path"] = executable }
        if let identifier = signed.identifier { identity["identifier"] = identifier }
        if let team = signed.team { identity["team_id"] = team }
        return identity
    }
    return ["name": "unknown", "via": via]
}

// Read once at start; immutable afterwards.
nonisolated(unsafe) let parent = parentIdentity()
if ProcessInfo.processInfo.environment["MFN_MCP_DEBUG"] == "1" {
    log("parent \(parent)")
}

// MARK: - Connection to the app

final class Link: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    /// The client's `initialize`, replayed after a reconnect (MFN restarted or unlocked).
    private var _initializeRequest: [String: Any]?
    private var _initializedNotification = false
    /// One connection attempt at a time (main loop and the background retry).
    private let connectLock = NSLock()

    var initializeRequest: [String: Any]? {
        get { lock.withLock { _initializeRequest } }
        set { lock.withLock { _initializeRequest = newValue } }
    }

    var initializedNotification: Bool {
        get { lock.withLock { _initializedNotification } }
        set { lock.withLock { _initializedNotification = newValue } }
    }

    /// Keeps trying to reach MFN while the client is idle, so MFN shows it as connected as soon
    /// as it runs, is unlocked and has access switched on (not only at the client's next request).
    func startRetrying() {
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 2)
                // MFN was updated: become the new helper (same process, same pipes) while idle.
                if binaryChanged() { input.execIfIdle(resuming: self) }
                if initializeRequest != nil, !isConnected { _ = connect(replaying: true) }
            }
        }
    }
    private var replayCounter = 0
    /// Counts connections; outstanding requests remember the one they were sent on.
    private var generation = 0
    /// One writer at a time on the socket (main loop and background retry).
    private let writeLock = NSLock()
    /// MFN accepted the socket and closed it again at once, without a single line: its peer
    /// check refused this process (typically an old helper still running after an update).
    private var _refused = false
    var refused: Bool { lock.withLock { _refused } }
    var hasOutstanding: Bool { lock.withLock { !outstanding.isEmpty } }
    /// Requests sent to the app and not answered yet, by their id (as JSON text), with the
    /// connection they went out on. Answered here if that connection drops, so the client never
    /// waits forever.
    private var outstanding: [String: (message: [String: Any], generation: Int)] = [:]

    static func key(_ id: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [id]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func sent(_ message: [String: Any]) {
        guard let id = message["id"], message["method"] != nil, let key = Self.key(id) else { return }
        lock.withLock { outstanding[key] = (message, generation) }
    }

    /// Takes a request back after a failed send; `false` if the reader answered it meanwhile.
    func take(_ message: [String: Any]) -> Bool {
        guard let id = message["id"], let key = Self.key(id) else { return true }
        return lock.withLock { outstanding.removeValue(forKey: key) != nil }
    }

    private func answered(_ id: Any) {
        guard let key = Self.key(id) else { return }
        _ = lock.withLock { outstanding.removeValue(forKey: key) }
    }

    var isConnected: Bool { lock.withLock { fd >= 0 } }

    /// Connects if not connected; on a new connection sends the hello and replays the
    /// client's handshake. Returns whether there is a connection.
    func ensure() -> Bool {
        connect(replaying: true)
    }

    /// `replaying`: send the stored handshake after the hello (not when the handshake itself is
    /// what is being sent).
    func connect(replaying: Bool) -> Bool {
        connectLock.lock()
        defer { connectLock.unlock() }
        if isConnected { return true }
        guard let path = socketPath() else {
            log("no App Group entitlement; this binary must be the one inside MFN.app")
            return false
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        // Not inherited by the new image after an in-place update.
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketFD)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(socketFD)
            return false
        }
        guard listenerIsMFN(socketFD) else {
            debug("the process on the socket is not MoneyForNothing")
            close(socketFD)
            return false
        }
        // The hello and the replayed handshake go out before the connection is published, so
        // no client line can come first.
        var opening: [[String: Any]] = [["jsonrpc": "2.0", "method": "mfn/hello", "params": ["parent": parent]]]
        if replaying, var replay = initializeRequest {
            replayCounter += 1
            replay["id"] = "mfn-replay-\(replayCounter)"
            opening.append(replay)
            if initializedNotification { opening.append(["jsonrpc": "2.0", "method": "notifications/initialized"]) }
        }
        for object in opening {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
                  Self.writeAll(socketFD, data) else {
                close(socketFD)
                return false
            }
        }
        let current: Int = lock.withLock {
            generation += 1
            fd = socketFD
            return generation
        }
        debug("connected to MFN (pid \(getpid()))")
        startReading(socketFD, generation: current)
        return true
    }

    /// One line, all of it; `false` on any error.
    static func writeAll(_ socketFD: Int32, _ data: Data) -> Bool {
        var line = data
        line.append(0x0A)
        return line.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return false }
            var left = raw.count
            while left > 0 {
                let written = write(socketFD, pointer, left)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                left -= written
                pointer += written
            }
            return true
        }
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        sendLine(data)
    }

    @discardableResult
    func sendLine(_ data: Data) -> Bool {
        writeLock.withLock {
            let socketFD = lock.withLock { fd }
            guard socketFD >= 0 else { return false }
            let ok = Self.writeAll(socketFD, data)
            if !ok { drop(socketFD) }
            return ok
        }
    }

    /// Ends this connection for writing and reading. Only its reader thread closes the
    /// descriptor, so its number can never be reused while another thread still holds it.
    private func drop(_ socketFD: Int32) {
        lock.withLock {
            guard fd == socketFD else { return }
            shutdown(fd, SHUT_RDWR)
            fd = -1
        }
    }

    private func startReading(_ socketFD: Int32, generation current: Int) {
        Thread.detachNewThread { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let opened = Date()
            var receivedAny = false
            while true {
                let count = read(socketFD, &chunk, chunk.count)
                guard count > 0 else { break }
                if !receivedAny {
                    receivedAny = true
                    lock.withLock { _refused = false }
                }
                buffer.append(contentsOf: chunk[0 ..< count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex ..< newline])
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    // Answers to the replayed handshake are ours, not the client's.
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    if let id = object?["id"] as? String, id.hasPrefix("mfn-replay-") { continue }
                    if let id = object?["id"], object?["method"] == nil { answered(id) }
                    emitLine(line)
                }
            }
            drop(socketFD)
            close(socketFD)
            if !receivedAny, Date().timeIntervalSince(opened) < 2 {
                lock.withLock { _refused = true }
                debug("MFN refused this helper")
            }
            debug("connection to MFN closed")
            // Only what went out on this connection: a newer one answers its own requests.
            let open: [[String: Any]] = lock.withLock {
                let mine = outstanding.filter { $0.value.generation == current }
                for key in mine.keys { outstanding[key] = nil }
                return mine.values.map(\.message)
            }
            for message in open { answerLocally(message) }
        }
    }
}

func debug(_ message: String) {
    if ProcessInfo.processInfo.environment["MFN_MCP_DEBUG"] == "1" { log(message) }
}

let link = Link()

/// Sends a client message to MFN; `false` if that failed (then answer it here).
func forward(_ message: [String: Any]?, _ data: Data) -> Bool {
    if let message { link.sent(message) }
    if link.sendLine(data) { return true }
    if let message { return !link.take(message) }
    return false
}

// MARK: - Answers while MFN is not reachable

func answerLocally(_ message: [String: Any]) {
    guard let id = message["id"], let method = message["method"] as? String else { return }
    let notRunning = link.refused ? refusedByMFN : notRunning
    switch method {
    case "initialize":
        let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
        let version = requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0]
        emit(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "moneyfornothing", "title": "MoneyForNothing", "version": "0"],
            "instructions": notRunning,
        ]])
    case "ping":
        emit(["jsonrpc": "2.0", "id": id, "result": [:]])
    case "tools/call":
        emit(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": notRunning]], "isError": true]])
    default:
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": notRunning]])
    }
}

// MARK: - Updating in place

/// This binary as it was when the process started.
let ownPath = path(of: getpid())
let ownStamp = ownPath.flatMap(fileStamp)

func fileStamp(_ path: String) -> [Int] {
    var info = stat()
    guard stat(path, &info) == 0 else { return [] }
    return [Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
}

/// The file on disk is no longer the code this process runs (MFN was updated or rebuilt).
/// MFN's peer check then refuses this process; the new file is fine.
func binaryChanged() -> Bool {
    guard let ownPath, let ownStamp else { return false }
    let now = fileStamp(ownPath)
    return !now.isEmpty && now != ownStamp
}

/// stdin, read by hand so that it is known when nothing of the client is buffered here: only
/// then may the process exec itself (the kernel keeps unread input for the new image).
final class Input: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var idle = false

    /// The next line, or `nil` at end of input.
    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newline])
                buffer.removeSubrange(buffer.startIndex ... newline)
                return line
            }
            lock.withLock { idle = true }
            var ready = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            _ = poll(&ready, 1, -1)
            // Read under the lock: the exec below never happens with input taken but unhandled.
            let count: Int = lock.withLock {
                idle = false
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let count = read(0, &chunk, chunk.count)
                if count > 0 { buffer.append(contentsOf: chunk[0 ..< count]) }
                return count
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            if count <= 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
        }
    }

    /// Replaces this process with the current helper binary, handing over the client's
    /// handshake. Only while the main loop waits for input with nothing buffered.
    func execIfIdle(resuming link: Link) {
        lock.lock()
        defer { lock.unlock() }
        // Under the input lock: the main loop cannot forward a request meanwhile, so nothing
        // the client waits for is lost with the old image.
        guard idle, buffer.isEmpty, !link.hasOutstanding, let ownPath else { return }
        var pending = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 0) == 0 else { return }
        if let request = link.initializeRequest,
           let data = try? JSONSerialization.data(withJSONObject: request) {
            setenv("MFN_MCP_RESUME", data.base64EncodedString(), 1)
            setenv("MFN_MCP_RESUME_INITIALIZED", link.initializedNotification ? "1" : "0", 1)
        }
        debug("helper binary changed, restarting in place")
        let arguments = [strdup(ownPath), nil]
        execv(ownPath, arguments)
        // exec failed: carry on as the old helper.
        unsetenv("MFN_MCP_RESUME")
        unsetenv("MFN_MCP_RESUME_INITIALIZED")
    }
}

let input = Input()

/// After an in-place restart: the client's handshake from the previous image.
if let resume = ProcessInfo.processInfo.environment["MFN_MCP_RESUME"],
   let data = Data(base64Encoded: resume),
   let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    link.initializeRequest = request
    link.initializedNotification = ProcessInfo.processInfo.environment["MFN_MCP_RESUME_INITIALIZED"] == "1"
    unsetenv("MFN_MCP_RESUME")
    unsetenv("MFN_MCP_RESUME_INITIALIZED")
    debug("resumed after an update")
    _ = link.connect(replaying: true)
}

// MARK: - Main loop

signal(SIGPIPE, SIG_IGN)
link.startRetrying()
while let data = input.nextLine() {
    let text = String(decoding: data, as: UTF8.self)
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    // "mfn/" methods are between this helper and MFN; a client may not send them.
    if let method = message?["method"] as? String, method.hasPrefix("mfn/") {
        if let id = message?["id"] { emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
        continue
    }
    if let message, let method = message["method"] as? String {
        if method == "initialize" { link.initializeRequest = message }
        if method == "notifications/initialized" { link.initializedNotification = true }
    }
    // A request is the moment to (re)connect: MFN may have started or been unlocked since.
    let isInitialize = (message?["method"] as? String) == "initialize"
    if isInitialize, link.isConnected {
        if !forward(message, data), let message { answerLocally(message) }
        continue
    }
    if isInitialize {
        // Connect without replaying (this is the handshake itself).
        if link.connect(replaying: false), forward(message, data) { continue }
        if let message { answerLocally(message) }
        continue
    }
    if link.ensure(), forward(message, data) { continue }
    if let message { answerLocally(message) }
}
exit(0)
