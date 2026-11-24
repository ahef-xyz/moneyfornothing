import AppKit
import CryptoKit
import Foundation
import MFNCore
import MFNMCP
import Observation
import Security
import os

/// Settings → MCP, docs/v0.6.0.md: the switch, the account checklist, approved
/// clients, the activity log and the server that answers the helper `mfn-mcp`.
///
/// Off by default. The server only listens while the switch is on; tool calls only get data
/// while MFN is unlocked (`context()` is `nil` otherwise) and lock closes every connection.
@MainActor
@Observable
final class AssistantAccess {
    struct ApprovedClient: Codable, Hashable, Identifiable {
        /// `ParentIdentity.approvalKey` (team and signing identifier).
        var key: String
        var name: String
        var approvedAt: Date
        var id: String { key }
    }

    /// The approval prompt waiting for the user.
    struct ApprovalRequest: Identifiable {
        let id = UUID()
        let client: MCPClientInfo
        let resume: @MainActor (Decision) -> Void
    }

    /// `noAnswer`: timeout or lock; the client is asked again at its next call.
    enum Decision { case once, always, deny, noAnswer }

    static let enabledKey = "mcpEnabled"
    static let excludedAccountsKey = "mcpExcludedAccounts"
    static let approvedClientsKey = "mcpApprovedClients"
    static let saltKey = "mcpIDSalt"
    /// Lines kept in the activity log (memory only, gone when MFN quits).
    static let logLimit = 500
    /// Time the user has to answer the approval prompt; then it counts as "Ablehnen".
    static let approvalTimeout: Duration = .seconds(120)

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: AssistantAccess.enabledKey)
    /// Accounts the user unticked; new accounts are shared until unticked.
    private(set) var excludedAccounts: Set<AccountID> = Set((UserDefaults.standard.stringArray(forKey: AssistantAccess.excludedAccountsKey) ?? []).map(AccountID.init(rawValue:)))
    private(set) var approvedClients: [ApprovedClient] = AssistantAccess.loadApproved()
    /// Newest first.
    private(set) var activity: [MCPActivity] = []
    private(set) var connectedClients: [MCPClientInfo] = []
    /// Why the server could not start (unsigned build, socket problem); shown in Settings.
    private(set) var problem: String? {
        didSet {
            // VoiceOver hears it, also when Settings is not the focused window.
            if let problem, problem != oldValue { AccessibilityNotification.Announcement(problem).post() }
        }
    }
    /// The approval prompt on screen.
    @ObservationIgnored private var pendingApproval: ApprovalRequest?
    /// Our alert's modal loop is running (only then may a timeout or lock abort it).
    @ObservationIgnored private var alertOnScreen = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: MCPServer?
    @ObservationIgnored private let salt: Data = AssistantAccess.loadSalt()
    @ObservationIgnored private var approvalQueue: [ApprovalRequest] = []
    /// The stored settings carry a valid seal for the open ledger (`verifySettings`).
    @ObservationIgnored private var settingsVerified = false
    @ObservationIgnored private static let logger = Logger(subsystem: "xyz.ahef.mfn", category: "mcp")

    init(model: AppModel) {
        self.model = model
    }

    /// Path of the helper inside this app; clients start it.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mfn-mcp").path
    }

    static var appGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        else { return nil }
        return groups.first
    }

    static var socketURL: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?.appendingPathComponent("mcp.sock")
    }

    // MARK: Seal

    /// The switch, the shared accounts and the "always" approvals live in the preferences, which
    /// another process of the user might edit. They count only with a valid HMAC under a key
    /// derived from the database key (per ledger), so enabling access or approving a program
    /// keeps needing the unlocked app.
    private var sealKey: String { model?.profile.scoped("mcpSettingsSeal") ?? "mcpSettingsSeal" }

    private func sealPayload() -> Data {
        let excluded = excludedAccounts.map(\.rawValue).sorted().joined(separator: ",")
        let approved = approvedClients.map(\.key).sorted().joined(separator: ",")
        return Data("v1|\(isEnabled)|\(excluded)|\(approved)".utf8)
    }

    private func seal() -> String? {
        guard let hash = model?.recurringHasher(), model?.recurringHashKey != nil else { return nil }
        return hash(String(decoding: sealPayload(), as: UTF8.self))
    }

    /// Stores a new seal after a change made in the unlocked app.
    private func reseal() {
        guard let seal = seal() else { return }
        UserDefaults.standard.set(seal, forKey: sealKey)
        settingsVerified = true
    }

    /// After unlocking: settings without a valid seal (changed outside MFN, or made for the other
    /// ledger) are reset to off, with no approvals.
    /// `accounts`: every account of the opened ledger. A broken seal fails closed: none of them
    /// stays shared, since the checklist itself may have been edited.
    func verifySettings(accounts: [AccountID]) {
        if isTestMode {
            settingsVerified = true
            return
        }
        guard let expected = seal() else { return }
        let stored = UserDefaults.standard.string(forKey: sealKey)
        if stored == expected {
            settingsVerified = true
            return
        }
        let hadSomething = isEnabled || !approvedClients.isEmpty
        approvedClients = []
        saveApproved()
        if stored != nil {
            excludedAccounts = Set(accounts)
            UserDefaults.standard.set(excludedAccounts.map(\.rawValue).sorted(), forKey: Self.excludedAccountsKey)
        }
        if isEnabled {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            stop()
        }
        reseal()
        if hadSomething, stored != nil {
            problem = "Die MCP-Einstellungen wurden außerhalb von MFN geändert oder gehören zur anderen Datenbank. Der Zugang ist deshalb aus, und kein Konto ist mehr freigegeben. Schalte ihn bei Bedarf neu ein und wähle die Konten wieder aus."
        }
    }

    // MARK: Switch

    /// Called at launch: starts the server if the user left it on.
    func resume() {
        if isEnabled { start() }
    }

    /// The switch in Settings (after the warning when turning on). Needs MFN unlocked.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled, model?.lock.isLocked == false || !on else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        reseal()
        if on { problem = nil; start() } else { stop() }
    }

    private func start() {
        guard server == nil else { return }
        guard let teamID = PeerVerifier.ownTeamID() else {
            problem = "Diese MFN-Version ist nicht mit einem Entwicklerzertifikat signiert. Ohne Signatur kann MFN den Helfer nicht prüfen, deshalb bleibt der Zugang zu."
            return
        }
        guard let url = Self.socketURL else {
            problem = "Der gemeinsame Ordner für den Helfer fehlt (App-Group-Berechtigung)."
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let server = MCPServer(host: Host(access: self), serverVersion: version) { clients in
            Task { @MainActor [weak self] in self?.updateClients(clients.filter { $0.declaredName != nil || $0.parent != nil }) }
        }
        self.server = server
        problem = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await server.start(path: url.path) { token in PeerVerifier.isHelper(token, teamID: teamID) }
            } catch {
                Self.logger.error("MCP: start failed: \(String(describing: error), privacy: .public)")
                self.problem = "Der Zugang konnte nicht geöffnet werden (\(String(describing: error)))."
                self.server = nil
            }
        }
    }

    /// New list of connected clients; VoiceOver hears when an assistant starts or stops reading.
    private func updateClients(_ clients: [MCPClientInfo]) {
        let before = Set(connectedClients.map(\.displayName))
        connectedClients = clients
        let after = Set(clients.map(\.displayName))
        for name in after.subtracting(before).sorted() {
            AccessibilityNotification.Announcement("MCP-Programm verbunden: \(name)").post()
        }
        for name in before.subtracting(after).sorted() {
            AccessibilityNotification.Announcement("MCP-Programm getrennt: \(name)").post()
        }
    }

    private func stop() {
        let server = server
        self.server = nil
        connectedClients = []
        denyAllPending()
        Task { await server?.stop() }
    }

    /// MFN locked: every connection closes, open prompts are answered "Ablehnen".
    func locked() {
        settingsVerified = false
        denyAllPending()
        let server = server
        Task { await server?.closeAll() }
    }

    // MARK: Accounts

    func isShared(_ account: AccountID) -> Bool { !excludedAccounts.contains(account) }

    func setShared(_ shared: Bool, _ account: AccountID) {
        if shared { excludedAccounts.remove(account) } else { excludedAccounts.insert(account) }
        UserDefaults.standard.set(excludedAccounts.map(\.rawValue).sorted(), forKey: Self.excludedAccountsKey)
        reseal()
    }

    // MARK: Approved clients

    func removeApproval(_ client: ApprovedClient) {
        approvedClients.removeAll { $0.key == client.key }
        saveApproved()
        reseal()
        let server = server
        Task { await server?.revokeApprovals() }
    }

    private func isApprovedAlways(_ client: MCPClientInfo) -> Bool {
        guard let key = client.parent?.approvalKey else { return false }
        return approvedClients.contains { $0.key == key }
    }

    private func saveApproved() {
        UserDefaults.standard.set(try? JSONEncoder().encode(approvedClients), forKey: Self.approvedClientsKey)
    }

    private static func loadApproved() -> [ApprovedClient] {
        guard let data = UserDefaults.standard.data(forKey: approvedClientsKey) else { return [] }
        return (try? JSONDecoder().decode([ApprovedClient].self, from: data)) ?? []
    }

    private static func loadSalt() -> Data {
        if let salt = UserDefaults.standard.data(forKey: saltKey), salt.count == 16 { return salt }
        let salt = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) })
        UserDefaults.standard.set(salt, forKey: saltKey)
        return salt
    }

    // MARK: Host (called from the server's sessions)

    /// DEBUG + demo + `MFN_MCP_AUTO_APPROVE=1`: automated tests of the whole path, never with
    /// real data (no prompt, `-mcpEnabled YES` without a seal).
    private var isTestMode: Bool {
        #if DEBUG
        model?.isDemo == true && ProcessInfo.processInfo.environment["MFN_MCP_AUTO_APPROVE"] == "1"
        #else
        false
        #endif
    }

    fileprivate func context() -> MCPContext? {
        guard isEnabled, let model, !model.lock.isLocked, model.isLedgerOpen, settingsVerified || isTestMode else { return nil }
        let ledger = model.ledger
        let scope = Set(ledger.accounts.map(\.id)).subtracting(excludedAccounts)
        let hidden = model.hiddenRecurring
        let hash = model.recurringHasher()
        return MCPContext(snapshot: ledger, scope: scope, idSalt: salt, today: .today,
                          isRecurringHidden: { hidden.contains(hash($0)) })
    }

    fileprivate func approve(_ client: MCPClientInfo) async -> MCPApproval {
        guard isEnabled, model?.lock.isLocked == false else { return .unanswered }
        if settingsVerified, isApprovedAlways(client) { return .allowed }
        if isTestMode { return .allowed }
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<Decision, Never>) in
            var done = false
            let request = ApprovalRequest(client: client) { decision in
                guard !done else { return }
                done = true
                continuation.resume(returning: decision)
            }
            enqueue(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.approvalTimeout)
                self?.answer(request, .noAnswer)
            }
        }
        switch decision {
        case .always:
            if let key = client.parent?.approvalKey, !approvedClients.contains(where: { $0.key == key }) {
                approvedClients.append(ApprovedClient(key: key, name: client.parent?.name ?? client.displayName, approvedAt: Date()))
                saveApproved()
                reseal()
            }
            return .allowed
        case .once: return .allowed
        case .deny: return .denied
        case .noAnswer: return .unanswered
        }
    }

    private func enqueue(_ request: ApprovalRequest) {
        approvalQueue.append(request)
        if pendingApproval == nil { showNext() }
    }

    /// One prompt at a time, as a system alert: it works with or without the main window
    /// (menu bar mode) and VoiceOver reads it like any system dialog.
    private func showNext() {
        guard pendingApproval == nil, let request = approvalQueue.first else { return }
        pendingApproval = request
        // Out of the caller's stack: the alert runs a modal loop.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.present(request) }
        }
    }

    private func present(_ request: ApprovalRequest) {
        guard pendingApproval?.id == request.id else { return }
        let client = request.client
        let alert = NSAlert()
        alert.alertStyle = .warning
        // Headline from what the helper read from the kernel; the client's own name only as a
        // labelled detail (anyone can send any name).
        // The name is the executable's own (anyone can call a binary "Claude"): without a
        // verified developer signature the headline says so first.
        if let parent = client.parent, parent.teamID != nil {
            alert.messageText = "„\(parent.name)“ möchte deine Finanzdaten lesen"
        } else {
            alert.messageText = "Ein Programm ohne Entwickler-Signatur („\(client.parent?.name ?? "unbekannt")“) möchte deine Finanzdaten lesen"
        }
        var lines = [
            "Programm: \(client.originDescription)",
            "Der Assistent sieht Salden, Umsätze und Namen von Gegenparteien der freigegebenen Konten. Mit einem Cloud-Modell gehen diese Daten an dessen Anbieter.",
        ]
        if let declared = client.declaredName { lines.insert("Nennt sich selbst: „\(declared)“", at: 1) }
        if client.parent?.approvalKey == nil {
            lines.append("„Immer erlauben“ gibt es nur für Programme mit Entwickler-Signatur, die MFNs Helfer direkt starten.")
        }
        lines.append("Ohne Antwort innerhalb von 2 Minuten lehnt MFN ab.")
        alert.informativeText = lines.joined(separator: "\n\n")
        // "Ablehnen" is the default: a stray Return never grants access.
        alert.addButton(withTitle: "Ablehnen")
        alert.addButton(withTitle: "Einmal erlauben").keyEquivalent = ""
        let canAlways = client.parent?.approvalKey != nil
        if canAlways { alert.addButton(withTitle: "Immer erlauben").keyEquivalent = "" }
        NSApp.activate()
        alertOnScreen = true
        let response = alert.runModal()
        alertOnScreen = false
        if response == .abort {
            // Timed out or MFN locked while the prompt was up.
            AccessibilityNotification.Announcement("MCP-Anfrage abgelaufen, abgelehnt").post()
        }
        let decision: Decision = switch response {
        case .alertSecondButtonReturn: .once
        case .alertThirdButtonReturn where canAlways: .always
        default: .deny
        }
        answer(request, decision)
        // Only now, with this alert's modal loop over, may the next prompt start.
        showNext()
    }

    /// The user's answer in the prompt (or the timeout).
    func answer(_ request: ApprovalRequest, _ decision: Decision) {
        guard let index = approvalQueue.firstIndex(where: { $0.id == request.id }) else { return }
        approvalQueue.remove(at: index)
        request.resume(decision)
        if pendingApproval?.id == request.id {
            pendingApproval = nil
            // Timeout while the alert is up: close it; `present` shows the next one after.
            if alertOnScreen {
                NSApp.abortModal()
                return
            }
        }
        showNext()
    }

    private func denyAllPending() {
        let queue = approvalQueue
        approvalQueue = []
        let showing = pendingApproval != nil
        pendingApproval = nil
        for request in queue { request.resume(.noAnswer) }
        if showing, alertOnScreen { NSApp.abortModal() }
    }

    fileprivate func record(_ entry: MCPActivity) {
        activity.insert(entry, at: 0)
        if activity.count > Self.logLimit { activity.removeLast(activity.count - Self.logLimit) }
        Self.logger.info("MCP: \(entry.tool, privacy: .public) \(entry.outcome.rawValue, privacy: .public) \(entry.count, privacy: .public)")
    }

    func clearLog() { activity = [] }

    /// Bridges the server's sessions (any thread) to the main actor.
    private struct Host: MCPHost {
        weak var access: AssistantAccess?

        func context() async -> MCPContext? {
            await MainActor.run { access?.context() }
        }

        func approve(_ client: MCPClientInfo, session: UUID) async -> MCPApproval {
            guard let access = await MainActor.run(body: { access }) else { return .unanswered }
            return await access.approve(client)
        }

        func record(_ activity: MCPActivity) async {
            await MainActor.run { access?.record(activity) }
        }
    }
}

extension MCPClientInfo {
    /// For the prompt: who started the helper, as far as MFN can tell.
    var originDescription: String {
        guard let parent else { return "Unbekannt (der Helfer hat keine Angaben geschickt)." }
        var text = parent.name
        if let identifier = parent.identifier { text += " (\(identifier))" }
        if let team = parent.teamID {
            text += ", signiert von Entwickler-Team \(team)"
        } else {
            text += ", ohne Entwickler-Signatur"
        }
        if !parent.via.isEmpty { text += ", gestartet über \(parent.via.joined(separator: ", "))" }
        return text
    }
}
