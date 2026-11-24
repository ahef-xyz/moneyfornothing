import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import MFNCore
import MFNIntelligence
import MFNMock
import MFNScrape
import MFNStore
import Observation
import SwiftUI

/// Single source of UI state. Views read `snapshot`; all data comes from the `LedgerStore`.
@MainActor
@Observable
final class AppModel {
    /// Password needed after Touch ID: first start (choose one) or a database without key on
    /// this Mac (enter it once).
    enum VaultPrompt: Equatable {
        case setup
        case password
    }

    let lock = AppLock()
    let presenter = AuthSheetPresenter()

    /// Everything in the ledger, including hidden accounts. Only places that switch accounts back
    /// on read it (bank menus, Settings → Banken).
    private(set) var ledger = LedgerSnapshot() {
        didSet {
            // Only read marks changed (a row selected, ⇧⌘U) or only sync states (a sync starting,
            // asking for approval, failing, ending): no rebuild of index and lists.
            switch Self.lightChange(from: oldValue, to: ledger) {
            case .newOnly:
                refreshNewState()
                return
            case let .syncStates(alsoNew):
                if alsoNew { refreshNewState() }
                snapshot.syncStates = ledger.syncStates
                return
            case nil:
                break
            }
            ledgerRevision &+= 1
            refreshSnapshot()
        }
    }
    /// Bumped on every new `ledger` (store update or lock), unlike `snapshotRevision` not on
    /// hiding accounts: what is read from the full ledger (initiators) is cached against it.
    @ObservationIgnored private var ledgerRevision = 0
    /// What the UI shows: `ledger` without hidden accounts (their balances, transactions,
    /// statements and positions). Totals, "Alle Konten", "Vorgemerkt" and "Zu prüfen" follow it.
    private(set) var snapshot = LedgerSnapshot()
    /// Bumped whenever `snapshot` is rebuilt. Derived values (list content, budgets) are cached
    /// against it, so a click or a sidebar drag does not recompute them over every transaction.
    private(set) var snapshotRevision = 0
    /// Lookups and counters over `snapshot`, rebuilt with it (sidebar, footer, menu bar, inspector
    /// read them on every render).
    private(set) var index = SnapshotIndex()
    @ObservationIgnored private var ledgerCache: (key: LedgerCacheKey, content: LedgerContent)?
    /// The query-independent part of the list (running balances, recurring, names): typing in
    /// the search field only refilters.
    @ObservationIgnored private var ledgerBaseCache: (key: LedgerBaseKey, base: LedgerBase)?
    /// Booked transactions per lowercased counterpart (inspector history), built on first use.
    @ObservationIgnored private var historyCache: (revision: Int, byName: [String: [MFNCore.Transaction]])?
    @ObservationIgnored private let forecastCache = SnapshotIndex.ForecastCache()
    @ObservationIgnored private var plannedOverviewCache: (revision: Int, excluded: Set<AccountID>, value: PlannedOverview)?
    @ObservationIgnored private var budgetCache: (revision: Int, day: BankDay, statuses: [AccountID: BudgetStatus?]) = (-1, .today, [:])
    /// Accounts the user hid. A UI preference in `UserDefaults` (like the sidebar order): hidden
    /// accounts keep syncing, nothing is deleted.
    var hiddenAccountIDs: Set<AccountID> = AppModel.loadHiddenAccounts() {
        didSet {
            guard hiddenAccountIDs != oldValue else { return }
            UserDefaults.standard.set(hiddenAccountIDs.map(\.rawValue).sorted(), forKey: Self.hiddenAccountsKey)
            refreshSnapshot()
            if let id = selectedAccountID, hiddenAccountIDs.contains(id) { selection = .overview }
        }
    }
    /// Recurring payments the user said are none (Fixkosten → "Ausblenden"). A UI preference in
    /// `UserDefaults` like `hiddenAccountIDs`, but only as hashes: the IDs carry counterpart names,
    /// which belong into the encrypted database and nowhere else.
    var hiddenRecurring: Set<String> = AppModel.loadHiddenRecurring() {
        didSet {
            guard hiddenRecurring != oldValue else { return }
            UserDefaults.standard.set(hiddenRecurring.sorted(), forKey: Self.hiddenRecurringKey)
        }
    }
    /// Keys the hashes in `hiddenRecurring`. Derived from the database key by the store, held
    /// only while unlocked.
    @ObservationIgnored var recurringHashKey: SymmetricKey?
    /// What `Subscriptions.detect` found for a snapshot and day, computed off the main actor
    /// (Subscriptions.swift). `nil` until the first run finished.
    var recurringDetection: RecurringDetection?
    /// `recurringDetection` with the user's entries applied, per detection and entries.
    @ObservationIgnored var recurringCache: (version: Int, entries: [RecurringEntry], payments: [RecurringPayment])?
    /// Accounts left out of the bank sums and the overall total (still shown with their balance).
    /// A UI preference in `UserDefaults`, like `hiddenAccountIDs`.
    var excludedFromTotals: Set<AccountID> = AppModel.loadExcludedFromTotals() {
        didSet {
            guard excludedFromTotals != oldValue else { return }
            UserDefaults.standard.set(excludedFromTotals.map(\.rawValue).sorted(), forKey: Self.excludedFromTotalsKey)
        }
    }
    private(set) var vaultPrompt: VaultPrompt?
    private(set) var vaultError: String?
    /// The keychain refused the database key: the data is open, but every unlock asks for the
    /// database password. Shown as an alert.
    var keychainNotice: String?
    @ObservationIgnored private var keychainNoticeShown = false
    private(set) var isWorking = false
    var selection: SidebarItem? {
        didSet {
            guard selection != oldValue else { return }
            selectedTransactionIDs = []
            // A ⌘F request nobody picked up (e.g. on a depot) must not focus a later list, nor a
            // focus hand-over from the sidebar.
            searchFocusRequested = false
            focusRequest = nil
            readInThisList = []
        }
    }
    /// Selected rows in the transaction list. Selecting exactly one opens the inspector.
    var selectedTransactionIDs: Set<TransactionID> = [] {
        didSet {
            guard selectedTransactionIDs.count == 1, oldValue != selectedTransactionIDs else { return }
            showsInspector = true
            // Focusing one row reads it (a multiple selection does not, nor moving on after a review).
            if !selectsWithoutReading { markRead(selectedTransactionIDs) }
        }
    }
    var showsInspector = false
    /// Search, filter and sort of the transaction list. Kept while switching lists (like Finder's
    /// search); the account filter only applies to the overview lists.
    var ledgerQuery = TransactionQuery() {
        // Switching "Nur neue" / "Neue zuerst" on starts from what is unread now.
        didSet { if ledgerQuery.dependsOnNew, !oldValue.dependsOnNew { readInThisList = [] } }
    }
    /// ⌘F: set by the menu, the transaction list focuses its search field and resets it.
    var searchFocusRequested = false
    /// Keyboard: hands the focus between sidebar and content (→ or Return in the sidebar, ← or
    /// Esc in the content). The receiving view clears it.
    var focusRequest: FocusArea?

    enum FocusArea { case sidebar, content }
    /// Selected position in a depot (ISIN). Selecting one opens the inspector, like transactions.
    var selectedPositionISIN: String? {
        didSet { if selectedPositionISIN != nil, oldValue != selectedPositionISIN { showsInspector = true } }
    }
    /// Sidebar order of banks and accounts (drag and drop). A UI preference in `UserDefaults`, not
    /// ledger data; IDs of the demo and the live database never collide.
    var displayOrder = AppModel.loadDisplayOrder() {
        didSet {
            guard displayOrder != oldValue, let data = try? JSONEncoder().encode(displayOrder) else { return }
            UserDefaults.standard.set(data, forKey: Self.displayOrderKey)
        }
    }
    /// Appearance and app icon live here (not in `@AppStorage`): the UI reads the value it just
    /// set, instead of waiting for `UserDefaults` to report the change back.
    var appearance: AppearanceMode = .system {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: AppearanceMode.storageKey)
            appearance.apply()
        }
    }
    var appIcon: AppIconChoice = .dark {
        didSet {
            guard appIcon != oldValue else { return }
            UserDefaults.standard.set(appIcon.rawValue, forKey: AppIconChoice.storageKey)
            appIcon.apply()
        }
    }
    /// Sidebar visibility, toggled with ⌘B.
    var columnVisibility: NavigationSplitViewVisibility = .all
    var hideAmounts = false
    /// ⌥⌘S: cancelled transactions are hidden by default.
    var showCancelled = false
    /// Areas whose negative amounts are red (Settings → Darstellung), read once for all `AmountText`s.
    private(set) var negativeRed = NegativeRedAreas()
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    /// Rebuilds the index at midnight: curves, shortfalls and "this month" refer to its day.
    @ObservationIgnored private var dayObserver: NSObjectProtocol?
    /// Bank favicons, loaded from the banks' own websites (see `BankIconStore`).
    private(set) var bankIcons: [ConnectorID: NSImage] = [:]

    @ObservationIgnored private let databaseURL: URL
    /// Keychain account of the database key. Live mode uses its own, so setting up its database
    /// never replaces the key of the demo database.
    @ObservationIgnored private let keyAccount: String
    @ObservationIgnored private let registerConnectors: ConnectorRegistration
    @ObservationIgnored private var vault: LedgerVault?
    @ObservationIgnored private var keyStore: KeychainDatabaseKey?
    @ObservationIgnored private var store: EncryptedLedgerStore?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var categorization: CategorizationService?
    @ObservationIgnored private var categorizeTask: Task<Void, Never>?
    @ObservationIgnored private var categorizeAgain = false
    /// Sync runs started from the UI (unlock, ⌘R, new bank); cancelled when locking.
    @ObservationIgnored private var syncTasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped by every `close()`: an unlock that finishes after a lock (and maybe a new unlock)
    /// sees the change and drops the store it opened.
    @ObservationIgnored private var session = 0
    /// Stages after the rules: kNN and Foundation Models (live), the mock stage (demo).
    @ObservationIgnored private let machineStages: [any CategorizationStage]
    /// Deterministic stages before the learning ones. The demo keeps only the user's rules, so
    /// well-known merchants and transfers stay open for the "Kategorien einrichten" assistant.
    @ObservationIgnored private let presetStages: [any CategorizationStage]
    /// A categorization run is going on (after a sync or a rule change).
    private(set) var isCategorizing = false
    /// How far the background run is (`nil` before its first step and after it ends).
    private(set) var categorizationProgress: CategorizationProgress?
    /// A category the user chose could not be saved (alert over the main window).
    var categoryFailure: String?
    /// Settings → MCP.
    @ObservationIgnored private(set) lazy var assistantAccess = AssistantAccess(model: self)
    /// ⌘K: transactions whose category the picker sheet sets.
    var categoryPicker: CategoryPickerRequest?
    /// ⇧⌘K: the rule being created or edited in the sheet over the main window.
    var ruleDraft: RuleDraft?
    /// Open "Kategorien einrichten" assistant (sheet over the main window).
    var categorySetup: CategorySetup?
    /// Set by a successful sync: once its categorization run is through, offer the assistant
    /// (only once ever, see `offerCategorySetupIfNeeded`).
    @ObservationIgnored private var setupOfferPending = false
    @ObservationIgnored private lazy var iconStore: BankIconStore? = (try? BankIconStore.defaultCacheDirectory()).map(BankIconStore.init)

    /// Registers connectors for the opened store: the stored connections (live) or the mock banks (demo).
    typealias ConnectorRegistration = @MainActor (SyncEngine, any LedgerStore, AuthSheetPresenter) async throws -> Void

    /// Demo with mock banks (`MFN_DEMO=1`): no real connections can be added.
    let isDemo: Bool
    /// Which ledger this launch opened (Settings → Entwickler).
    let profile: LaunchProfile
    /// Credentials of the connections (keychain, see `CredentialStore`).
    let credentialStore = CredentialStore()
    /// Open "Bank hinzufügen" assistant, shown as sheet over the main window.
    var bankSetup: BankSetup?
    /// Open "Zusammenführen prüfen" report (sidebar context menu or menu bar, developer mode).
    var mergeCheck: MergeRequest?

    /// Merge pair for the selected account's bank: a FinTS bank with exactly one web connection of
    /// the same bank, or that web connection itself. Developer mode only.
    var mergeCandidate: MergeRequest? {
        guard DeveloperMode.isAvailable, !lock.isLocked, let bank = selectedAccount?.connectionID,
              let selected = ledger.connections.first(where: { $0.id == bank })
        else { return nil }
        let same = ledger.connections.filter { $0.connectorID == selected.connectorID && $0.id != selected.id }
        if BankAccess.of(selected).isFinTS {
            let sources = same.filter { !BankAccess.of($0).isFinTS }
            return sources.count == 1 ? sources.first.map { MergeRequest(source: $0, target: selected) } : nil
        }
        let targets = same.filter { BankAccess.of($0).isFinTS }
        return targets.count == 1 ? targets.first.map { MergeRequest(source: selected, target: $0) } : nil
    }

    init(
        databaseURL: URL,
        keyAccount: String = KeychainDatabaseKey.defaultAccount,
        isDemo: Bool,
        profile: LaunchProfile = .live,
        machineStages: [any CategorizationStage] = [],
        presetStages: [any CategorizationStage] = [RuleStage(), TransferStage(), KnownMerchantStage()],
        registerConnectors: @escaping ConnectorRegistration
    ) {
        self.databaseURL = databaseURL
        self.keyAccount = keyAccount
        self.isDemo = isDemo
        self.profile = profile
        self.machineStages = machineStages
        self.presetStages = presetStages
        self.registerConnectors = registerConnectors
        let defaults = UserDefaults.standard
        appearance = defaults.string(forKey: AppearanceMode.storageKey).flatMap(AppearanceMode.init) ?? .system
        appIcon = defaults.string(forKey: AppIconChoice.storageKey).flatMap(AppIconChoice.init) ?? .dark
        negativeRed = NegativeRedAreas.current()
        // Settings toggles them via `@AppStorage`; one observer here instead of three
        // `@AppStorage` in every `AmountText`.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let current = NegativeRedAreas.current()
                if self?.negativeRed != current { self?.negativeRed = current }
            }
        }
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }
        lock.onLock = { [weak self] in self?.close() }
        lock.onUnlock = { [weak self] context in await self?.unlocked(context) }
        assistantAccess.resume()
        lock.start()
    }

    /// Real banks (default), the demo (`MFN_DEMO=1`, `MFN_DEMO=headless` with a headless mock
    /// login) or the profile chosen in Settings → Entwickler (`LaunchProfile`).
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        switch environment["MFN_DEMO"]?.lowercased() {
        case nil, "", "0", "false", "no": break
        case "headless": return demo(headlessLogin: true)
        default: return demo(headlessLogin: false)
        }
        switch LaunchProfile.launched {
        case .live: return live()
        case .demo: return demo()
        case .fresh: return live(profile: .fresh)
        }
    }

    /// Encrypted demo ledger in the sandbox container, filled by the five mock banks. The data
    /// persists across launches.
    static func demo(headlessLogin: Bool = false) -> AppModel {
        var directory = "MFN"
        var keyAccount = KeychainDatabaseKey.defaultAccount
        var seedsAlways = false
        #if DEBUG
        // Website screenshots never show the demo ledger of this Mac (it may hold whatever was
        // tried in it, also a restored backup): they get a ledger of their own, new on every run.
        if ScreenshotMode.isActive {
            directory = "MFN-Screenshots"
            keyAccount = "ledger-key-screenshots-v1"
            seedsAlways = true
            if let old = try? databaseURL(directory: directory).deletingLastPathComponent() { try? FileManager.default.removeItem(at: old) }
            // The key of the ledger just deleted goes with it.
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainDatabaseKey.defaultService,
                kSecAttrAccount as String: keyAccount,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
        #endif
        let url = (try? databaseURL(directory: directory)) ?? FileManager.default.temporaryDirectory.appendingPathComponent(EncryptedLedgerStore.fileName)
        // The "once" marks belong to the persistent demo ledger; a new one is always filled.
        let fresh = seedsAlways
        let wasDone: @Sendable (String) -> Bool = { key in !fresh && UserDefaults.standard.bool(forKey: key) }
        let markDone: @Sendable (String) -> Void = { key in if !fresh { UserDefaults.standard.set(true, forKey: key) } }
        return AppModel(databaseURL: url, keyAccount: keyAccount, isDemo: true, profile: .demo, machineStages: [MockCategorizationStage()], presetStages: [RuleStage()]) { engine, store, presenter in
            if await store.snapshot().categoryRules.isEmpty {
                for rule in MockCategorizationStage.demoRules { try await store.upsertRule(rule) }
            }
            #if DEBUG
            // Website screenshots start from a new ledger: fill it with the demo data as it was a
            // few days ago first (the same history, without its newest days), so the sync that
            // follows brings transactions that are marked "Neu", and the example budgets, planned
            // payments and depot history below find their accounts.
            if await ScreenshotMode.isActive, await store.snapshot().connections.isEmpty {
                let current = MockDataset.demo()
                let seeding = SyncEngine(store: store)
                for connection in current.connections {
                    let connector = ScreenshotMode.EarlierConnector(
                        base: MockConnector(connection: connection.id, dataset: current, latency: .milliseconds(0)),
                        until: BankDay.today.adding(days: -ScreenshotMode.newDays))
                    try await seeding.register(connection, connector: connector)
                }
                await seeding.syncAll(trigger: .manual)
            }
            #endif
            // Once: automatic categories of earlier demo versions go (model guesses, known
            // merchants, transfers; not user rules or manual ones), so an existing demo ledger is
            // as open as a new one and the assistant is offered again.
            let resetKey = "demoMachineCategoriesReset.v3"
            if !wasDone(resetKey) {
                let automatic = await store.snapshot().transactions.filter { transaction in
                    switch transaction.categorySource {
                    case .knn, .llm: true
                    case .rule: (transaction.confidence ?? 1) < 1
                    default: false
                    }
                }
                try await store.clearCategories(Set(automatic.map(\.id)))
                markDone(resetKey)
                // The persistent demo's own setting: a screenshot run leaves it alone.
                if !fresh { UserDefaults.standard.removeObject(forKey: "categorySetupOffered.demo") }
            }
            // Once: example budgets (deleting them later sticks).
            let budgetsKey = "demoBudgets.v1"
            if !wasDone(budgetsKey) {
                let snapshot = await store.snapshot()
                let known = Set(snapshot.accounts.map(\.id))
                // A budget needs its account, and a demo bank that was never approved has none.
                // Each budget is added once on its own, so one missing bank does not bring back
                // budgets the user deleted on the others.
                for budget in MockDataset.demoBudgets where known.contains(budget.accountID) {
                    let key = "\(budgetsKey).\(budget.accountID.rawValue)"
                    guard !wasDone(key) else { continue }
                    if snapshot.budgets[budget.accountID] == nil { try await store.setBudget(budget) }
                    markDone(key)
                }
            }
            // Once: example planned payments on the salary account (deleting them later sticks).
            let plannedKey = "demoPlannedItems.v1"
            if !wasDone(plannedKey),
               await store.snapshot().accounts.contains(where: { $0.id == MockAccounts.ingGiro }) {
                for item in MockDataset.demoPlannedItems() {
                    try await store.upsertPlannedItem(item)
                }
                markDone(plannedKey)
            }
            let dataset = MockDataset.demo()
            // Once: depot history up to yesterday (the banks deliver none; syncs add today).
            let depotKey = "demoDepotHistory.v1"
            // The depot accounts must exist (first sync of a new demo ledger), else next launch.
            if !wasDone(depotKey) {
                let known = Set(await store.snapshot().accounts.map(\.id))
                if dataset.accounts.filter({ $0.type == .depot }).allSatisfy({ known.contains($0.id) }) {
                    try await store.recordDepotValues(dataset.demoDepotHistory())
                    markDone(depotKey)
                }
            }
            var pairs = headlessLogin ? dataset.demoConnectorsWithHeadlessLogin(presenter: nil) : dataset.demoConnectors(presenter: nil)
            #if DEBUG
            // Website screenshots: no approval sheets in the picture, every demo bank syncs cleanly.
            if await ScreenshotMode.isActive {
                pairs = dataset.connections.map { ($0, MockConnector(connection: $0.id, dataset: dataset, latency: .milliseconds(200))) }
            }
            #endif
            #if DEBUG
            let freshBookings = await !ScreenshotMode.isActive
            #else
            let freshBookings = true
            #endif
            for (connection, connector) in pairs {
                var connector = connector
                connector.presenter = presenter.scoped(to: connection)
                // Something new on every sync, so the demo shows "Neu seit dem Abgleich".
                connector.deliversFreshBookings = freshBookings
                try await engine.register(connection, connector: connector)
            }
        }
    }

    /// The real ledger: database in `MFN-Live/` with keychain key `ledger-key-live-v1` (kept from
    /// the former `MFN_LIVE` test mode, so its data stays). Every stored connection is registered
    /// with its connector; banks are added in the "Bank hinzufügen" assistant.
    /// `profile: .fresh` is the same with an empty test ledger (`MFN-Test/`, own keychain key).
    static func live(profile: LaunchProfile = .live) -> AppModel {
        let url = (try? databaseURL(directory: profile.directory))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(profile.directory + "-" + EncryptedLedgerStore.fileName)
        // Cascade after the rules: kNN over the user's own bookings, then the on-device language
        // model (CLAUDE.md §8). One shared embedding, so few-shots and neighbours reuse its cache.
        let embedding = HybridEmbedding()
        // Settings → Kategorien: the user can leave the model out (slow Macs). Read before every
        // model batch, so switching takes effect in a running run.
        let language = LLMStage(embedding: embedding, isEnabled: { UserDefaults.standard.bool(forKey: Preferences.useCategoryModel) })
        language.prewarm()
        return AppModel(databaseURL: url, keyAccount: profile.keyAccount, isDemo: false, profile: profile, machineStages: [KNNStage(embedding: embedding), language]) { engine, store, presenter in
            for connection in await store.snapshot().connections {
                // Connections without a connector in this build (ING/DKB until the FinTS product
                // ID) keep their data but are not synced.
                guard let connector = ConnectorFactory.make(connection, presenter: presenter.scoped(to: connection)) else { continue }
                try await engine.register(connection, connector: connector)
            }
        }
    }

    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/MFN/ledger.sqlite`
    /// (next to it: `ledger.key`, the password-protected key).
    static func databaseURL(directory: String = "MFN") throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(EncryptedLedgerStore.fileName)
    }

    // MARK: - Unlock flow

    private func unlocked(_ context: sending LAContext) async {
        let session = self.session
        let keyStore = KeychainDatabaseKey(context: context, account: keyAccount)
        let vault = LedgerVault(databaseURL: databaseURL, keyStore: keyStore)
        self.keyStore = keyStore
        self.vault = vault
        do {
            switch try vault.state() {
            case .ready:
                await finishOpening(try await vault.open(), session: session)
            case .needsSetup:
                vaultPrompt = .setup
                #if DEBUG
                // The screenshot ledger is thrown away with the next run: nobody has to think of
                // a password for it.
                if ScreenshotMode.isActive { await submitPassword(UUID().uuidString + UUID().uuidString) }
                #endif
            case .needsPassword:
                vaultPrompt = .password
            }
        } catch {
            lock.lock(problem: Self.problem(for: error))
        }
    }

    /// Called by `VaultPasswordView`.
    func submitPassword(_ password: String) async {
        guard let vault, let prompt = vaultPrompt, !isWorking else { return }
        let session = self.session
        isWorking = true
        defer { isWorking = false }
        do {
            let opened = switch prompt {
            case .setup: try await vault.setUp(password: password)
            case .password: try await vault.recover(password: password)
            }
            vaultPrompt = nil
            vaultError = nil
            await finishOpening(opened.store, session: session)
            // Once per launch: the password prompt on every unlock explains itself after that.
            if let refusal = opened.keyNotStored, !keychainNoticeShown, !isStale(session) {
                keychainNoticeShown = true
                keychainNotice = Self.keychainNotice(for: refusal)
            }
        } catch {
            switch error {
            case .wrongPassword, .weakPassword:
                vaultError = Self.message(for: error)
            default:
                vaultPrompt = nil
                lock.lock(problem: Self.problem(for: error))
            }
        }
    }

    func cancelPasswordPrompt() {
        lock.lock()
    }

    /// The database is open (unlocked and set up): MCP may read `ledger`.
    var isLedgerOpen: Bool { store != nil }

    /// The current unlock; read before an `await`, checked with `isStale` after it.
    var lockSession: Int { session }

    /// Locked (and maybe unlocked again) since `session` was read: this store is not ours anymore.
    func isStale(_ session: Int) -> Bool {
        lock.isLocked || session != self.session
    }

    private func finishOpening(_ store: EncryptedLedgerStore, session: Int) async {
        // Locked again while the database was opening.
        guard !isStale(session) else {
            await store.close()
            return
        }
        // New transactions come from successful syncs (manual, timer, unlock, new bank):
        // categorize them right after each one.
        let engine = SyncEngine(store: store, afterSync: { [weak self] _ in
            await self?.syncSucceeded()
        })
        do {
            try await registerConnectors(engine, store, presenter)
        } catch {
            await store.close()
            if !isStale(session) { lock.lock(problem: Self.problem(for: error)) }
            return
        }
        // Locked while the connectors registered: nothing may be assigned or started behind the
        // lock screen.
        guard !isStale(session) else {
            await store.close()
            return
        }
        self.store = store
        self.engine = engine
        recurringHashKey = await store.preferenceHashKey()
        assistantAccess.verifySettings(accounts: await store.snapshot().accounts.map(\.id))
        // Deterministic stages first (user rules, own transfers, well-known merchants), then the
        // learning ones. Works without Apple Intelligence: the first three need no model.
        categorization = CategorizationService(
            store: store,
            categorizer: Categorizer(stages: presetStages + machineStages),
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, !self.isStale(session) else { return }
                    self.categorizationProgress = progress
                }
            }
        )
        let defaults = UserDefaults.standard
        hideAmounts = defaults.bool(forKey: Preferences.hideAmountsOnUnlock)
        showCancelled = defaults.bool(forKey: Preferences.showCancelledByDefault)
        let syncsNow = defaults.bool(forKey: Preferences.syncOnUnlock)
        if syncsNow {
            // The user is at the Mac: logins may ask for approval (unlike the timer).
            startSync { await engine.syncAll(trigger: .unlock) }
        }
        // Transactions from before categorization existed, or from an interrupted run.
        categorizeInBackground()
        // First view after unlocking, unless something chose one already (menu bar panel).
        if selection == nil { selection = .overview }
        loadBankIcons()
        scheduleAutoSync()
        // With a sync starting now the backup waits for its end (`syncSucceeded`): copying the
        // database while it is being written and categorized makes both slower.
        if !syncsNow { runAutoBackupIfDue() }
        // Secrets of removed connections whose deletion did not finish (failure, crash). A
        // connection that exists again (same ID) is left alone.
        let pending = PendingCleanup.all.filter { stale in !ledger.connections.contains { $0.id == stale.id } }
        if !pending.isEmpty {
            Task(priority: .background) {
                for connection in pending { await Self.deleteSecrets(of: connection) }
            }
        }
        observation = Task { [weak self] in
            for await snapshot in await store.updates() {
                self?.ledger = snapshot
            }
        }
    }

    /// Lock: stop observing, drop everything decrypted, close the database, invalidate the key access.
    private func close() {
        session &+= 1
        assistantAccess.locked()
        bankSetup?.abandon()
        bankSetup = nil
        presenter.cancelAll()
        observation?.cancel()
        observation = nil
        autoSyncTask?.cancel()
        autoSyncTask = nil
        categorizeTask?.cancel()
        categorizeTask = nil
        categorizeAgain = false
        isCategorizing = false
        categorizationProgress = nil
        categoryFailure = nil
        for task in syncTasks.values { task.cancel() }
        syncTasks = [:]
        // The run stops before its next model batch; what it saved stays.
        if let categorization { Task { await categorization.cancel() } }
        categorization = nil
        categoryPicker = nil
        ruleDraft = nil
        categorySetup = nil
        setupOfferPending = false
        keyStore?.invalidate()
        keyStore = nil
        vault = nil
        vaultPrompt = nil
        vaultError = nil
        if let store {
            Task { await store.close() }
        }
        store = nil
        engine = nil
        ledger = LedgerSnapshot()
        selection = nil
        selectedTransactionIDs = []
        selectedPositionISIN = nil
        showsInspector = false
        budgetEditor = nil
        forecastPanel = nil
        csvImport?.cancel()
        csvImport = nil
        csvImportFailure = nil
        isOpeningCSV = false
        // Ends the save sheet; its completion sees the lock and writes nothing.
        csvExportPanel?.cancel(nil)
        csvExportPanel = nil
        backupPanel?.cancel(nil)
        backupPanel = nil
        restoreRequest = nil
        recurringHashKey = nil
        recurringDetection = nil
        // Alerts and reports over decrypted rows (counts, account names, transactions).
        importRemoval = nil
        importRemovalFailure = nil
        importIndexCache = nil
        mergeCheck = nil
        // The search text names counterparts; caches hold decrypted transactions.
        ledgerQuery.text = ""
        ledgerCache = nil
        ledgerBaseCache = nil
        historyCache = nil
        budgetCache = (-1, .today, [:])
        plannedOverviewCache = nil
        forecastCache.entries = [:]
        index = SnapshotIndex()
        initiators = [:]
        sharedAccounts = []
    }

    /// Runs a sync started from the UI; kept so locking can cancel it.
    private func startSync(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        syncTasks[id] = Task { [weak self] in
            await operation()
            self?.syncTasks[id] = nil
            // Also when every bank failed (no `syncSucceeded`): a due backup is not skipped.
            self?.runAutoBackupIfDue()
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case VaultError.wrongPassword:
            "Das Passwort ist falsch."
        case let VaultError.weakPassword(minimum):
            "Das Passwort muss mindestens \(minimum) Zeichen haben."
        case VaultError.key(.authenticationCancelled):
            "Entsperren abgebrochen."
        case VaultError.key(.keychain):
            "MFN konnte den Schlüssel der Datenbank nicht im Schlüsselbund speichern oder lesen."
        case VaultError.key(.missingEntitlement):
            "Die App ist nicht korrekt signiert (Schlüsselbund-Berechtigung fehlt)."
        case VaultError.keyUnrecoverable:
            "Für diese Datenbank gibt es weder einen Schlüssel auf diesem Mac noch eine Passwort-Datei (ledger.key). Die Daten können nicht entschlüsselt werden."
        case VaultError.store(.cannotDecrypt):
            "Die Datenbank lässt sich mit diesem Schlüssel nicht entschlüsseln."
        case VaultError.store(.newerSchema), StoreError.newerSchema:
            "Diese Datenbank stammt aus einer neueren Version von MFN."
        default:
            "Die Datenbank konnte nicht geöffnet werden."
        }
    }

    /// The status code is not sensitive and is what a bug report needs.
    static func keychainNotice(for error: DatabaseKeyError) -> String {
        let code = if case let .keychain(status) = error { "Schlüsselbund-Fehler \(status)" } else { errorKind(error) }
        return "Deine Daten sind geöffnet und bleiben verschlüsselt. MFN konnte den Schlüssel der Datenbank aber nicht im Schlüsselbund dieses Macs ablegen und fragt deshalb bei jedem Entsperren nach dem Datenbank-Passwort. Bitte schick uns diesen Code: \(code)"
    }

    /// What the lock screen shows when the data could not be opened: a plain sentence, what to do,
    /// and the technical detail only where the sentence cannot say more.
    static func problem(for error: any Error) -> AppLock.Problem {
        switch error {
        case let VaultError.store(.newerSchema(found, supported)), let StoreError.newerSchema(found, supported):
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            return AppLock.Problem(
                message: message(for: error),
                hint: "Deine Daten sind unverändert. Mit der aktuellen Version von MFN lässt sich die Datenbank wieder öffnen.",
                detail: "MFN \(version) kennt Schema bis \(supported), die Datenbank hat Schema \(found).",
                action: .update
            )
        case let VaultError.key(.keychain(status)):
            // The status code is not sensitive and is what a bug report needs.
            return AppLock.Problem(
                message: message(for: error),
                hint: "Deine Daten bleiben unverändert. Versuche es erneut. Wenn es wieder passiert, schick uns bitte den Code unten.",
                detail: "Schlüsselbund-Fehler \(status)"
            )
        case VaultError.wrongPassword, VaultError.weakPassword, VaultError.key(.authenticationCancelled),
             VaultError.key(.missingEntitlement), VaultError.keyUnrecoverable, VaultError.store(.cannotDecrypt):
            return AppLock.Problem(message: message(for: error))
        default:
            return AppLock.Problem(
                message: message(for: error),
                hint: "Deine Daten bleiben unverändert. Versuche es erneut oder starte MFN neu.",
                detail: errorKind(error)
            )
        }
    }

    /// "StoreError.corruptRow", "VaultError.store(StoreError.cannotOpen)": type and case only. The
    /// lock screen shows this before authentication, so never associated values (row contents,
    /// paths, messages).
    static func errorKind(_ error: any Error) -> String {
        let type = String(describing: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return type }
        guard let payload = mirror.children.first else {
            // A case without payload prints as its name, unless the type describes itself.
            return error is any CustomStringConvertible ? type : "\(type).\(String(describing: error))"
        }
        guard let label = payload.label else { return type }
        // One level down when the payload is the underlying error (`VaultError.store(_)`).
        let inner: any Error
        if let error = payload.value as? any Error {
            inner = error
        } else if let tuple = Mirror(reflecting: payload.value).children.first?.value as? any Error {
            inner = tuple
        } else {
            return "\(type).\(label)"
        }
        return "\(type).\(label)(\(errorKind(inner)))"
    }

    // MARK: - Commands

    func syncAll() {
        guard let engine else { return }
        startSync { await engine.syncAll(trigger: .manual) }
    }

    func syncConnection(_ id: ConnectionID) {
        guard let engine else { return }
        startSync { await engine.sync(id, trigger: .manual) }
    }

    func syncSelectedConnection() {
        guard let account = selectedAccount, canSync(account.connectionID) else { return }
        syncConnection(account.connectionID)
    }

    /// `false` for accounts without a bank connection (v10, `ConnectorID.manual`): they have
    /// nothing to sync, so their sync buttons and menu items are hidden or disabled.
    func canSync(_ id: ConnectionID) -> Bool {
        ledger.connections.first { $0.id == id }?.connectorID.hasConnector ?? false
    }

    /// The selected account's bank can be synced (⇧⌘R).
    var canSyncSelectedConnection: Bool {
        !lock.isLocked && selectedAccount.map { canSync($0.connectionID) } == true
    }

    // MARK: - Banks

    /// "Bank hinzufügen…" is possible while unlocked, outside the demo.
    var canAddBank: Bool { !lock.isLocked && engine != nil && !isDemo }

    func showBankSetup() {
        guard canAddBank, bankSetup == nil else { return }
        bankSetup = BankSetup(model: self)
    }

    /// "Konto ohne Anbindung anlegen …" from the "Konten" menu: the assistant opens directly
    /// on that form (from the bank list it switches there instead).
    func showManualAccountSetup() {
        guard canAddBank, bankSetup == nil else { return }
        let setup = BankSetup(model: self)
        setup.startManualAccount()
        bankSetup = setup
    }

    /// "Konto bearbeiten …" of an account without a bank connection: type, currency, IBAN, opening balance.
    func showManualAccountEditor(for account: Account) {
        guard canAddBank, bankSetup == nil, isManual(account.id) else { return }
        let setup = BankSetup(model: self)
        setup.startManualAccount(editing: account, opening: ledger.openingBalances[account.id])
        bankSetup = setup
    }

    /// The account belongs to an account without a bank connection (v10).
    func isManual(_ account: AccountID) -> Bool {
        guard let connection = self.account(account)?.connectionID else { return false }
        return ledger.connections.first { $0.id == connection }?.isManual == true
    }

    enum ManualAccountOutcome {
        /// `balanceStale`: saved, but the computed balance could not be written (twice); the
        /// sidebar may show the old one until the next import or edit.
        case saved(AccountID, balanceStale: Bool)
        case failed(String)
    }

    /// Creates (or, with `editing`, changes) an account without a bank connection: connection and
    /// account through the regular store calls, the opening balance, then the computed balance.
    /// Never registered with the sync engine. A new one is removed again if a later write fails.
    func saveManualAccount(_ fields: ManualAccountFields, editing: Account? = nil) async -> ManualAccountOutcome {
        guard let store, !lock.isLocked else { return .failed("MFN ist gesperrt.") }
        // Stored amounts are in the account's currency; the form locks the picker, this is the backstop.
        if let editing, editing.currency != fields.currency, ledger.transactions.contains(where: { $0.accountID == editing.id }) {
            return .failed("Die Währung lässt sich nicht ändern, solange das Konto Umsätze hat.")
        }
        let session = lockSession
        let ids = editing.map { ($0.connectionID, $0.id) } ?? ManualAccount.newIDs()
        let connection = Connection(id: ids.0, connectorID: .manual, displayName: fields.name)
        let account = Account(id: ids.1, connectionID: ids.0, iban: fields.iban, type: fields.type, currency: fields.currency,
                              name: editing?.name ?? fields.name)
        do {
            if editing == nil { try await store.upsert(connection: connection) }
            try await store.replaceAccounts([account], of: connection.id)
            try await store.setOpeningBalance(fields.opening, for: account.id)
        } catch {
            Log.logger("app").error("Konto ohne Anbindung nicht gespeichert: \(String(describing: type(of: error)), privacy: .public)")
            if editing == nil {
                do {
                    try await store.removeConnection(connection.id)
                } catch {
                    Log.logger("app").error("Halb angelegtes Konto nicht entfernt: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
            return .failed(isStale(session) ? "MFN ist gesperrt." : "Das Konto konnte nicht gespeichert werden.")
        }
        // Locked while saving: the store is closed, nothing more to write or select.
        guard !isStale(session) else { return .failed("MFN ist gesperrt.") }
        // The account and opening balance are stored; only the derived balance is left. One retry,
        // then report it as possibly stale instead of "not saved".
        var balanceStale = false
        for attempt in 1...2 {
            do {
                try await recomputeManualBalance(of: account.id, in: store)
                break
            } catch {
                Log.logger("app").error("Kontostand nicht neu berechnet (Versuch \(attempt, privacy: .public)): \(String(describing: type(of: error)), privacy: .public)")
                balanceStale = attempt == 2
            }
        }
        guard !isStale(session) else { return .failed("MFN ist gesperrt.") }
        if editing == nil { selection = .account(account.id) }
        return .saved(account.id, balanceStale: balanceStale)
    }

    /// Opening balance plus booked transactions → `setBalance` (accounts without a bank
    /// connection only; others keep what their bank reported).
    private func recomputeManualBalance(of account: AccountID, in store: some LedgerStore) async throws {
        guard let balance = await store.snapshot().computedManualBalance(of: account, asOf: Date()) else { return }
        try await store.setBalance(balance, for: account)
    }

    /// After rows were removed: recomputes the balance of accounts without a bank connection
    /// (no-op for real banks, whose balance comes from the bank).
    func recomputeManualBalances(_ accounts: Set<AccountID>) async {
        guard let store else { return }
        for account in accounts {
            do {
                try await recomputeManualBalance(of: account, in: store)
            } catch {
                Log.logger("app").error("Kontostand nicht neu berechnet: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Registers a connection found in the assistant and starts its first sync (full history:
    /// it never synced before).
    func addConnection(_ connection: Connection, connector: any BankConnector) async throws {
        guard let engine else { throw ConnectorError.cancelled }
        try await engine.register(connection, connector: connector)
        // Locked while registering: the engine is gone, nothing starts behind the lock screen.
        guard !lock.isLocked, self.engine === engine else { throw ConnectorError.cancelled }
        selection = .overview
        let id = connection.id
        startSync { await engine.sync(id, trigger: .manual) }
    }

    /// "Bank entfernen": stops its sync, deletes connection, accounts, transactions, sync state,
    /// credentials, session and the connection's web data store. Returns an error text or `nil`.
    func removeConnection(_ connection: Connection) async -> String? {
        guard let store else { return "MFN ist gesperrt." }
        presenter.cancel(connection: connection.id)
        await engine?.unregister(connection.id)
        if let accountID = selectedAccountID, account(accountID)?.connectionID == connection.id {
            selection = .overview
        }
        do {
            try await store.removeConnection(connection.id)
        } catch {
            return connection.isManual ? "Das Konto konnte nicht entfernt werden: \(error)" : "Die Bank konnte nicht entfernt werden: \(error)"
        }
        displayOrder.connections.removeAll { $0 == connection.id.rawValue }
        displayOrder.accounts[connection.id.rawValue] = nil
        // An account without a bank connection has no credentials, session or web data store.
        if !connection.isManual { await Self.deleteSecrets(of: connection) }
        return nil
    }

    enum MergeOutcome {
        /// Done; `backup` is the encrypted copy taken before (the user may delete it).
        case merged(backup: URL)
        case failed(String)
    }

    /// Merges `source` (web banking) into `target` (FinTS, same bank): an encrypted backup, then
    /// moves, categories, account names, budgets and the removal of `source` in one database
    /// transaction (`LedgerStore.applyMerge`), then the hidden/totals/order settings and the
    /// secrets of `source`. Both connections are paused meanwhile, so no sync writes in between;
    /// the plan is computed again from the current ledger, off the main actor.
    func mergeConnection(_ source: Connection, into target: Connection) async -> MergeOutcome {
        guard let store else { return .failed("MFN ist gesperrt.") }
        for id in [source.id, target.id] {
            switch ledger.syncStates[id]?.phase {
            case .syncing?, .waitingForApproval?: return .failed("Bitte warten, bis der Abgleich beendet ist.")
            default: break
            }
        }
        // Irreversible from here: first an encrypted copy of the database next to it.
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let backup = databaseURL.deletingLastPathComponent().appendingPathComponent("ledger-vor-zusammenfuehren-\(stamp).sqlite")
        do {
            try await store.backup(to: backup)
        } catch {
            return .failed("Keine Sicherung möglich, nichts geändert: \(error)")
        }
        // No sync may write into either connection while they are merged (unregister waits for a running one).
        await engine?.unregister(source.id)
        await engine?.unregister(target.id)
        let snapshot = await store.snapshot()
        let changes: ConnectionMerge.Changes
        do {
            changes = try await Task.detached(priority: .userInitiated) {
                ConnectionMerge.changes(try ConnectionMerge.plan(snapshot, source: source.id, target: target.id), in: snapshot)
            }.value
            try await store.applyMerge(changes)
        } catch {
            // One transaction: nothing changed. Both banks sync again.
            await reregister([source, target])
            return .failed("Zusammenführen fehlgeschlagen, nichts geändert: \(error)")
        }
        await reregister([target])
        for (old, new) in changes.accounts {
            if isHidden(old) { setHidden(true, account: new) }
            if !isCountedInTotals(old) { setCountedInTotals(false, account: new) }
        }
        // The target takes the source's place and account order in the sidebar.
        let mappedOrder = (displayOrder.accounts[source.id.rawValue] ?? []).compactMap { changes.accounts[AccountID($0)]?.rawValue }
        let rest = (displayOrder.accounts[target.id.rawValue] ?? []).filter { !mappedOrder.contains($0) }
        displayOrder.accounts[target.id.rawValue] = mappedOrder + rest
        if let index = displayOrder.connections.firstIndex(of: source.id.rawValue) {
            displayOrder.connections.removeAll { $0 == target.id.rawValue }
            displayOrder.connections.insert(target.id.rawValue, at: min(index, displayOrder.connections.count))
        }
        displayOrder.connections.removeAll { $0 == source.id.rawValue }
        displayOrder.accounts[source.id.rawValue] = nil
        if let selected = selectedAccountID, let mapped = changes.accounts[selected] {
            selection = .account(mapped)
        }
        presenter.cancel(connection: source.id)
        await Self.deleteSecrets(of: source)
        return .merged(backup: backup)
    }

    /// Registers connections with the engine again (after a pause), like at unlock.
    private func reregister(_ connections: [Connection]) async {
        guard let engine else { return }
        for connection in connections {
            guard let connector = ConnectorFactory.make(connection, presenter: presenter.scoped(to: connection)) else { continue }
            do {
                try await engine.register(connection, connector: connector)
            } catch {
                Log.logger("app").error("Bank nicht wieder angemeldet: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Deletes a backup taken before a merge. Returns an error message, `nil` on success.
    func deleteBackup(_ url: URL) -> String? {
        guard url.deletingLastPathComponent() == databaseURL.deletingLastPathComponent(),
              url.lastPathComponent.hasPrefix("ledger-vor-zusammenfuehren-")
        else { return "Das ist keine Sicherung von MFN." }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return "Sicherung nicht löschbar: \(error.localizedDescription)"
        }
    }

    /// Credentials, session cookies, FinTS system ID and web data store of a connection. The
    /// connection is noted in `PendingCleanup` first and taken off only when everything is gone;
    /// after a failure (or a crash) the next unlock tries again.
    static func deleteSecrets(of connection: Connection) async {
        PendingCleanup.add(connection)
        var complete = true
        do {
            try ConnectionSecrets.deleteAll(connection: connection.id, connector: connection.connectorID)
        } catch {
            complete = false
            Log.logger("app").error("Zugangsdaten nicht löschbar: \(String(describing: type(of: error)), privacy: .public)")
        }
        if BankAccess.of(connection).isFinTS {
            do {
                try FinTSConnection.deleteState(of: connection)
            } catch {
                complete = false
                Log.logger("app").error("FinTS-System-ID nicht löschbar: \(String(describing: type(of: error)), privacy: .public)")
            }
        } else {
            // FinTS connections never open a web view, so only the others have a web data store.
            await WebDataStoreCleanup.remove(connection.id)
        }
        if complete { PendingCleanup.remove(connection.id) }
    }

    /// Secrets whose deletion did not finish (see `deleteSecrets`). Profile-scoped, and only
    /// connections MFN itself removed: nothing else is touched.
    enum PendingCleanup {
        static var key: String { LaunchProfile.launched.scoped("pendingSecretCleanup") }

        static var all: [Connection] {
            (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { entry in
                let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let connector = ConnectorID(rawValue: parts[0]) else { return nil }
                return Connection(id: ConnectionID(parts[1]), connectorID: connector, displayName: "")
            }
        }

        static func add(_ connection: Connection) {
            let entry = "\(connection.connectorID.rawValue)|\(connection.id.rawValue)"
            var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
            guard !entries.contains(entry) else { return }
            entries.append(entry)
            UserDefaults.standard.set(entries, forKey: key)
        }

        static func remove(_ id: ConnectionID) {
            let entries = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !$0.hasSuffix("|\(id.rawValue)") }
            UserDefaults.standard.set(entries, forKey: key)
        }
    }

    /// "Zugangsdaten ändern…": stores the new credentials; the next login uses them.
    func updateCredentials(_ credentials: BankCredentials, for connection: Connection) throws {
        try credentialStore.set(credentials, for: connection.id)
        // New credentials lift the block after a rejected login (no retry with the old ones).
        if let engine { Task { await engine.credentialsChanged(connection.id) } }
    }

    func toggleSidebar() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// (Re)starts the periodic automatic sync from Settings. Runs only while unlocked; the
    /// engine still skips banks synced < 15 min ago, after login errors or 3 failures.
    func scheduleAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        guard engine != nil, UserDefaults.standard.bool(forKey: Preferences.autoSync) else { return }
        let interval = Preferences.autoSyncInterval
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let engine = self?.engine else { return }
                await engine.syncAll(trigger: .automatic)
            }
        }
    }

    /// Loads (or drops, if disabled in Settings) the bank favicons.
    func loadBankIcons() {
        guard UserDefaults.standard.bool(forKey: Preferences.loadBankIcons), let iconStore else {
            bankIcons = [:]
            return
        }
        let connectors = Set(snapshot.connections.map(\.connectorID)).union(ConnectorID.allCases.filter { $0 != .mock })
            .filter(\.hasConnector)
        for connector in connectors where bankIcons[connector] == nil {
            Task { [weak self] in
                guard let data = await iconStore.icon(for: connector), let image = NSImage(data: data) else { return }
                self?.bankIcons[connector] = image
            }
        }
    }

    /// Re-wraps the database key with a new password (`ledger.key`); the database is untouched.
    func changePassword(from old: String, to new: String) async throws(VaultError) {
        guard let vault else { throw .keyUnrecoverable }
        // PBKDF2 with 2 M iterations runs twice: keep it off the main actor.
        let result = await Task.detached { () -> Result<Void, VaultError> in
            Result { () throws(VaultError) in try vault.changePassword(from: old, to: new) }
        }.value
        try result.get()
    }

    var canChangePassword: Bool { !lock.isLocked && vaultPrompt == nil }

    // MARK: - Backup (Backup.swift)

    /// The vault of this unlock: also while the password prompt is up, before any database is open.
    var backupVault: LedgerVault? { vault }
    var backupStore: EncryptedLedgerStore? { store }
    /// Automatic backup into a folder the user chose (Settings → Sicherung).
    @ObservationIgnored private(set) lazy var autoBackup = AutoBackup(profile: profile)

    /// After a restore on the setup screen: the database from the backup is in place, open it
    /// the way a copied database is opened (key into the keychain, connectors, first view).
    func openRestoredDatabase(password: String) async {
        guard vault != nil, store == nil, !lock.isLocked else { return }
        vaultPrompt = .password
        vaultError = nil
        await submitPassword(password)
    }

    var databaseURLForDisplay: URL { databaseURL }

    static func message(forPasswordChange error: VaultError) -> String {
        switch error {
        case .wrongPassword: "Das bisherige Passwort ist falsch."
        case let .weakPassword(minimum): "Das neue Passwort muss mindestens \(minimum) Zeichen haben."
        default: "Passwort konnte nicht geändert werden: \(error)"
        }
    }


    // MARK: - Categories

    /// Categorizes every transaction without a category in the background (after syncs, rule
    /// changes, unlocking). One run at a time; asked again while running, it runs once more.
    func categorizeInBackground() {
        guard categorization != nil else { return }
        guard categorizeTask == nil else {
            categorizeAgain = true
            return
        }
        isCategorizing = true
        categorizeTask = Task { [weak self] in
            repeat {
                guard let self, let service = self.categorization, !Task.isCancelled else { break }
                self.categorizeAgain = false
                do {
                    let report = try await service.categorizeUncategorized()
                    Log.logger("categorize").info("Kategorisiert: \(report.categorized, privacy: .public), zu prüfen: \(report.needsReview, privacy: .public)")
                } catch {
                    Log.logger("categorize").error("Kategorisierung fehlgeschlagen: \(String(describing: type(of: error)), privacy: .public)")
                }
            } while self?.categorizeAgain == true && !Task.isCancelled
            // A lock cancelled this run and may have started a new one after unlocking.
            guard !Task.isCancelled else { return }
            // A run long enough to show progress says when it is done (VoiceOver).
            if self?.categorizationProgress != nil {
                AccessibilityNotification.Announcement("Kategorisierung abgeschlossen").post()
            }
            self?.categorizeTask = nil
            self?.isCategorizing = false
            await self?.offerCategorySetupIfNeeded()
        }
    }

    private func syncSucceeded() {
        setupOfferPending = true
        categorizeInBackground()
        runAutoBackupIfDue()
    }

    // MARK: - Category setup assistant

    /// `UserDefaults`: the assistant was offered on its own once (demo and live separately).
    var setupOfferedKey: String { profile.scoped("categorySetupOffered") }

    /// Settings → Entwickler: empties the test profile (credentials and web data of its banks,
    /// database, keychain key) and starts MFN again as a fresh install. Only in the test profile
    /// and while unlocked, so the banks whose credentials go are known.
    func resetTestProfile() async throws(DeveloperMode.Failure) {
        guard profile == .fresh, !lock.isLocked else { return }
        // A bank being added is not in the ledger yet: its secrets go too.
        var connections = snapshot.connections
        if let pending = bankSetup?.connection, !connections.contains(where: { $0.id == pending.id }) {
            connections.append(pending)
        }
        let store = self.store
        lock.lock()
        await store?.close()
        for connection in connections { await Self.deleteSecrets(of: connection) }
        try DeveloperMode.wipeTestProfile()
        try await DeveloperMode.relaunch()
    }

    /// Settings → Entwickler: next launch opens `profile`. Only while unlocked.
    func switchProfile(to profile: LaunchProfile) async throws(DeveloperMode.Failure) {
        guard !lock.isLocked else { return }
        // `close()` abandons an unfinished "Bank hinzufügen" in a task; quitting must not cut it short.
        let pending = bankSetup?.connection.flatMap { connection in
            snapshot.connections.contains { $0.id == connection.id } ? nil : connection
        }
        let store = self.store
        UserDefaults.standard.set(profile.rawValue, forKey: LaunchProfile.storageKey)
        lock.lock()
        await store?.close()
        if let pending { await Self.deleteSecrets(of: pending) }
        try await DeveloperMode.relaunch()
    }

    var canShowCategorySetup: Bool { canCategorize && categorySetup == nil && bankSetup == nil }

    /// Menu "Umsatz → Kategorien einrichten …", Settings → Kategorien.
    func showCategorySetup() {
        guard canShowCategorySetup else { return }
        let setup = CategorySetup(model: self)
        categorySetup = setup
        Task { await setup.refresh() }
    }

    /// After the first successful sync (and its categorization): opens the assistant once if
    /// most transactions are still open. Never again after that, whatever the user did.
    private func offerCategorySetupIfNeeded() async {
        let defaults = UserDefaults.standard
        guard setupOfferPending, !defaults.bool(forKey: setupOfferedKey) else { return }
        #if DEBUG
        if ScreenshotMode.isActive { return }   // no setup sheet in website screenshots
        #endif
        // Another sheet is up (bank assistant, approval, ⌘K): ask again after the next run.
        guard canShowCategorySetup, presenter.current == nil else { return }
        setupOfferPending = false
        guard let plan = await setupPlan() else { return }
        // Remember the first look even if the plan says no: a later sync must not push it either.
        defaults.set(true, forKey: setupOfferedKey)
        guard plan.suggestsSetup, canShowCategorySetup else { return }
        showCategorySetup()
    }

    func setupPlan() async -> SetupPlan? {
        guard let service = categorization else { return nil }
        return await service.setupPlan()
    }

    /// Manual categories from the assistant's rest step; waits for the store. Returns an error text.
    func setManualCategory(_ category: CategoryID?, for ids: [TransactionID]) async -> String? {
        guard let service = categorization else { return "MFN ist gesperrt." }
        do {
            try await service.setManual(category, for: ids)
            return nil
        } catch {
            return "Die Kategorie konnte nicht gespeichert werden: \(error)"
        }
    }

    /// Category commands are possible: unlocked, and no category or rule sheet open.
    var canCategorize: Bool { !lock.isLocked && categorization != nil && categoryPicker == nil && ruleDraft == nil && categorySetup == nil }

    /// ⌘K for the selection, or for `ids` (context menu).
    // MARK: Setup banner and likely categories

    /// Share of transactions (not cancelled) with a category the user can rely on: manual, or a
    /// machine/rule category at or above the review threshold.
    var categorizationCoverage: Double { index.coverage }

    /// The footer hint: below 80 % categorized and at least 20 transactions.
    var showsSetupHint: Bool {
        canShowCategorySetup && snapshot.transactions.count >= 20 && categorizationCoverage < 0.8
    }

    /// Categories the user most often chose for transactions in the same direction (manual and
    /// rule), then typical ones: the quick choices of the suggestion menu.
    /// Precomputed per snapshot (`SnapshotIndex`), one table per direction.
    func likelyCategories(for transaction: MFNCore.Transaction, limit: Int = 6) -> [CategoryID] {
        Array((transaction.amountCents > 0 ? index.likelyInflow : index.likelyOutflow).prefix(limit))
    }

    /// Ranked choices for one direction: the user's manual and rule categories by frequency, then
    /// typical ones; income categories only for inflows.
    fileprivate static func likelyCategories(counts: [CategoryID: Int], inflow: Bool) -> [CategoryID] {
        var result = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map(\.key)
        let typical: [CategoryID] = inflow
            ? ["gehalt", "erstattung", "umbuchung", "einnahmen_sonstige"]
            : ["lebensmittel", "restaurant", "online_shopping", "drogerie", "tanken", "haushalt", "freizeit", "abos"]
        for category in typical where !result.contains(category) { result.append(category) }
        return result.filter { CategoryCatalog.info($0).map { !$0.isIncome || inflow } ?? false }
    }

    func showCategoryPicker(for ids: Set<TransactionID>? = nil) {
        let targets = transactions(ids ?? selectedTransactionIDs).filter { $0.status != .cancelled }
        guard canCategorize, !targets.isEmpty else { return }
        let categories = Set(targets.map(\.categoryID))
        categoryPicker = CategoryPickerRequest(
            transactionIDs: targets.map(\.id),
            title: targets.count == 1 ? targets[0].counterpartName : "\(targets.count) Umsätze",
            current: categories.count == 1 ? categories.first ?? nil : nil
        )
    }

    /// Settings → Kategorien switched the model on or off. On: load it now (it was not
    /// prewarmed). A running run sees the switch at its next batch either way.
    func categoryModelSwitched(on: Bool) {
        guard on else { return }
        for case let stage as LLMStage in machineStages { stage.prewarm() }
        categorizeInBackground()
    }

    /// Whether this ledger uses the language model at all (live, not the demo's mock stage).
    var hasCategoryModel: Bool { machineStages.contains { $0 is LLMStage } }

    /// Quiet status of the background run ("412 von 1.500 Umsätzen eingeordnet").
    var categorizationStatus: String? {
        guard isCategorizing, let progress = categorizationProgress, progress.total > 0 else { return nil }
        return "\(progress.done.formatted()) von \(progress.total.formatted()) Umsätzen eingeordnet"
    }

    /// The user's category (`nil` = none) for `ids`; source becomes `manual`, so they leave "Zu prüfen".
    func setCategory(_ category: CategoryID?, for ids: [TransactionID]) {
        guard let service = categorization, !ids.isEmpty else { return }
        if Set(ids) == selectedTransactionIDs { selectNextReview(after: ids) }
        Task {
            do {
                try await service.setManual(category, for: ids)
            } catch {
                Log.logger("categorize").error("Kategorie nicht gespeichert: \(String(describing: type(of: error)), privacy: .public)")
                if !lock.isLocked { categoryFailure = "Die Kategorie konnte nicht gespeichert werden. Bitte versuche es noch einmal." }
            }
        }
    }

    /// Selected (or `ids`) transactions with a suggestion waiting for review.
    func reviewable(_ ids: Set<TransactionID>? = nil) -> [MFNCore.Transaction] {
        let ids = ids ?? selectedTransactionIDs
        return transactions(ids).filter(needsReview)
    }

    /// Visible transactions with these IDs, in snapshot order (newest first).
    func transactions(_ ids: Set<TransactionID>) -> [MFNCore.Transaction] {
        ids.compactMap { index.transactionsByID[$0] }.sorted { (index.position[$0.id] ?? .max) < (index.position[$1.id] ?? .max) }
    }

    var canAcceptSuggestion: Bool { canCategorize && !reviewable().isEmpty }

    /// ⌘⏎: takes over the suggested categories; the selection moves on to the next suggestion.
    func acceptSuggestions(for ids: Set<TransactionID>? = nil) {
        guard let service = categorization else { return }
        let targets = reviewable(ids)
        guard !targets.isEmpty else { return }
        if ids == nil || ids == selectedTransactionIDs { selectNextReview(after: targets.map(\.id)) }
        let byCategory = Dictionary(grouping: targets.compactMap { t in t.categoryID.map { ($0, t.id) } }, by: \.0)
        Task {
            do {
                for (category, pairs) in byCategory {
                    try await service.setManual(category, for: pairs.map(\.1))
                }
            } catch {
                Log.logger("categorize").error("Vorschlag nicht übernommen: \(String(describing: type(of: error)), privacy: .public)")
                if !lock.isLocked { categoryFailure = "Der Vorschlag konnte nicht übernommen werden. Bitte versuche es noch einmal." }
            }
        }
    }

    func acceptSuggestion(for transaction: MFNCore.Transaction) {
        acceptSuggestions(for: [transaction.id])
    }

    /// After deciding on `done`: the next transaction of the current list that waits for review
    /// (below, else above). None left: in "Zu prüfen" the selection empties, elsewhere it stays.
    private func selectNextReview(after done: [TransactionID]) {
        guard let item = selection else { return }
        let done = Set(done)
        let content = ledgerContent(for: item)
        let order = content.ordered
        let positions = done.compactMap { content.position(of: $0) }
        guard let last = positions.max(), let first = positions.min() else { return }
        let candidate: (MFNCore.Transaction) -> Bool = { !done.contains($0.id) && self.needsReview($0) }
        if let next = order[(last + 1)...].first(where: candidate) ?? order[..<first].last(where: candidate) {
            // The user did not pick this row: it stays unread.
            selectsWithoutReading = true
            defer { selectsWithoutReading = false }
            selectedTransactionIDs = [next.id]
        } else if case .review = item {
            selectedTransactionIDs = []
        }
    }

    var canCreateRule: Bool { canCategorize && selectedTransaction != nil }

    /// ⇧⌘K: rule sheet filled from the selected transaction (or `id`, context menu).
    func showRuleEditor(for id: TransactionID? = nil) {
        guard canCategorize else { return }
        let transaction = id.flatMap { index.transactionsByID[$0] } ?? selectedTransaction
        guard let transaction else { return }
        ruleDraft = RuleDraft(transaction: transaction)
    }

    var categoryRules: [CategoryRule] { ledger.categoryRules }

    /// Stores the rule, applies it and categorizes what is still open. Returns an error text.
    func saveRule(_ rule: CategoryRule) async -> String? {
        guard let service = categorization else { return "MFN ist gesperrt." }
        do {
            try await service.apply(rule: rule)
        } catch {
            return "Die Regel konnte nicht gespeichert werden: \(error)"
        }
        categorizeInBackground()
        return nil
    }

    func removeRule(_ id: UUID) async -> String? {
        guard let service = categorization else { return "MFN ist gesperrt." }
        do {
            try await service.removeRule(id)
        } catch {
            return "Die Regel konnte nicht gelöscht werden: \(error)"
        }
        return nil
    }

    /// Transactions (hidden accounts included) the rule would categorize, and of those the manual ones it leaves alone.
    func ruleMatches(_ rule: CategoryRule) -> (all: [MFNCore.Transaction], manual: Int) {
        let all = ledger.transactions.filter { $0.status != .cancelled && rule.matches($0) }
        return (all, all.count(where: { $0.categorySource == .manual }))
    }

    var uncategorizedCount: Int { index.uncategorizedCount }

    // MARK: - Collapsed banks

    static var collapsedBanksKey: String { LaunchProfile.launched.scoped("collapsedBanks") }

    /// Banks collapsed in the sidebar (click on the bank header). UI preference in `UserDefaults`.
    var collapsedConnections: Set<ConnectionID> = Set((UserDefaults.standard.stringArray(forKey: AppModel.collapsedBanksKey) ?? []).map(ConnectionID.init(rawValue:))) {
        didSet {
            guard collapsedConnections != oldValue else { return }
            UserDefaults.standard.set(collapsedConnections.map(\.rawValue).sorted(), forKey: Self.collapsedBanksKey)
        }
    }

    func isCollapsed(_ connection: ConnectionID) -> Bool {
        collapsedConnections.contains(connection)
    }

    /// Collapse state of the selected account's bank, `nil` without a selected account.
    var selectedBankCollapsed: Bool? {
        selectedAccount.map { isCollapsed($0.connectionID) }
    }

    func setSelectedBankCollapsed(_ collapsed: Bool) {
        guard let bank = selectedAccount?.connectionID, isCollapsed(bank) != collapsed else { return }
        toggleCollapsed(bank)
    }

    func toggleCollapsed(_ connection: ConnectionID) {
        if collapsedConnections.contains(connection) { collapsedConnections.remove(connection) } else { collapsedConnections.insert(connection) }
    }

    /// Sum of a bank's visible EUR balances (other currencies are left out, not converted).
    func totalBalanceCents(of connection: ConnectionID) -> Int {
        snapshot.accounts(of: connection).filter { !excludedFromTotals.contains($0.id) }.compactMap { snapshot.balances[$0.id] }
            .filter { $0.currency == "EUR" }
            .reduce(0) { $0 + $1.bookedCents }
    }

    // MARK: - Budgets

    /// Account whose budget sheet is open.
    var budgetEditor: Account?

    func budget(for account: AccountID) -> AccountBudget? {
        ledger.budgets[account]
    }

    /// Current state and forecast; `nil` without a budget.
    /// The forecast starts at the account's last successful sync (what the bank reported).
    func budgetStatus(for account: AccountID, today: BankDay = .today) -> BudgetStatus? {
        // Every ledger change rebuilds the snapshot, so its revision covers budgets and transactions.
        let revision = snapshotRevision
        if budgetCache.revision != revision || budgetCache.day != today { budgetCache = (revision, today, [:]) }
        if let cached = budgetCache.statuses[account] { return cached }
        let status = computeBudgetStatus(for: account, today: today)
        budgetCache.statuses[account] = .some(status)
        return status
    }

    /// The list content for a sidebar item, rebuilt only when its inputs change. Its
    /// query-independent part is cached apart, so a new search or filter only refilters.
    func ledgerContent(for item: SidebarItem) -> LedgerContent {
        let today = BankDay.today
        // Only a query that reads the new rows depends on them (reading one changes the set).
        let key = LedgerCacheKey(item: item, query: ledgerQuery, showCancelled: showCancelled, revision: snapshotRevision, today: today,
                                 newRevision: ledgerQuery.dependsOnNew ? newRevision : 0)
        if let cache = ledgerCache, cache.key == key { return cache.content }
        let new = ledgerQuery.dependsOnNew ? newForQuery : []
        let baseKey = LedgerBaseKey(item: item, revision: snapshotRevision, today: today)
        let base: LedgerBase
        if let cache = ledgerBaseCache, cache.key == baseKey {
            base = cache.base
        } else {
            base = LedgerBase(item: item, model: self, today: today)
            ledgerBaseCache = (baseKey, base)
        }
        let content = LedgerContent(base: base, query: ledgerQuery, showCancelled: showCancelled, today: today, new: new)
        ledgerCache = (key, content)
        return content
    }

    /// Other booked transactions with this counterpart (lowercased name), newest first.
    func bookedHistory(counterpart name: String) -> [MFNCore.Transaction] {
        let revision = snapshotRevision
        if let cache = historyCache, cache.revision == revision { return cache.byName[name] ?? [] }
        var byName: [String: [MFNCore.Transaction]] = [:]
        for transaction in snapshot.transactions where transaction.status == .booked {
            byName[transaction.counterpartName.lowercased(), default: []].append(transaction)
        }
        historyCache = (revision, byName)
        return byName[name] ?? []
    }

    private func computeBudgetStatus(for account: AccountID, today: BankDay) -> BudgetStatus? {
        guard let budget = ledger.budgets[account] else { return nil }
        let connection = ledger.accounts.first { $0.id == account }?.connectionID
        let lastSync = connection.flatMap { ledger.syncStates[$0]?.lastSuccess }.map(BankDay.init)
        // Only this account's rows count (spending, anchor deposits): not a pass over the whole ledger.
        return BudgetForecast.status(for: budget, transactions: ledger.transactions(of: account), today: today, dataAsOf: lastSync)
    }

    func showBudgetEditor(for account: Account) {
        guard !lock.isLocked, store != nil else { return }
        budgetEditor = account
    }

    /// Returns an error text for the sheet, `nil` on success.
    func saveBudget(_ budget: AccountBudget) async -> String? {
        guard let store else { return "MFN ist gesperrt." }
        do {
            try await store.setBudget(budget)
            return nil
        } catch {
            return "Budget konnte nicht gespeichert werden: \(error)"
        }
    }

    func removeBudget(for account: AccountID) async -> String? {
        guard let store else { return "MFN ist gesperrt." }
        do {
            try await store.removeBudget(for: account)
            return nil
        } catch {
            return "Budget konnte nicht entfernt werden: \(error)"
        }
    }

    // MARK: - CSV import

    /// The open import preview (`CSVImportSession`, sheet over the main window).
    var csvImport: CSVImportSession?
    /// Why a chosen file could not be opened (alert); `nil` when there is nothing to say.
    var csvImportFailure: String?
    /// The file is being read and split before the preview opens (`beginCSVImport`).
    var isOpeningCSV = false
    /// The open "Umsätze als CSV exportieren" panel; cancelled when locking.
    @ObservationIgnored var csvExportPanel: NSSavePanel?
    /// Open save or open panel of the backup commands; cancelled when locking.
    @ObservationIgnored var backupPanel: NSSavePanel?
    /// A backup file the user picked to restore from (sheet over the main window).
    var restoreRequest: RestoreRequest?
    /// Result of a backup or restore, shown as an alert (also over the lock screen).
    var backupNotice: BackupNotice?
    /// A backup is being written or restored.
    var isBackingUp = false
    /// "Importierte Umsätze entfernen" waiting for confirmation (alert with the count).
    var importRemoval: ImportRemovalRequest?
    /// Why a removal failed (alert); `nil` when there is nothing to say.
    var importRemovalFailure: String?
    /// Imported rows per account and batch (`ImportIndex`), rebuilt per snapshot revision.
    @ObservationIgnored var importIndexCache: (revision: Int, index: ImportIndex)?

    var canImportCSV: Bool { !lock.isLocked && store != nil && csvImport == nil && !isOpeningCSV && !csvImportAccounts.isEmpty }

    enum CSVImportOutcome {
        case success(count: Int, account: AccountID)
        case failure(String)
    }

    /// Imports the session's rows through the shared merge path (`CSVImportPlan.merge` →
    /// `LedgerStore.apply`), planned again against what is stored now (a sync may have run since
    /// the preview), then categorizes them like synced transactions.
    func importCSV(_ session: CSVImportSession) async -> CSVImportOutcome {
        guard let store, !lock.isLocked, let account = session.account else { return .failure("MFN ist gesperrt.") }
        let lockSession = self.lockSession
        // Every row of this import carries the batch's ID (v10): marked, filterable, removable.
        let batchID = ImportBatchID.make()
        let document = session.document
        let stored = await store.storedTransactions(of: account.id)
        guard !isStale(lockSession) else { return .failure("MFN ist gesperrt.") }
        // Parse and plan off the main actor, like the preview.
        let (incoming, plan) = await Task.detached(priority: .userInitiated) {
            let incoming = document.transactions(for: account, importID: batchID).transactions
            return (incoming, CSVImportPlan.make(incoming: incoming, stored: stored))
        }.value
        guard !isStale(lockSession) else { return .failure("MFN ist gesperrt.") }
        let rows = plan.transactionsToImport(includingLikelyDuplicates: session.includeLikelyDuplicates)
        guard !rows.isEmpty else { return .success(count: 0, account: account.id) }
        let batch = ImportBatch(
            id: batchID, accountID: account.id, format: session.document.preset?.id, fileName: session.fileName,
            encoding: session.document.table.encoding.rawValue, rowCount: rows.count
        )
        do {
            try await store.recordImport(batch, merge: CSVImportPlan.merge(rows, into: stored))
        } catch {
            Log.logger("import").error("CSV-Import nicht gespeichert: \(String(describing: type(of: error)), privacy: .public)")
            return .failure(isStale(lockSession) ? "MFN ist gesperrt." : "Die Umsätze konnten nicht gespeichert werden.")
        }
        // Locked while writing: the store is closed; no balance, no categorization, no selection.
        guard !isStale(lockSession) else { return .failure("MFN ist gesperrt.") }
        // Counts only, never contents.
        Log.logger("import").info("CSV importiert: \(rows.count, privacy: .public) Umsätze, \(plan.duplicates.count, privacy: .public) vorhanden")
        // Without a bank there is no reported balance: opening balance + booked transactions.
        do {
            try await recomputeManualBalance(of: account.id, in: store)
        } catch {
            Log.logger("import").error("Kontostand nicht gespeichert: \(String(describing: type(of: error)), privacy: .public)")
        }
        guard !isStale(lockSession) else { return .failure("MFN ist gesperrt.") }
        categorizeInBackground()
        return .success(count: rows.count, account: account.id)
    }

    /// Store side of "Importierte Umsätze entfernen" (`ImportedTransactions.swift`): one write;
    /// the store refuses bank rows.
    var canWriteStore: Bool { store != nil }

    func removeImportedTransactions(_ ids: Set<TransactionID>) async throws -> LedgerSnapshot.ImportRemoval {
        guard let store else { throw StoreUnavailable() }
        return try await store.removeImportedTransactions(ids)
    }

    struct StoreUnavailable: Error {}

    // MARK: - Forecast and planned items

    /// The open forecast panel.
    var forecastPanel: ForecastRequest?

    func forecastBasis(of account: AccountID) -> SnapshotIndex.ForecastBasis? {
        index.forecasts[account]
    }

    /// The user's planned items of an account, by day.
    func plannedItems(for account: AccountID) -> [PlannedItem] {
        index.ownItemsByAccount[account] ?? []
    }

    /// Sum of the self-planned payments still counted on an account (not the ones a booking
    /// probably fulfilled), for "Verfügbar" in the header.
    func ownPlannedCents(for account: AccountID) -> Int {
        index.forecasts[account]?.ownPlannedCents ?? 0
    }

    /// Account the forecast command works on: the selected one, if it has a forecast.
    var forecastAccount: Account? {
        guard !lock.isLocked, case let .account(id)? = selection, index.forecasts[id] != nil else { return nil }
        return account(id)
    }

    /// Opens the forecast panel; `editing` loads that planned item into its form.
    func showForecast(for account: Account, editing: UUID? = nil) {
        guard !lock.isLocked, store != nil, index.forecasts[account.id] != nil else { return }
        forecastPanel = ForecastRequest(account: account, editing: editing)
    }

    /// Returns an error text for the panel, `nil` on success.
    func savePlannedItem(_ item: PlannedItem) async -> String? {
        guard let store else { return "MFN ist gesperrt." }
        do {
            try await store.upsertPlannedItem(item)
            return nil
        } catch {
            return "Die geplante Buchung konnte nicht gespeichert werden: \(error)"
        }
    }

    func removePlannedItem(_ id: UUID) async -> String? {
        guard let store else { return "MFN ist gesperrt." }
        do {
            try await store.removePlannedItem(id)
            return nil
        } catch {
            return "Die geplante Buchung konnte nicht entfernt werden: \(error)"
        }
    }

    /// "Nein, kommt noch": the booking is something else, the item counts again.
    func ignoreMatch(_ transaction: TransactionID, for item: PlannedItem) async -> String? {
        var changed = item
        changed.ignoredMatches.insert(transaction)
        return await savePlannedItem(changed)
    }

    struct PlannedOverview {
        var count = 0
        var cents = 0
        var next: PlannedItem?
    }

    /// Overview: self-planned payments still to come on accounts that count in totals. Cached per
    /// snapshot (the overview reads it several times per redraw).
    var plannedOverview: PlannedOverview {
        if let cache = plannedOverviewCache, cache.revision == snapshotRevision, cache.excluded == excludedFromTotals { return cache.value }
        var value = PlannedOverview()
        var nextDay: BankDay?
        for (account, basis) in index.forecasts where !excludedFromTotals.contains(account) {
            for event in basis.forecast.events {
                guard case let .manual(id) = event.source else { continue }
                value.count += 1
                value.cents += event.cents
                if nextDay.map({ event.day < $0 }) ?? true {
                    nextDay = event.day
                    value.next = index.ownItemsByAccount[account]?.first { $0.id == id }
                }
            }
        }
        plannedOverviewCache = (snapshotRevision, excludedFromTotals, value)
        return value
    }

    // MARK: - Hidden accounts

    // Per profile (`LaunchProfile.scoped`): the test profile may hold the same real accounts
    // (same IDs) as the live ledger, and its settings must not change the live ones.
    static var hiddenAccountsKey: String { LaunchProfile.launched.scoped("hiddenAccounts") }
    static var hiddenRecurringKey: String { LaunchProfile.launched.scoped("hiddenRecurring") }

    private static func loadHiddenRecurring() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenRecurringKey) ?? [])
    }
    static var excludedFromTotalsKey: String { LaunchProfile.launched.scoped("excludedFromTotals") }
    /// Base names of all per-profile UI settings (removed when the test profile is emptied).
    nonisolated static let profileScopedKeys = ["hiddenAccounts", "excludedFromTotals", "sidebarOrder", "collapsedBanks", "hiddenRecurring", "categorySetupOffered", "pendingSecretCleanup"]

    private static func loadExcludedFromTotals() -> Set<AccountID> {
        Set((UserDefaults.standard.stringArray(forKey: excludedFromTotalsKey) ?? []).map(AccountID.init(rawValue:)))
    }

    func isCountedInTotals(_ account: AccountID) -> Bool {
        !excludedFromTotals.contains(account)
    }

    func setCountedInTotals(_ counted: Bool, account: AccountID) {
        if counted { excludedFromTotals.remove(account) } else { excludedFromTotals.insert(account) }
    }

    private static func loadHiddenAccounts() -> Set<AccountID> {
        Set((UserDefaults.standard.stringArray(forKey: hiddenAccountsKey) ?? []).map(AccountID.init(rawValue:)))
    }

    /// Who made each transaction, where the raw data says so (shared accounts, e.g. C24).
    private(set) var initiators: [TransactionID: TransactionInitiator] = [:]
    /// `ledgerRevision` the initiators were read for (a pending → booked swap keeps the count).
    @ObservationIgnored private var initiatorBasis = -1
    /// Accounts with transactions by at least two different people: only there the list names them.
    private(set) var sharedAccounts: Set<AccountID> = []

    /// The person behind a transaction in lists: only on shared accounts (elsewhere it is noise).
    func listedInitiator(of transaction: MFNCore.Transaction) -> TransactionInitiator? {
        sharedAccounts.contains(transaction.accountID) ? initiators[transaction.id] : nil
    }

    /// Extraction result per transaction, with the size of the raw data it was read from: a
    /// publish only reads rows that are new or whose raw data changed, not every blob again.
    /// (Same size, other content: the person behind a transaction does not change.)
    @ObservationIgnored private var initiatorCache: [TransactionID: (size: Int, initiator: TransactionInitiator?)] = [:]

    private func refreshInitiators() {
        // Most publishes change no raw data (a category, a balance, a read mark): nothing to
        // extract and nothing to rebuild then.
        if initiatorCache.count == ledger.transactions.count,
           ledger.transactions.allSatisfy({ initiatorCache[$0.id]?.size == $0.rawJSON.count }) { return }
        var found: [TransactionID: TransactionInitiator] = [:]
        var people: [AccountID: Set<String>] = [:]
        var cache: [TransactionID: (size: Int, initiator: TransactionInitiator?)] = [:]
        cache.reserveCapacity(ledger.transactions.count)
        for transaction in ledger.transactions {
            let size = transaction.rawJSON.count
            let initiator: TransactionInitiator?
            if let known = initiatorCache[transaction.id], known.size == size {
                initiator = known.initiator
            } else {
                initiator = TransactionInitiator.extract(from: transaction.rawJSON)
            }
            cache[transaction.id] = (size, initiator)
            guard let initiator else { continue }
            found[transaction.id] = initiator
            people[transaction.accountID, default: []].insert(initiator.key)
        }
        initiatorCache = cache
        if initiators != found { initiators = found }
        let shared = Set(people.filter { $0.value.count > 1 }.keys)
        if sharedAccounts != shared { sharedAccounts = shared }
    }

    /// The UI's view: hidden accounts out, the user's account names in place of the bank's.
    /// A new day without a new snapshot: day-based figures would be one day off otherwise.
    private func dayChanged() {
        guard !lock.isLocked, index.day != .today else { return }
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        if ledgerRevision != initiatorBasis {
            initiatorBasis = ledgerRevision
            refreshInitiators()
        }
        var visible = ledger.hiding(hiddenAccountIDs)
        if !visible.customAccountNames.isEmpty {
            for index in visible.accounts.indices {
                visible.accounts[index].name = visible.displayName(of: visible.accounts[index])
            }
        }
        snapshot = visible
        index = SnapshotIndex(snapshot: visible, forecastCache: forecastCache, needsReview: needsReview)
        snapshotRevision &+= 1
    }

    // MARK: - New since the last sync

    /// Rows read since this list was opened. "Nur neue" and "Neue zuerst" still treat them as
    /// new, so a row does not vanish or jump the moment it is selected (like Mail).
    private(set) var readInThisList: Set<TransactionID> = [] {
        didSet { newRevision &+= 1 }
    }
    /// Bumped when `newForQuery` changes without a new `snapshotRevision` (keys `ledgerContent`).
    @ObservationIgnored private var newRevision = 0
    /// Set while the app itself moves the selection (`selectNextReview`): that does not read.
    @ObservationIgnored private var selectsWithoutReading = false

    enum LightChange: Equatable {
        /// Only the read marks differ, or nothing at all (e.g. the store confirming an optimistic
        /// `markRead`).
        case newOnly
        /// Only the sync states differ (and the read marks, if `alsoNew`).
        case syncStates(alsoNew: Bool)
    }

    /// A change that needs no new index and no new lists; `nil` for everything else.
    /// Unchanged arrays compare by storage first: cheap.
    ///
    /// Sync states only count as light while every connection's last successful sync stays on
    /// the same day: budgets forecast from that day (`computeBudgetStatus`), so a new day goes
    /// the full way.
    static func lightChange(from old: LedgerSnapshot, to new: LedgerSnapshot) -> LightChange? {
        var probe = old
        probe.newTransactionIDs = new.newTransactionIDs
        probe.syncStates = new.syncStates
        guard probe == new else { return nil }
        guard old.syncStates != new.syncStates else { return .newOnly }
        let connections = Set(old.syncStates.keys).union(new.syncStates.keys)
        for id in connections {
            let before = old.syncStates[id]?.lastSuccess.map { BankDay($0) }
            let after = new.syncStates[id]?.lastSuccess.map { BankDay($0) }
            guard before == after else { return nil }
        }
        return .syncStates(alsoNew: old.newTransactionIDs != new.newTransactionIDs)
    }

    /// Read marks into `snapshot` and the counts, without rebuilding anything else.
    private func refreshNewState() {
        let visible = ledger.newTransactionIDs.filter { index.transactionsByID[$0] != nil }
        var counts: [AccountID: Int] = [:]
        for id in visible {
            if let account = index.transactionsByID[id]?.accountID { counts[account, default: 0] += 1 }
        }
        snapshot.newTransactionIDs = visible
        index.newCounts = counts
        newRevision &+= 1
    }

    /// New transactions of an account ("Neu"), for the sidebar, the overview and the header.
    func newCount(of account: AccountID) -> Int {
        index.newCounts[account] ?? 0
    }

    /// New transactions in all visible accounts.
    var totalNewCount: Int { index.newCounts.values.reduce(0, +) }

    /// Not read yet: marked "Neu" in lists.
    func isNew(_ id: TransactionID) -> Bool {
        snapshot.newTransactionIDs.contains(id)
    }

    /// What "Nur neue" and "Neue zuerst" go by: unread plus read in this list.
    var newForQuery: Set<TransactionID> {
        readInThisList.isEmpty ? snapshot.newTransactionIDs : snapshot.newTransactionIDs.union(readInThisList)
    }

    /// Marks rows read (selecting one row, "Alle als gelesen markieren"). The marks go at once;
    /// if the store cannot save it, they come back.
    func markRead(_ ids: Set<TransactionID>) {
        guard !lock.isLocked, let store else { return }
        let read = snapshot.newTransactionIDs.intersection(ids)
        guard !read.isEmpty else { return }
        readInThisList.formUnion(read)
        ledger.newTransactionIDs.subtract(read)
        Task {
            do {
                try await store.markSeen(read)
            } catch {
                // Locked meanwhile: the database is closed and the marks stay on disk.
                guard self.store === store else {
                    Log.store.notice("Gelesen-Markierung nicht gespeichert, Datenbank gesperrt")
                    return
                }
                Log.store.error("Neue Umsätze nicht als gelesen gespeichert: \(String(describing: error), privacy: .private)")
                ledger.newTransactionIDs.formUnion(read.filter { ledger.transaction($0) != nil })
                readInThisList.subtract(read)
            }
        }
    }

    /// The new rows "Alle als gelesen markieren" (⇧⌘U) applies to: the selected account's, or
    /// all of them.
    private var newInScope: Set<TransactionID> {
        guard let account = selectedAccountID else { return snapshot.newTransactionIDs }
        return snapshot.newTransactionIDs.filter { index.transactionsByID[$0]?.accountID == account }
    }

    var canMarkAllRead: Bool {
        !lock.isLocked && (selectedAccountID.map { newCount(of: $0) > 0 } ?? (totalNewCount > 0))
    }

    func markAllRead() {
        guard !lock.isLocked else { return }
        markRead(newInScope)
    }

    /// Sidebar context menu of an account.
    func markAllRead(of account: AccountID) {
        guard !lock.isLocked else { return }
        markRead(snapshot.newTransactionIDs.filter { index.transactionsByID[$0]?.accountID == account })
    }

    /// "Nur neue Umsätze" (⌃⌘N). The overview and depots have no list: switches to "Alle Konten"
    /// first, like ⌃⌘I.
    func toggleNewFilter() {
        guard !lock.isLocked else { return }
        let isDepot = if case let .account(id)? = selection { account(id)?.type == .depot } else { false }
        if !ledgerQuery.onlyNew, selection == .overview || selection == .subscriptions || selection == nil || isDepot {
            selection = .allAccounts
            AccessibilityNotification.Announcement("Alle Konten, nur neue Umsätze").post()
        }
        ledgerQuery.onlyNew.toggle()
    }

    // MARK: - Renaming

    /// The name the bank gives the account (what "Originalnamen verwenden" restores).
    func bankName(of account: AccountID) -> String? {
        ledger.accounts.first { $0.id == account }?.name
    }

    /// Display name of any account, hidden ones included.
    func displayName(of account: Account) -> String {
        ledger.displayName(of: account)
    }

    /// `nil` or blank restores the bank's name. Returns an error message for the UI.
    func renameAccount(_ account: AccountID, to name: String?) async -> String? {
        guard let store else { return "Die Datenbank ist nicht geöffnet." }
        do {
            try await store.setCustomName(name, for: account)
            return nil
        } catch {
            return "Name konnte nicht gespeichert werden: \(error)"
        }
    }

    func renameConnection(_ id: ConnectionID, to name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Der Name darf nicht leer sein." }
        guard let store, var connection = ledger.connections.first(where: { $0.id == id }) else { return "Die Datenbank ist nicht geöffnet." }
        connection.displayName = trimmed
        do {
            try await store.upsert(connection: connection)
            return nil
        } catch {
            return "Name konnte nicht gespeichert werden: \(error)"
        }
    }

    func isHidden(_ account: AccountID) -> Bool {
        hiddenAccountIDs.contains(account)
    }

    func setHidden(_ hidden: Bool, account: AccountID) {
        if hidden { hiddenAccountIDs.insert(account) } else { hiddenAccountIDs.remove(account) }
    }

    /// All accounts of a bank, hidden ones included, in the user's order.
    func allAccounts(of connection: ConnectionID) -> [Account] {
        DisplayOrder.ordered(ledger.accounts(of: connection), by: displayOrder.accounts[connection.rawValue] ?? []) { $0.id.rawValue }
    }

    // MARK: - Sidebar order

    static var displayOrderKey: String { LaunchProfile.launched.scoped("sidebarOrder") }

    private static func loadDisplayOrder() -> DisplayOrder {
        UserDefaults.standard.data(forKey: displayOrderKey).flatMap { try? JSONDecoder().decode(DisplayOrder.self, from: $0) } ?? DisplayOrder()
    }

    /// Banks in the user's order; new banks after the ordered ones.
    var orderedConnections: [Connection] {
        DisplayOrder.ordered(snapshot.connections, by: displayOrder.connections) { $0.id.rawValue }
    }

    /// Accounts of a bank in the user's order; new accounts after the ordered ones.
    func orderedAccounts(of connection: ConnectionID) -> [Account] {
        DisplayOrder.ordered(snapshot.accounts(of: connection), by: displayOrder.accounts[connection.rawValue] ?? []) { $0.id.rawValue }
    }

    /// Drag and drop of a bank onto another bank's header.
    func moveConnection(_ dragged: String, onto target: ConnectionID) {
        displayOrder.connections = DisplayOrder.move(dragged, onto: target.rawValue, in: orderedConnections.map(\.id.rawValue))
    }

    /// Context menu "Nach oben/unten" for a bank.
    func moveConnection(_ id: ConnectionID, by offset: Int) {
        displayOrder.connections = DisplayOrder.move(id.rawValue, by: offset, in: orderedConnections.map(\.id.rawValue))
    }

    /// `List.onMove` inside one bank.
    func moveAccounts(of connection: ConnectionID, fromOffsets source: IndexSet, toOffset destination: Int) {
        let ids = orderedAccounts(of: connection).map(\.id.rawValue)
        displayOrder.accounts[connection.rawValue] = DisplayOrder.move(fromOffsets: source, toOffset: destination, in: ids)
    }

    /// Context menu "Nach oben/unten" for an account (within its bank).
    func moveAccount(_ account: Account, by offset: Int) {
        let ids = orderedAccounts(of: account.connectionID).map(\.id.rawValue)
        displayOrder.accounts[account.connectionID.rawValue] = DisplayOrder.move(account.id.rawValue, by: offset, in: ids)
    }

    // MARK: - Derived

    var selectedAccountID: AccountID? {
        if case let .account(id) = selection { id } else { nil }
    }

    var selectedAccount: Account? {
        guard let id = selectedAccountID else { return nil }
        return index.accountsByID[id]
    }

    func needsReview(_ transaction: MFNCore.Transaction) -> Bool {
        guard transaction.status != .cancelled, transaction.categoryID != nil, transaction.categorySource != .manual,
              let confidence = transaction.confidence else { return false }
        return confidence < Categorizer.reviewThreshold
    }

    var reviewCount: Int { index.reviewCount }

    var pendingTotalCents: Int { index.pendingTotalCents }

    var pendingCount: Int { index.pendingCount }

    /// Overview: monthly flows of an account (see `SnapshotIndex.MonthFlow`).
    func overviewMonths(of account: AccountID) -> [SnapshotIndex.MonthFlow] {
        index.monthsByAccount[account] ?? []
    }

    /// Account header: balance of the last 31 days plus forecast, built once per snapshot.
    func balanceCurve(of account: AccountID) -> SnapshotIndex.BalanceCurve? {
        index.balanceCurves[account]
    }

    /// Overview: this month's spending of an account per category group.
    func overviewSpending(of account: AccountID) -> [CategoryInfo.Group?: Int] {
        index.spendingByAccount[account] ?? [:]
    }

    /// Balance does not cover the planned payments of this account (giro and Tagesgeld only).
    /// `nil` while amounts are hidden (⇧⌘H): the warning alone would tell that money is short.
    func shortfall(for account: AccountID) -> SnapshotIndex.Shortfall? {
        hideAmounts ? nil : index.shortfalls[account]
    }

    /// "ursprünglich"-style original amount of a foreign-currency booking; `nil` without one and
    /// while amounts are hidden (⇧⌘H).
    func foreignAmountText(of transaction: MFNCore.Transaction) -> String? {
        guard !hideAmounts, let original = transaction.originalAmountCents, let currency = transaction.originalCurrency else { return nil }
        return Money.format(original, currency: currency)
    }

    /// Overview: newest transactions of all visible accounts (the index is built without hidden ones).
    var latestOverall: [MFNCore.Transaction] { index.latestOverall }

    /// Overview → list: opens the account and selects the transaction (the inspector follows).
    func reveal(_ transaction: MFNCore.Transaction) {
        // A kept search or filter could hide the row: start from the unfiltered list.
        ledgerQuery.resetFilters()
        ledgerQuery.text = ""
        // A depot shows its positions, not a list: reveal it in "Alle Konten" instead.
        let isDepot = account(transaction.accountID)?.type == .depot
        // `selection` clears the transaction selection when it changes, so it goes first.
        selection = isDepot ? .allAccounts : .account(transaction.accountID)
        selectedTransactionIDs = [transaction.id]
    }

    /// Sum of all EUR balances (foreign-currency accounts are left out rather than mixed in).
    var totalBalanceCents: Int {
        snapshot.balances.filter { !excludedFromTotals.contains($0.key) }.values
            .filter { $0.currency == "EUR" }.reduce(0) { $0 + $1.bookedCents }
    }

    /// Oldest successful sync across all connections, `nil` until every connection synced once.
    var lastCompleteSync: Date? {
        // Accounts without a bank connection never sync (v10).
        let dates = snapshot.connections.filter(\.connectorID.hasConnector).map { snapshot.syncStates[$0.id]?.lastSuccess }
        guard !dates.isEmpty, !dates.contains(nil) else { return nil }
        return dates.compactMap(\.self).min()
    }

    var selectedTransaction: MFNCore.Transaction? {
        guard selectedTransactionIDs.count == 1, let id = selectedTransactionIDs.first else { return nil }
        return index.transactionsByID[id]
    }

    func syncState(_ id: ConnectionID) -> SyncState {
        snapshot.syncStates[id] ?? SyncState()
    }

    func account(_ id: AccountID) -> Account? {
        index.accountsByID[id]
    }

    /// Whether today's balance walked back through the bookings gives the balance of each day.
    /// Not at PayPal: a payment PayPal collects from the bank account is in the list, the money
    /// coming in for it is not, so the sum of the rows is not what the balance moved by.
    func hasRunningBalance(_ account: Account) -> Bool {
        ledger.connections.first { $0.id == account.connectionID }?.connectorID != .paypal
    }

    func connectionName(_ id: ConnectionID) -> String {
        snapshot.connections.first { $0.id == id }?.displayName ?? id.rawValue
    }
}

extension LedgerSnapshot {
    /// The snapshot without `hidden` accounts and everything that belongs to them.
    func hiding(_ hidden: Set<AccountID>) -> LedgerSnapshot {
        guard !hidden.isEmpty else { return self }
        var result = self
        result.accounts.removeAll { hidden.contains($0.id) }
        result.balances = balances.filter { !hidden.contains($0.key) }
        result.transactions.removeAll { hidden.contains($0.accountID) }
        result.cardStatements.removeAll { hidden.contains($0.accountID) }
        result.securities.removeAll { hidden.contains($0.accountID) }
        result.plannedItems.removeAll { hidden.contains($0.accountID) }
        result.recurringEntries.removeAll { hidden.contains($0.accountID) }
        result.importBatches.removeAll { hidden.contains($0.accountID) }
        // "Neu" counts, ⇧⌘U and the new filter only see visible accounts.
        if !result.newTransactionIDs.isEmpty {
            result.newTransactionIDs = result.newTransactionIDs.filter { result.transaction($0) != nil }
        }
        return result
    }
}

/// Counters and lookups over one snapshot, computed in one pass when it is rebuilt.
struct SnapshotIndex {
    var transactionsByID: [TransactionID: MFNCore.Transaction] = [:]
    /// Position in `snapshot.transactions` (newest first), for ordered lookups.
    var position: [TransactionID: Int] = [:]
    var accountsByID: [AccountID: Account] = [:]
    var reviewCount = 0
    /// Transactions not seen since a sync brought them in, per account (`LedgerSnapshot.newTransactionIDs`).
    var newCounts: [AccountID: Int] = [:]
    /// Pending EUR transactions (other currencies are left out, not converted).
    var pendingTotalCents = 0
    var uncategorizedCount = 0
    /// Share of transactions (not cancelled) with a category the user can rely on.
    var coverage: Double = 1
    var likelyInflow: [CategoryID] = []
    var likelyOutflow: [CategoryID] = []
    /// Pending EUR transactions (counted with `pendingTotalCents`).
    var pendingCount = 0
    /// Overview charts, per account and month (index 0 = `overviewMonths` − 1 months ago,
    /// last = this month), EUR only. The view sums the visible accounts.
    var monthsByAccount: [AccountID: [MonthFlow]] = [:]
    /// Overview: this month's spending per category group (positive cents), EUR, without
    /// transfers; `nil` key = no category yet.
    var spendingByAccount: [AccountID: [CategoryInfo.Group?: Int]] = [:]
    /// The day this index was built for. Day-based figures (curves, shortfalls) refer to it; the
    /// model rebuilds the index when the day changes (`NSCalendarDayChanged`).
    var day = BankDay.today
    /// Account header: balance of the last `overviewDays` days plus the forecast (EUR, not depots).
    var balanceCurves: [AccountID: BalanceCurve] = [:]
    /// What the curves and shortfalls are built from, for the forecast panel (other horizons,
    /// what-if) and the planned items of the list.
    var forecasts: [AccountID: ForecastBasis] = [:]
    /// The user's planned items per account, by day.
    var ownItemsByAccount: [AccountID: [PlannedItem]] = [:]
    /// Giro and Tagesgeld accounts whose balance does not cover their known payments (announced
    /// by the bank or planned by the user; estimated monthly ones do not warn).
    var shortfalls: [AccountID: Shortfall] = [:]
    /// Overview: the newest pending and booked transactions of all accounts, newest first. Planned
    /// (not happened yet) and cancelled ones are left out.
    var latestOverall: [MFNCore.Transaction] = []

    static let latestOverallLimit = 40
    static let overviewMonths = 12
    static let overviewDays = 31

    /// The balance runs out before the known payments (announced by the bank, planned by the user)
    /// are through. Start: booked balance plus pending, without overdraft (Dispo is not known).
    /// Estimated monthly payments never warn: an account topped up as its debits come has the
    /// debits estimated but not the money that covers them, and warned falsely.
    struct Shortfall: Equatable {
        /// First day the balance would be below zero (today if it already is).
        var day: BankDay
        /// Missing at the lowest point (positive cents).
        var missingCents: Int
        /// Planned payments still to come (positive cents).
        var plannedOutCents: Int
        /// Formatted once per build (the sidebar shows it on every redraw).
        var dayText: String
        var missingText: String
    }

    /// Everything the forecast of one account starts from.
    struct ForecastBasis: Equatable {
        /// Booked balance, and booked plus pending (where the forecast starts).
        var bookedCents: Int
        var startCents: Int
        /// Announced, self-planned and estimated monthly payments up to `forecastMonths` ahead.
        var forecast: AccountForecast
        /// Where the header's curve and the shortfall warning end.
        var horizon: BankDay
        /// Sum of the self-planned payments still counted (not the ones a booking probably fulfilled).
        var ownPlannedCents: Int
    }

    /// The panel can look this far ahead.
    static let forecastMonths = 12

    /// Forecasts of the last index build. The index is rebuilt on the main actor for every ledger
    /// change (each sync write, each categorisation batch); most of them leave an account's
    /// payments untouched, and its forecast (recurring series, matching) is then reused.
    @MainActor
    final class ForecastCache {
        /// `key`: hash over everything the forecast reads (see `feed`), the planned items and the
        /// days. Equal hashes are taken as equal inputs (64 bits, seeded per launch).
        var entries: [AccountID: (key: Int, forecast: AccountForecast)] = [:]
    }

    /// The fields of a transaction `BalanceForecast` reads.
    private static func feed(_ hasher: inout Hasher, _ transaction: MFNCore.Transaction) {
        hasher.combine(transaction.id)
        hasher.combine(transaction.amountCents)
        hasher.combine(transaction.status)
        hasher.combine(transaction.valueDate)
        hasher.combine(transaction.bookingDate)
        hasher.combine(transaction.counterpartName)
    }

    /// End-of-day balances of the last `overviewDays` days (booked, walked back from today's
    /// balance) and the forecast from today: pending at once, then the expected payments
    /// (`BalanceForecast`) until the end of the month, at least 14 days, and at least until the
    /// last announced or self-planned payment.
    struct BalanceCurve: Equatable {
        struct Point: Equatable, Identifiable {
            /// Running number: forecast points can share a day (unique ids for `ForEach`).
            let index: Int
            let day: BankDay
            let cents: Int
            let isForecast: Bool
            var id: Int { index }
        }

        var past: [Point]
        var forecast: [Point]
        var todayCents: Int
        var endCents: Int
        var end: BankDay
        /// Lowest forecast point, only when below zero.
        var lowest: Point?
    }

    /// One account's money in one month.
    struct MonthFlow: Equatable {
        /// Income and spending (positive cents), pending and booked, without own transfers and
        /// card settlements (they would count the same money twice).
        var income = 0
        var spending = 0
        /// All booked amounts: walks the balance back month by month.
        var bookedNet = 0
    }

    /// Own transfers and card settlements: money moving between the user's accounts.
    static let transferCategories: Set<CategoryID> = TransferRules.categories

    static func isCardSettlement(_ transaction: MFNCore.Transaction, account: Account?, hasCardAccount: Bool) -> Bool {
        TransferRules.isCardSettlement(transaction, account: account, hasCardAccount: hasCardAccount)
    }

    init() {}

    @MainActor
    init(snapshot: LedgerSnapshot, forecastCache: ForecastCache? = nil, needsReview: (MFNCore.Transaction) -> Bool) {
        transactionsByID.reserveCapacity(snapshot.transactions.count)
        position.reserveCapacity(snapshot.transactions.count)
        var relevant = 0
        var trusted = 0
        var inflowCounts: [CategoryID: Int] = [:]
        var outflowCounts: [CategoryID: Int] = [:]
        var latestAll: [(transaction: MFNCore.Transaction, offset: Int)] = []
        let today = BankDay.today
        let thisMonth = today.year * 12 + today.month
        accountsByID = Dictionary(snapshot.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hasCardAccount = snapshot.accounts.contains { $0.type == .card }
        let emptyMonths = Array(repeating: MonthFlow(), count: Self.overviewMonths)
        day = today
        let emptyDays = Array(repeating: 0, count: Self.overviewDays)
        let firstDay = today.adding(days: -(Self.overviewDays - 1))
        // Day → slot without calendar math per booking.
        let daySlots = Dictionary(uniqueKeysWithValues: (0..<Self.overviewDays).map { (firstDay.adding(days: $0), $0) })
        let historyFrom = today.adding(days: -BalanceForecast.historyDays)
        var dailyBookedNet: [AccountID: [Int]] = [:]
        var plannedByAccount: [AccountID: [MFNCore.Transaction]] = [:]
        var recentByAccount: [AccountID: [MFNCore.Transaction]] = [:]
        var pendingByAccount: [AccountID: Int] = [:]
        var forecastInputs: [AccountID: Hasher] = [:]
        let hasNew = !snapshot.newTransactionIDs.isEmpty
        for (offset, transaction) in snapshot.transactions.enumerated() {
            // A duplicate ID (should not happen) is counted once, not twice.
            guard transactionsByID[transaction.id] == nil else { continue }
            transactionsByID[transaction.id] = transaction
            position[transaction.id] = offset
            if needsReview(transaction) { reviewCount += 1 }
            if hasNew, snapshot.newTransactionIDs.contains(transaction.id) { newCounts[transaction.accountID, default: 0] += 1 }
            if transaction.status == .pending, transaction.currency == "EUR" {
                pendingTotalCents += transaction.amountCents
                pendingCount += 1
                pendingByAccount[transaction.accountID, default: 0] += transaction.amountCents
            }
            if transaction.status == .planned, transaction.currency == "EUR" {
                plannedByAccount[transaction.accountID, default: []].append(transaction)
                Self.feed(&forecastInputs[transaction.accountID, default: Hasher()], transaction)
            }
            // Recent bookings: executed planned payments, monthly counterparts, fulfilled items.
            if transaction.status == .pending || transaction.status == .booked, transaction.currency == "EUR",
               transaction.effectiveDate >= historyFrom {
                recentByAccount[transaction.accountID, default: []].append(transaction)
                Self.feed(&forecastInputs[transaction.accountID, default: Hasher()], transaction)
            }
            if transaction.status == .pending || transaction.status == .booked {
                Self.insertLatest(transaction, offset: offset, into: &latestAll, limit: Self.latestOverallLimit)
                if transaction.currency == "EUR" {
                    let day = transaction.effectiveDate
                    let slot = day.year * 12 + day.month - thisMonth + Self.overviewMonths - 1
                    if (0..<Self.overviewMonths).contains(slot) {
                        // Mutated in place: a copy out and back would copy the array per transaction.
                        let id = transaction.accountID
                        if transaction.status == .booked {
                            monthsByAccount[id, default: emptyMonths][slot].bookedNet += transaction.amountCents
                            if let daySlot = daySlots[day] {
                                dailyBookedNet[id, default: emptyDays][daySlot] += transaction.amountCents
                            }
                        }
                        let isTransfer = (transaction.categoryID.map(Self.transferCategories.contains) ?? false)
                            || Self.isCardSettlement(transaction, account: accountsByID[id], hasCardAccount: hasCardAccount)
                        if !isTransfer {
                            if transaction.amountCents > 0 {
                                monthsByAccount[id, default: emptyMonths][slot].income += transaction.amountCents
                            } else {
                                monthsByAccount[id, default: emptyMonths][slot].spending -= transaction.amountCents
                            }
                            if slot == Self.overviewMonths - 1, transaction.amountCents < 0 {
                                let group = transaction.categoryID.flatMap(CategoryCatalog.info)?.group
                                spendingByAccount[transaction.accountID, default: [:]][group, default: 0] -= transaction.amountCents
                            }
                        }
                    } else if slot >= Self.overviewMonths, transaction.status == .booked {
                        // Value date in a coming month (rare): still part of the balance walk.
                        monthsByAccount[transaction.accountID, default: emptyMonths][Self.overviewMonths - 1].bookedNet += transaction.amountCents
                    }
                }
            }
            if transaction.status != .cancelled {
                relevant += 1
                if transaction.categoryID == nil {
                    uncategorizedCount += 1
                } else if transaction.categorySource == .manual || (transaction.confidence ?? 0) >= Categorizer.reviewThreshold {
                    trusted += 1
                }
            }
            if let category = transaction.categoryID, transaction.categorySource == .manual || transaction.categorySource == .rule {
                if transaction.amountCents > 0 { inflowCounts[category, default: 0] += 1 } else { outflowCounts[category, default: 0] += 1 }
            }
        }
        coverage = relevant == 0 ? 1 : Double(trusted) / Double(relevant)
        likelyInflow = AppModel.likelyCategories(counts: inflowCounts, inflow: true)
        likelyOutflow = AppModel.likelyCategories(counts: outflowCounts, inflow: false)
        latestOverall = latestAll.map(\.transaction)

        // One forecast per account for the shortfall and the curve. The curve shows all of it,
        // the shortfall warning reads the known payments only (`Shortfall`).
        ownItemsByAccount = Dictionary(grouping: snapshot.plannedItems, by: \.accountID)
        let itemsByAccount = ownItemsByAccount
        // First of next month minus one day (adding a month to the 31st would clamp first).
        let next = today.year * 12 + today.month
        let monthEnd = (BankDay(year: next / 12, month: next % 12 + 1, day: 1) ?? today.adding(days: 30)).adding(days: -1)
        let until = today.adding(months: Self.forecastMonths)
        var freshForecasts: [AccountID: (key: Int, forecast: AccountForecast)] = [:]
        defer { forecastCache?.entries = freshForecasts }
        for account in snapshot.accounts where account.type != .depot {
            guard let balance = snapshot.balances[account.id], balance.currency == "EUR" else { continue }
            var inputs = forecastInputs[account.id] ?? Hasher()
            inputs.combine(itemsByAccount[account.id] ?? [])
            inputs.combine(today)
            inputs.combine(until)
            let key = inputs.finalize()
            let forecast: AccountForecast
            if let cached = forecastCache?.entries[account.id], cached.key == key {
                forecast = cached.forecast
            } else {
                forecast = BalanceForecast.forecast(planned: plannedByAccount[account.id] ?? [], actual: recentByAccount[account.id] ?? [],
                                                    items: itemsByAccount[account.id] ?? [], today: today, until: until)
            }
            freshForecasts[account.id] = (key, forecast)
            let start = balance.bookedCents + (pendingByAccount[account.id] ?? 0)
            // Known payments are always inside; estimates only fill the time up to them.
            let lastKnown = forecast.events.last { !$0.isEstimate }?.day ?? today
            let horizon = min(max(monthEnd, today.adding(days: 14), lastKnown), until)
            let ownPlanned = forecast.events.reduce(0) { sum, event in
                if case .manual = event.source { sum + event.cents } else { sum }
            }
            let basis = ForecastBasis(bookedCents: balance.bookedCents, startCents: start, forecast: forecast, horizon: horizon,
                                      ownPlannedCents: ownPlanned)
            forecasts[account.id] = basis
            let path = BalanceForecast.path(start: start, events: forecast.events, today: today, until: horizon)
            if account.type == .giro || account.type == .tagesgeld {
                // Without estimates the curve's path is the known path already.
                let known = forecast.events.contains(where: \.isEstimate) ? Self.knownPath(basis, today: today) : path
                if let shortfall = Self.shortfall(known) { shortfalls[account.id] = shortfall }
            }
            balanceCurves[account.id] = Self.curve(booked: balance.bookedCents, nets: dailyBookedNet[account.id] ?? emptyDays,
                                                   path: path, horizon: horizon, today: today)
        }
    }

    private static let shortDay = Date.FormatStyle(locale: Locale(identifier: "de_DE"), timeZone: BankDay.bankTimeZone).day().month(.wide)

    /// The balance walked through the known payments only, as the shortfall warning counts it.
    static func knownPath(_ basis: ForecastBasis, today: BankDay) -> ForecastPath {
        BalanceForecast.path(start: basis.startCents, events: basis.forecast.events.filter { !$0.isEstimate },
                             today: today, until: basis.horizon)
    }

    /// Only a warning about expected payments: an account already below zero with nothing outgoing
    /// expected gets none (its balance says it).
    private static func shortfall(_ path: ForecastPath) -> Shortfall? {
        let outgoing = path.steps.reduce(0) { $0 + max(0, -$1.event.cents) }
        guard let firstDay = path.firstNegativeDay, path.lowestCents < 0, outgoing > 0 else { return nil }
        return Shortfall(day: firstDay, missingCents: -path.lowestCents, plannedOutCents: outgoing,
                         dayText: firstDay.startDate.formatted(shortDay), missingText: Money.format(-path.lowestCents))
    }

    /// End-of-day balances of the last `overviewDays` days, walked back from today's balance.
    private static func past(booked: Int, nets: [Int], today: BankDay) -> [BalanceCurve.Point] {
        let first = today.adding(days: -(overviewDays - 1))
        var running = booked
        var past: [BalanceCurve.Point] = []
        for slot in stride(from: overviewDays - 1, through: 0, by: -1) {
            past.append(.init(index: slot, day: first.adding(days: slot), cents: running, isForecast: false))
            running -= nets.indices.contains(slot) ? nets[slot] : 0
        }
        past.reverse()
        return past
    }

    private static func curve(booked: Int, nets: [Int], path: ForecastPath, horizon: BankDay, today: BankDay) -> BalanceCurve {
        var index = overviewDays
        func point(_ day: BankDay, _ cents: Int) -> BalanceCurve.Point {
            defer { index += 1 }
            return .init(index: index, day: day, cents: cents, isForecast: true)
        }
        var forecast = [point(today, booked), point(today, path.startCents)]
        for step in path.steps { forecast.append(point(step.day, step.cents)) }
        forecast.append(point(horizon, path.endCents))
        let low = forecast.min { $0.cents < $1.cents }
        return BalanceCurve(past: past(booked: booked, nets: nets, today: today), forecast: forecast, todayCents: booked,
                            endCents: path.endCents, end: horizon, lowest: (low?.cents ?? 0) < 0 ? low : nil)
    }

    /// Newer first: later date, on the same day pending before booked, then snapshot order.
    private static func isNewer(_ a: (transaction: MFNCore.Transaction, offset: Int), than b: (transaction: MFNCore.Transaction, offset: Int)) -> Bool {
        let dayA = a.transaction.effectiveDate, dayB = b.transaction.effectiveDate
        if dayA != dayB { return dayA > dayB }
        let pendingA = a.transaction.status == .pending, pendingB = b.transaction.status == .pending
        if pendingA != pendingB { return pendingA }
        return a.offset < b.offset
    }

    /// Keeps `list` sorted and at most `limit` long: one pass over the ledger, no full sort.
    private static func insertLatest(_ transaction: MFNCore.Transaction, offset: Int, into list: inout [(transaction: MFNCore.Transaction, offset: Int)], limit: Int) {
        let entry = (transaction: transaction, offset: offset)
        if list.count == limit, let last = list.last, !isNewer(entry, than: last) { return }
        let index = list.firstIndex { isNewer(entry, than: $0) } ?? list.endIndex
        list.insert(entry, at: index)
        if list.count > limit { list.removeLast() }
    }
}

/// Inputs of `LedgerBase`: the list's query-independent part.
struct LedgerBaseKey: Equatable {
    let item: SidebarItem
    let revision: Int
    let today: BankDay
}

/// Inputs of `LedgerContent`; everything else it reads comes from the snapshot (`revision`).
struct LedgerCacheKey: Equatable {
    let item: SidebarItem
    let query: TransactionQuery
    let showCancelled: Bool
    let revision: Int
    let today: BankDay
    let newRevision: Int
}

#if DEBUG
extension AppModel {
    /// Unit tests feed a ledger without a store (and so without Keychain or Touch ID).
    func applyLedgerForTesting(_ snapshot: LedgerSnapshot) { ledger = snapshot }

    /// Unit tests inject figures that are otherwise derived from a forecast.
    func applyIndexForTesting(_ index: SnapshotIndex) { self.index = index }
}
#endif
