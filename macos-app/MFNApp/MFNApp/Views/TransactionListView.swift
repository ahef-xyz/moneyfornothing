import AppKit
import MFNCore
import SwiftUI

/// Transaction list for one account or an overview (all accounts, review, pending).
///
/// Status is shown by shape and text, never by colour alone (CLAUDE.md §6 UI):
/// pending = italic, dashed ring and chip, own block on top; planned = additionally clock + date;
/// cancelled = struck through and hidden unless ⌥⌘S.
struct TransactionListView: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    /// Rows rendered so far (upcoming block not counted). A SwiftUI list with thousands of rows in
    /// hundreds of sections is slow to build and to diff; more rows load at the end of the list.
    @State private var rowLimit = Self.pageSize
    /// What the search field shows; reaches `model.ledgerQuery.text` after a short pause, so the
    /// list is not refiltered on every keystroke.
    @State private var searchText = ""

    static let pageSize = 300
    static let searchDebounce: Duration = .milliseconds(250)

    var body: some View {
        @Bindable var model = model
        let ledger = model.ledgerContent(for: item)
        let page = ledger.page(limit: rowLimit)
        // Once per body, not per use.
        let ownPlans = self.ownPlans

        VStack(spacing: 0) {
            LedgerHeader(ledger: ledger)
            // Own row like the filter bar: inside the header it pushed the header under the toolbar.
            if let account = ledger.account, let shortfall = model.shortfall(for: account.id) {
                Divider()
                ShortfallNotice(shortfall: shortfall)
            }
            if ledger.query.isFiltering {
                Divider()
                FilterBar(ledger: ledger)
            }
            Divider()
            if ledger.isEmpty, ownPlans.isEmpty {
                if ledger.query.isFiltering {
                    ContentUnavailableView.search(text: ledger.query.text)
                } else if let account = ledger.account, account.type != .depot {
                    // An empty account: history from the bank's CSV export (CLAUDE.md §1).
                    ContentUnavailableView {
                        Label(ledger.emptyTitle, systemImage: "tray")
                    } description: {
                        Text("Ältere Umsätze lassen sich aus einer CSV-Datei des Online-Bankings übernehmen.")
                    } actions: {
                        Button("Umsätze aus CSV importieren …") { model.beginCSVImport(for: account.id) }
                            .disabled(!model.canImportCSV)
                    }
                } else {
                    ContentUnavailableView(ledger.emptyTitle, systemImage: "tray")
                }
            } else {
                List(selection: $model.selectedTransactionIDs) {
                    if !ownPlans.isEmpty {
                        // Items a booking probably fulfilled are listed, but not summed (like
                        // "nach selbst Geplantem" in the header).
                        let matched = Set(ownPlans.filter { model.forecastBasis(of: $0.accountID)?.forecast.matches[$0.id] != nil }.map(\.id))
                        Section {
                            ForEach(ownPlans) { plan in
                                if let account = model.account(plan.accountID) {
                                    PlannedItemRow(item: plan, account: account,
                                                   accountName: ledger.showsAccountName ? ledger.accountName(plan.accountID) : nil,
                                                   isMatched: matched.contains(plan.id))
                                        .selectionDisabled()
                                }
                            }
                        } header: {
                            SectionHeaderRow(
                                title: "Selbst geplant",
                                trailing: "\(ownPlans.count == 1 ? "1 Buchung" : "\(ownPlans.count) Buchungen") · "
                                    + amount(ownPlans.filter { !matched.contains($0.id) }.reduce(0) { $0 + $1.amountCents }, currency: ledger.sumCurrency)
                            )
                        }
                    }
                    if !ledger.upcoming.isEmpty {
                        Section {
                            ForEach(ledger.upcoming) { TransactionRow(transaction: $0, info: ledger.rowInfo(for: $0)).equatable() }
                        } header: {
                            SectionHeaderRow(
                                title: "Vorgemerkt und geplant",
                                trailing: "\(ledger.upcoming.count) Umsätze · " + amount(ledger.sumCents(ledger.upcoming), currency: ledger.sumCurrency)
                            )
                        }
                    }
                    if ledger.query.sort.isChronological {
                        ForEach(page.days) { day in
                            Section {
                                ForEach(day.transactions) { TransactionRow(transaction: $0, info: ledger.rowInfo(for: $0)).equatable() }
                            } header: {
                                SectionHeaderRow(
                                    title: day.title,
                                    trailing: day.endBalance.map { "Saldo " + amount($0, currency: ledger.sumCurrency) }
                                )
                            }
                        }
                    } else if !ledger.flat.isEmpty {
                        Section {
                            ForEach(page.flat) { TransactionRow(transaction: $0, info: ledger.rowInfo(for: $0)).equatable() }
                        } header: {
                            SectionHeaderRow(title: ledger.query.sort.title, trailing: "\(ledger.flat.count) Umsätze")
                        }
                    }
                    if page.remaining > 0 {
                        LoadMoreRow(remaining: page.remaining, pageSize: Self.pageSize) { rowLimit += Self.pageSize }
                            .selectionDisabled()
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 46)
                // The list gives way to a taller header (e.g. the shortfall warning) instead of
                // the column overflowing.
                .frame(minHeight: 0, maxHeight: .infinity)
                .contextMenu(forSelectionType: TransactionID.self) { ids in
                    TransactionContextMenu(ids: ids)
                }
                // ⌫: removes the selection only if every row is CSV-imported (asks first).
                .onDeleteCommand {
                    if model.canRemoveSelectedImports { model.requestRemoveSelectedImports() }
                }
                .focused($listFocused)
                // Back to the sidebar (the list has no left/right movement of its own).
                .onKeyPress(.leftArrow) {
                    model.focusRequest = .sidebar
                    return .handled
                }
                // Esc first clears the selection (closing what it opened), then goes back.
                .onKeyPress(.escape) {
                    if !model.selectedTransactionIDs.isEmpty {
                        model.selectedTransactionIDs = []
                    } else {
                        model.focusRequest = .sidebar
                    }
                    return .handled
                }
            }
            Divider()
            LedgerFooter(ledger: ledger, selection: model.selectedTransactionIDs)
        }
        // If it is ever too tall anyway, the header stays below the toolbar: an overflowing column
        // was centred and pushed the header up under it. The zero minimums matter: without them
        // the frame takes the column's own height when that is larger, overflows its parent and
        // gets centred anyway (alignment only applies inside the frame).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        // A new list (other account, filter, sort) starts with one page again.
        .onChange(of: item) { rowLimit = Self.pageSize }
        .onChange(of: model.ledgerQuery) { rowLimit = Self.pageSize }
        .navigationTitle(ledger.title)
        .navigationSubtitle(ledger.subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Umsätze durchsuchen")
        .onChange(of: model.focusRequest) { takeFocus() }
        .onAppear {
            takeFocus()
            searchText = model.ledgerQuery.text
            // ⌘F from the overview switches here first; the request came before this view existed.
            if model.searchFocusRequested {
                Task { @MainActor in
                    searchFocused = true
                    model.searchFocusRequested = false
                }
            }
        }
        // Typing waits for a pause; clearing applies at once.
        .task(id: searchText) {
            guard searchText != model.ledgerQuery.text else { return }
            if !searchText.isEmpty {
                try? await Task.sleep(for: Self.searchDebounce)
                guard !Task.isCancelled else { return }
            }
            model.ledgerQuery.text = searchText
        }
        // Reset elsewhere (filter bar, menu, lock): the field follows.
        .onChange(of: model.ledgerQuery.text) { _, text in
            if text != searchText { searchText = text }
        }
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequested) { _, requested in
            guard requested else { return }
            searchFocused = true
            model.searchFocusRequested = false
        }
        .toolbar {
            ToolbarItemGroup {
                SortMenu(query: $model.ledgerQuery)
                FilterMenu(query: $model.ledgerQuery, ledger: ledger)
                Button {
                    model.showCategorySetup()
                } label: {
                    Label("Kategorien einrichten", systemImage: "wand.and.stars")
                }
                .help("Kategorien einrichten (⌥⌘K)")
                .disabled(!model.canShowCategorySetup)
                Button {
                    model.exportCSV()
                } label: {
                    Label("Umsätze als CSV exportieren", systemImage: "square.and.arrow.up")
                }
                .help("Umsätze als CSV exportieren (⇧⌘E)")
                .disabled(!model.canExportCSV)
            }
        }
    }

    /// The user's planned items: of the shown account, all of them in "Alle Konten" and
    /// "Vorgemerkt". None while filtering (they have no category, counterpart or purpose).
    private var ownPlans: [PlannedItem] {
        switch item {
        case let .account(id):
            var query = model.ledgerQuery
            query.accounts = []
            return query.isFiltering ? [] : model.plannedItems(for: id)
        case .allAccounts, .pending:
            return model.ledgerQuery.isFiltering ? [] : model.snapshot.plannedItems
        case .overview, .review:
            return []
        }
    }

    /// The sidebar handed the focus over (→ or Return there). An empty list takes it too, so the
    /// request does not linger.
    private func takeFocus() {
        guard model.focusRequest == .content else { return }
        model.focusRequest = nil
        listFocused = true
    }

    private func amount(_ cents: Int, currency: String) -> String {
        model.hideAmounts ? "•••••" : Money.format(cents, currency: currency)
    }
}

// MARK: - Content

/// The query-independent part of a list: what it shows, names, balances, recurring. Cached per
/// sidebar item and snapshot revision, so typing in the search field does not recompute it.
@MainActor
struct LedgerBase {
    let item: SidebarItem
    let account: Account?
    let balance: Balance?
    let title: String
    let subtitle: String
    /// Everything this list can show, newest first.
    let source: [MFNCore.Transaction]
    /// Categories and accounts present in this list, for the filter menu.
    let categories: [CategoryID]
    let filterAccounts: [Account]
    /// People (shared accounts) in this list, for the filter menu; empty if fewer than two.
    let people: [TransactionInitiator]
    let initiatorLookup: [TransactionID: TransactionInitiator]
    let shared: Set<AccountID>
    /// Current month, booked only, unfiltered: income and expenses (EUR).
    let monthInCents: Int
    let monthOutCents: Int
    /// Balance after each booked transaction; only for a single account with a known balance.
    let running: [TransactionID: Int]
    let recurring: Set<String>
    let showsAccountName: Bool
    let accountNames: [AccountID: String]
    /// Position in the newest-first booked list: the end-of-day balance belongs to the newest.
    let bookedOrder: [TransactionID: Int]
    /// Currency the list's sums are in: the account's, EUR in overviews. Other currencies are
    /// left out of sums rather than mixed in (like `AppModel.totalBalanceCents`).
    let sumCurrency: String
    /// Imported rows in this list (filter menu count).
    let importedCount: Int

    init(item: SidebarItem, model: AppModel, today: BankDay) {
        self.item = item
        let snapshot = model.snapshot
        let source: [MFNCore.Transaction]
        switch item {
        // `.overview` has its own view (`OverviewView`); as a list it is "Alle Konten".
        case .overview, .allAccounts:
            account = nil
            title = "Alle Konten"
            subtitle = "\(snapshot.accounts.count) Konten"
            source = snapshot.transactions
        case .review:
            account = nil
            title = "Zu prüfen"
            subtitle = "Konfidenz unter \(Categorizer.reviewThreshold.formatted(.number.locale(Locale(identifier: "de_DE"))))"
            source = snapshot.transactions.filter(model.needsReview)
        case .pending:
            account = nil
            title = "Vorgemerkt"
            subtitle = "Alle Konten"
            source = snapshot.transactions.filter(\.status.isUpcoming)
        case let .account(id):
            let account = model.account(id)
            self.account = account
            title = account?.name ?? "Konto"
            subtitle = account.map { model.connectionName($0.connectionID) } ?? ""
            source = snapshot.transactions(of: id)
        }
        self.source = source
        balance = account.flatMap { snapshot.balances[$0.id] }
        sumCurrency = account?.currency ?? "EUR"
        showsAccountName = account == nil
        accountNames = Dictionary(snapshot.accounts.map { ($0.id, "\(model.connectionName($0.connectionID)) \($0.name)") }, uniquingKeysWith: { a, _ in a })

        let month = TransactionQuery.Period.thisMonth.range(today: today)
        let monthBooked = source.filter { $0.status == .booked && $0.currency == "EUR" && (month?.contains($0.effectiveDate) ?? false) }
        monthInCents = monthBooked.filter { $0.amountCents > 0 }.sumCents
        monthOutCents = monthBooked.filter { $0.amountCents < 0 }.sumCents
        // From the cached per-snapshot index where the list is a whole account or all accounts.
        switch item {
        case .overview, .allAccounts: importedCount = model.importIndex.count
        case let .account(id): importedCount = model.importedCount(of: id)
        case .review, .pending: importedCount = source.count { $0.importID != nil }
        }
        categories = Array(Set(source.compactMap(\.categoryID))).sorted { ($0.catalogIndex, $0.rawValue) < ($1.catalogIndex, $1.rawValue) }
        let present = Set(source.map(\.accountID))
        filterAccounts = account == nil ? snapshot.accounts.filter { present.contains($0.id) } : []
        let lookup = model.initiators
        initiatorLookup = lookup
        shared = model.sharedAccounts
        var byKey: [String: TransactionInitiator] = [:]
        for transaction in source where model.sharedAccounts.contains(transaction.accountID) {
            if let person = lookup[transaction.id], byKey[person.key] == nil { byKey[person.key] = person }
        }
        people = byKey.count > 1 ? byKey.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : []

        // Running balances need every booked transaction of the account, filtered or not.
        let allBooked = source.filter { $0.status == .booked }
        bookedOrder = Dictionary(allBooked.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Snapshot transactions are newest first: walk back from today's balance.
        var running: [TransactionID: Int] = [:]
        if let balance, account != nil {
            var current = balance.bookedCents
            for transaction in allBooked {
                running[transaction.id] = current
                current -= transaction.amountCents
            }
        }
        self.running = running

        // Recurring: same counterpart booked in at least three different months.
        var months: [String: Set<Int>] = [:]
        for transaction in allBooked {
            let day = transaction.effectiveDate
            months[transaction.counterpartName.lowercased(), default: []].insert(day.year * 12 + day.month)
        }
        recurring = Set(months.filter { $0.value.count >= 3 }.keys)
    }

    /// Balance at the end of the day: after its newest booked transaction (whatever the sort).
    func endOfDayBalance(_ transactions: [MFNCore.Transaction]) -> Int? {
        transactions.filter { running[$0.id] != nil }
            .min { (bookedOrder[$0.id] ?? .max) < (bookedOrder[$1.id] ?? .max) }
            .flatMap { running[$0.id] }
    }
}

/// Everything the list needs: `LedgerBase` filtered and sorted by the query.
@MainActor
struct LedgerContent {
    struct Day: Identifiable {
        let day: BankDay
        let transactions: [MFNCore.Transaction]
        /// "Saldo" in the header, see `LedgerBase.endOfDayBalance`.
        let endBalance: Int?
        var id: BankDay { day }

        private static let titleStyle = Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "de_DE"), timeZone: BankDay.bankTimeZone)

        var title: String { day.startDate.formatted(Self.titleStyle) }
    }

    let base: LedgerBase
    /// The query as applied here (account filter dropped inside a single account).
    let query: TransactionQuery
    let upcoming: [MFNCore.Transaction]
    let days: [Day]
    /// Listed transactions in query order when not sorted by date (no day sections).
    let flat: [MFNCore.Transaction]
    /// Sum of everything listed (upcoming included, cancelled not), for the filter bar.
    let listedCents: Int
    let listedCount: Int
    let cancelledCount: Int
    let bookedCount: Int
    /// Everything listed, top to bottom.
    let ordered: [MFNCore.Transaction]
    /// Index into `ordered`.
    private let positions: [TransactionID: Int]

    init(base: LedgerBase, query: TransactionQuery, showCancelled: Bool, today: BankDay) {
        self.base = base
        var query = query
        if case .account = base.item { query.accounts = [] }
        self.query = query
        let names = base.accountNames
        let lookup = base.initiatorLookup
        let matching = query.isFiltering
            ? query.filter(base.source, today: today, accountName: { names[$0] }, initiator: { lookup[$0.id] })
            : base.source

        upcoming = query.sorted(matching.filter(\.status.isUpcoming))
        cancelledCount = matching.count(where: { $0.status == .cancelled })
        let booked = matching.filter { $0.status == .booked }
        bookedCount = booked.count
        let listed = query.sorted(showCancelled ? matching.filter { !$0.status.isUpcoming } : booked)
        var days: [Day] = []
        if query.sort.isChronological {
            var current: [MFNCore.Transaction] = []
            for transaction in listed {
                if let first = current.first, first.effectiveDate != transaction.effectiveDate {
                    days.append(Day(day: first.effectiveDate, transactions: current, endBalance: base.endOfDayBalance(current)))
                    current = []
                }
                current.append(transaction)
            }
            if let first = current.first { days.append(Day(day: first.effectiveDate, transactions: current, endBalance: base.endOfDayBalance(current))) }
        }
        self.days = days
        flat = query.sort.isChronological ? [] : listed
        let currency = base.sumCurrency
        listedCents = (upcoming + listed).filter { $0.status != .cancelled && $0.currency == currency }.sumCents
        listedCount = upcoming.count + listed.count
        let ordered = upcoming + listed
        self.ordered = ordered
        var positions: [TransactionID: Int] = [:]
        positions.reserveCapacity(ordered.count)
        for (offset, transaction) in ordered.enumerated() where positions[transaction.id] == nil {
            positions[transaction.id] = offset
        }
        self.positions = positions
    }

    var item: SidebarItem { base.item }
    var account: Account? { base.account }
    var balance: Balance? { base.balance }
    var title: String { base.title }
    var subtitle: String { base.subtitle }
    var categories: [CategoryID] { base.categories }
    var filterAccounts: [Account] { base.filterAccounts }
    var people: [TransactionInitiator] { base.people }
    var monthInCents: Int { base.monthInCents }
    var monthOutCents: Int { base.monthOutCents }
    var showsAccountName: Bool { base.showsAccountName }
    var sumCurrency: String { base.sumCurrency }
    var importedCount: Int { base.importedCount }

    /// Listed imported rows ("Alle entfernen …" in the filter bar).
    var listedImportedIDs: Set<TransactionID> {
        Set(ordered.lazy.filter { $0.importID != nil }.map(\.id))
    }

    var isEmpty: Bool { upcoming.isEmpty && days.isEmpty && flat.isEmpty }

    /// The first `limit` listed rows (days cut at a day boundary when possible) and what is left.
    struct Page {
        let days: [Day]
        let flat: [MFNCore.Transaction]
        let remaining: Int
    }

    func page(limit: Int) -> Page {
        if !query.sort.isChronological {
            return Page(days: [], flat: Array(flat.prefix(limit)), remaining: max(flat.count - limit, 0))
        }
        var shown: [Day] = []
        var count = 0
        for day in days {
            guard count < limit else { break }
            if count + day.transactions.count <= limit || shown.isEmpty {
                shown.append(day)
                count += day.transactions.count
            } else {
                let part = Array(day.transactions.prefix(limit - count))
                shown.append(Day(day: day.day, transactions: part, endBalance: base.endOfDayBalance(part)))
                count = limit
            }
        }
        let total = days.reduce(0) { $0 + $1.transactions.count }
        return Page(days: shown, flat: [], remaining: total - count)
    }

    /// Everything a row shows besides the transaction itself; equatable so unchanged rows are skipped.
    func rowInfo(for transaction: MFNCore.Transaction) -> TransactionRow.Info {
        TransactionRow.Info(
            showsDate: showsDate,
            showsAccountName: showsAccountName,
            accountName: showsAccountName ? accountName(transaction.accountID) : nil,
            initiatorName: initiatorName(of: transaction),
            isRecurring: isRecurring(transaction),
            running: base.running[transaction.id]
        )
    }

    /// "von …" in the row: only on shared accounts.
    func initiatorName(of transaction: MFNCore.Transaction) -> String? {
        base.shared.contains(transaction.accountID) ? base.initiatorLookup[transaction.id]?.name : nil
    }

    func person(_ key: String) -> TransactionInitiator? {
        people.first { $0.key == key } ?? base.initiatorLookup.values.first { $0.key == key }
    }

    /// Not grouped by day: the row shows its date.
    var showsDate: Bool { !query.sort.isChronological }

    var emptyTitle: String {
        switch item {
        case .review: "Nichts zu prüfen"
        case .pending: "Keine vorgemerkten Umsätze"
        case .overview, .allAccounts, .account: "Keine Umsätze"
        }
    }

    var pendingCents: Int { upcoming.filter { $0.status == .pending }.sumCents }

    func isRecurring(_ transaction: MFNCore.Transaction) -> Bool {
        base.recurring.contains(transaction.counterpartName.lowercased())
    }

    func accountName(_ id: AccountID) -> String {
        base.accountNames[id] ?? id.rawValue
    }

    /// Index of a listed transaction in `ordered`.
    func position(of id: TransactionID) -> Int? {
        positions[id]
    }

    /// Listed transactions with these IDs, top to bottom.
    func transactions(_ ids: Set<TransactionID>) -> [MFNCore.Transaction] {
        ids.compactMap { positions[$0] }.sorted().map { ordered[$0] }
    }

    /// Sum in the list's currency, cancelled ones left out (they never moved money).
    func sumCents(_ transactions: [MFNCore.Transaction]) -> Int {
        transactions.filter { $0.status != .cancelled && $0.currency == sumCurrency }.sumCents
    }
}

extension [MFNCore.Transaction] {
    var sumCents: Int { reduce(0) { $0 + $1.amountCents } }
}

// MARK: - Header and footer

/// Texts for `SnapshotIndex.Shortfall`: the balance does not cover the planned payments. Shown
/// only while amounts are visible (`AppModel.shortfall(for:)`).
enum ShortfallFormat {
    /// Orange exclamation circle: a warning, not an error (red), and a different shape than the
    /// budget's triangle.
    static let symbol = "exclamationmark.circle.fill"

    static func text(_ shortfall: SnapshotIndex.Shortfall) -> String {
        "Guthaben reicht nicht für \(payments(shortfall)): ab \(shortfall.dayText) fehlen bis zu \(shortfall.missingText)"
    }

    /// Short form for the sidebar tooltip and VoiceOver.
    static func short(_ shortfall: SnapshotIndex.Shortfall) -> String {
        "Reicht nicht für \(payments(shortfall)) ab \(shortfall.dayText), bis zu \(shortfall.missingText)"
    }

    private static func payments(_ shortfall: SnapshotIndex.Shortfall) -> String {
        shortfall.estimated ? "geplante und regelmäßige Zahlungen" : "geplante Zahlungen"
    }
}

/// Alert row below the account header (symbol + text, not colour alone).
struct ShortfallNotice: View {
    let shortfall: SnapshotIndex.Shortfall

    var body: some View {
        Label {
            Text(ShortfallFormat.text(shortfall))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ShortfallFormat.symbol)
                .foregroundStyle(.orange)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Rectangle().fill(Color.orange.opacity(0.12)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warnung: \(ShortfallFormat.text(shortfall))")
    }
}

private struct LedgerHeader: View {
    let ledger: LedgerContent
    @Environment(AppModel.self) private var model
    @State private var showsGiroCode = false
    /// Widths that decide whether the graph fits (`showsChart`).
    @State private var rowWidth: CGFloat = 0
    @State private var textIdealWidth: CGFloat = 0
    @State private var figuresWidth: CGFloat = 0
    @State private var chartWidth: CGFloat = 208
    /// Widths of the action row with labels and icon-only (`actions`).
    @State private var actionsWidth: CGFloat = 0
    @State private var compactActionsWidth: CGFloat = 0

    private var connection: Connection? {
        ledger.account.flatMap { account in model.snapshot.connections.first { $0.id == account.connectionID } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if let account = ledger.account, let status = model.budgetStatus(for: account.id) {
                BudgetBar(status: status)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The graph fits next to the untruncated text and the figures. Measured, not `ViewThatFits`:
    /// one row keeps the graph's identity (its popover and focus survive a resize) and the graph
    /// is laid out once.
    private var showsChart: Bool {
        guard rowWidth > 0 else { return true }
        let spacing: CGFloat = 14
        let badge: CGFloat = connection == nil ? 0 : 40 + spacing
        // The action row can always fall back to icons, so only its compact width counts here.
        let text = max(textIdealWidth, compactActionsWidth)
        let needed = badge + text + spacing + 12 + spacing + chartWidth + spacing + figuresWidth
        return needed <= rowWidth
    }

    /// Never wider than the column: an overflowing header pushed itself up under the toolbar.
    /// The graph goes first when space runs out, then the text block truncates; the figures
    /// shrink last.
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 14) {
            if let connection {
                BankBadge(connection: connection, size: 40)
            }
            textBlock()
                // Untruncated width, from an invisible copy that may grow past the row.
                .background(alignment: .leading) {
                    textBlock(measuring: true)
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textIdealWidth = $0 }
                }
            Spacer(minLength: 12)
            if showsChart, let account = ledger.account {
                AccountBalanceChart(account: account.id)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
            }
            figures
                .layoutPriority(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { figuresWidth = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    /// `measuring`: the invisible copy that sizes the row. It leaves out the action row, which
    /// `actions` measures itself (with and without labels).
    private func textBlock(measuring: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ledger.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                // The full name when it is cut short.
                .help(ledger.title)
            identity
                .font(.callout)
                .foregroundStyle(.secondary)
            activity
                .font(.caption)
                .foregroundStyle(.secondary)
            if !measuring, let account = ledger.account {
                actions(for: account)
                    .padding(.top, 4)
            }
        }
    }

    /// Sync, account details, budget: own row under the facts, so they never squeeze them.
    /// Icon-only when the labelled row does not fit the space the text block gets (tooltips keep
    /// the names). Decided from measured widths, not `ViewThatFits`: one copy of the buttons
    /// keeps the GiroCode popover anchored.
    private func actions(for account: Account) -> some View {
        actionButtons(for: account, compact: actionsWidth > textSpace, giroCode: $showsGiroCode)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    actionButtons(for: account, compact: false, giroCode: .constant(false), measuring: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
                    actionButtons(for: account, compact: true, giroCode: .constant(false), measuring: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { compactActionsWidth = $0 }
                }
                .hidden()
                .accessibilityHidden(true)
            }
    }

    /// `measuring`: an invisible copy for `actions`; it must not announce sync progress.
    private func actionButtons(for account: Account, compact: Bool, giroCode: Binding<Bool>, measuring: Bool = false) -> some View {
        HStack(spacing: 8) {
            if connection?.isManual == true {
                // v10: nothing to sync; new transactions come from CSV files.
                Button {
                    model.beginCSVImport(for: account.id)
                } label: {
                    Label("CSV importieren …", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canImportCSV)
                .help("Umsätze aus CSV importieren (⇧⌘I)")
            } else {
                AccountSyncButton(connectionID: account.connectionID, announces: !measuring)
            }
            AccountCopyMenu(account: account, balance: ledger.balance, bankName: connection?.displayName,
                            showsGiroCode: giroCode)
            if account.type != .depot {
                let hasBudget = model.budget(for: account.id) != nil
                Button {
                    model.showBudgetEditor(for: account)
                } label: {
                    Label(hasBudget ? "Budget ändern …" : "Budget festlegen …", systemImage: "gauge.with.needle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(hasBudget ? "Budget ändern oder entfernen" : "Ausgabenbudget für dieses Konto festlegen")
            }
            if model.forecastBasis(of: account.id) != nil {
                Button {
                    model.showForecast(for: account)
                } label: {
                    Label("Planen …", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Prognose ansehen und einmalige Ausgaben einplanen (⌥⌘P)")
            }
        }
        .labelStyle(CompactableLabelStyle(compact: compact))
        .lineLimit(1)
        .fixedSize()
    }

    /// Width the text block gets in the header row (same layout as `showsChart`).
    private var textSpace: CGFloat {
        guard rowWidth > 0 else { return .infinity }
        let spacing: CGFloat = 14
        let badge: CGFloat = connection == nil ? 0 : 40 + spacing
        let chart: CGFloat = showsChart ? chartWidth + spacing : 0
        return rowWidth - badge - spacing - 12 - spacing - chart - figuresWidth
    }

    /// Bank · type · IBAN (copyable) · card.
    @ViewBuilder
    private var identity: some View {
        if let account = ledger.account {
            HStack(spacing: 6) {
                Text([ledger.subtitle, account.type.title].joined(separator: " · "))
                if let iban = account.iban {
                    Text("·")
                    Text(IBANFormat.grouped(iban))
                        .monospaced()
                        .textSelection(.enabled)
                }
                if let last4 = account.cardLast4 {
                    Text("·")
                    Text("Karte ·· \(last4)").monospacedDigit()
                }
            }
            .lineLimit(1)
            .contextMenu {
                AccountCopyItems(account: account, balance: ledger.balance, bankName: connection?.displayName,
                                 onShowGiroCode: { showsGiroCode = true })
            }
        } else {
            Text(ledger.subtitle)
        }
    }

    /// This month's income and expenses, and the last sync.
    @ViewBuilder
    private var activity: some View {
        HStack(spacing: 10) {
            if ledger.monthInCents != 0 || ledger.monthOutCents != 0 {
                Label {
                    HStack(spacing: 6) {
                        Text("\(monthName):")
                        AmountText(cents: ledger.monthInCents, signed: true)
                        Text("Eingänge")
                        Text("·")
                        AmountText(cents: ledger.monthOutCents, colorsInflow: false)
                            .foregroundStyle(.secondary)
                        Text("Ausgaben")
                    }
                } icon: {
                    Image(systemName: "calendar")
                }
            }
            if let account = ledger.account {
                if connection?.isManual == true {
                    Label("ohne Anbindung", systemImage: "tray.and.arrow.down")
                } else if let lastSync = model.snapshot.syncStates[account.connectionID]?.lastSuccess {
                    Label("abgeglichen \(DayFormat.syncTime(lastSync))", systemImage: "clock")
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private var monthName: String {
        Date().formatted(.dateTime.month(.wide).locale(Locale(identifier: "de_DE")))
    }

    @ViewBuilder
    private var figures: some View {
        HStack(alignment: .top, spacing: 28) {
            if let balance = ledger.balance {
                Figure(label: ledger.account?.type == .card ? "Saldo" : "Gebucht", cents: balance.bookedCents, currency: balance.currency)
                if let available = balance.availableCents {
                    Figure(label: "Verfügbar", cents: available, currency: balance.currency) {
                        if let planned = ledger.account.map({ model.ownPlannedCents(for: $0.id) }), planned != 0 {
                            Text("\(model.hideAmounts ? "•••••" : Money.format(available + planned)) nach selbst Geplantem")
                                .accessibilityLabel(model.hideAmounts ? "Betrag ausgeblendet, nach selbst Geplantem" : "\(Money.format(available + planned)) nach selbst Geplantem")
                                .help("Verfügbar abzüglich der selbst geplanten Buchungen (\(model.hideAmounts ? "•••••" : Money.format(planned, signed: true)))")
                        }
                        if ledger.pendingCents != 0 {
                            Text("gebucht \(ledger.pendingCents < 0 ? "−" : "+") \(model.hideAmounts ? "•••••" : Money.format(abs(ledger.pendingCents))) vorgemerkt")
                                .accessibilityLabel(model.hideAmounts ? "Betrag ausgeblendet, vorgemerkt" : "gebucht \(ledger.pendingCents < 0 ? "minus" : "plus") \(Money.format(abs(ledger.pendingCents))) vorgemerkt")
                        }
                    }
                }
                // No "Verfügbar" from the bank (most giro accounts): what is left after pending
                // and self-planned payments, as a figure of its own. Simulated: the label and the
                // caption say so (not a dimmed colour, it is a key figure).
                if balance.availableCents == nil, let planned = ledger.account.map({ model.ownPlannedCents(for: $0.id) }), planned != 0 {
                    let pending = ledger.account.flatMap { model.forecastBasis(of: $0.id) }.map { $0.startCents - $0.bookedCents } ?? 0
                    Figure(label: "Nach Geplantem", cents: balance.bookedCents + pending + planned, currency: balance.currency) {
                        // Two short lines like "Verfügbar": one long line made the figure too wide.
                        Text("gebucht \(planned < 0 ? "−" : "+") \(model.hideAmounts ? "•••••" : Money.format(abs(planned))) geplant")
                            .accessibilityLabel(model.hideAmounts ? "Betrag ausgeblendet, selbst geplant" : "simuliert: gebucht \(planned < 0 ? "abzüglich" : "zuzüglich") \(Money.format(abs(planned))) selbst geplant")
                        if pending != 0 {
                            Text("\(pending < 0 ? "−" : "+") \(model.hideAmounts ? "•••••" : Money.format(abs(pending))) vorgemerkt")
                                .accessibilityLabel(model.hideAmounts ? "Betrag ausgeblendet, vorgemerkt" : "\(pending < 0 ? "minus" : "plus") \(Money.format(abs(pending))) vorgemerkt")
                        }
                    }
                    .help("Simuliert: gebuchter Saldo mit vorgemerkten und selbst geplanten Buchungen. Regelmäßige Buchungen zeigt die Prognose (⌥⌘P).")
                }
                if let limit = ledger.account?.creditLimitCents {
                    Figure(label: "Limit", cents: limit, currency: balance.currency)
                        .foregroundStyle(.secondary)
                }
            } else if ledger.item == .allAccounts || ledger.item == .overview {
                Figure(label: "Gesamt", cents: model.totalBalanceCents, currency: "EUR")
            }
        }
    }
}

/// Icon only when `compact`, otherwise title and icon.
private struct CompactableLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            IconOnlyLabelStyle().makeBody(configuration: configuration)
        } else {
            TitleAndIconLabelStyle().makeBody(configuration: configuration)
        }
    }
}

private struct Figure<Caption: View>: View {
    let label: String
    let cents: Int
    let currency: String
    @ViewBuilder var caption: Caption

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            AmountText(cents: cents, currency: currency, colorsInflow: false)
                .font(.title.weight(.semibold))
                // Shrinks rather than being cut off when even the figures alone do not fit.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

extension Figure where Caption == EmptyView {
    init(label: String, cents: Int, currency: String) {
        self.init(label: label, cents: cents, currency: currency) { EmptyView() }
    }
}

private struct LedgerFooter: View {
    let ledger: LedgerContent
    let selection: Set<TransactionID>
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(summary)
            if ledger.cancelledCount > 0 {
                Button(model.showCancelled ? "ausblenden" : "einblenden") { model.showCancelled.toggle() }
                    .buttonStyle(.link)
                    .help(model.showCancelled ? "Stornos ausblenden (⌥⌘S)" : "Stornos einblenden (⌥⌘S)")
            }
            Spacer()
            if model.showsSetupHint, selection.isEmpty {
                // Quiet hint instead of a banner: how much is categorized, one click to the assistant.
                Text("\(Int((model.categorizationCoverage * 100).rounded())) % kategorisiert")
                    .monospacedDigit()
                Divider()
                    .frame(height: 12)
                    .padding(.horizontal, 4)
                Button("Kategorien einrichten …") { model.showCategorySetup() }
                    .buttonStyle(.link)
                    .help("Assistent: mit wenigen Entscheidungen den Großteil zuordnen (⌥⌘K)")
            }
            if !selection.isEmpty {
                let selected = ledger.transactions(selection)
                Text("Ausgewählt: \(selected.count) · \(model.hideAmounts ? "•••••" : Money.format(ledger.sumCents(selected), currency: ledger.sumCurrency))")
                    .monospacedDigit()
                    .accessibilityLabel(model.hideAmounts ? "Ausgewählt: \(selected.count), Betrag ausgeblendet" : "Ausgewählt: \(selected.count), Summe \(Money.format(ledger.sumCents(selected), currency: ledger.sumCurrency))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var summary: String {
        var parts = [ledger.query.isFiltering ? "\(ledger.bookedCount) Treffer" : "\(ledger.bookedCount) Umsätze"]
        if !ledger.upcoming.isEmpty { parts.append("\(ledger.upcoming.count) vorgemerkt") }
        if ledger.cancelledCount > 0 {
            parts.append("\(ledger.cancelledCount) storniert")
        }
        return parts.joined(separator: " · ")
    }
}

private struct SectionHeaderRow: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fontWeight(.regular)
            }
        }
    }
}

// MARK: - Row

struct TransactionRow: View, Equatable {
    struct Info: Equatable {
        let showsDate: Bool
        let showsAccountName: Bool
        let accountName: String?
        let initiatorName: String?
        let isRecurring: Bool
        let running: Int?
    }

    let transaction: MFNCore.Transaction
    let info: Info
    @Environment(AppModel.self) private var model

    nonisolated static func == (lhs: TransactionRow, rhs: TransactionRow) -> Bool {
        lhs.transaction == rhs.transaction && lhs.info == rhs.info
    }

    private var status: TransactionStatus { transaction.status }

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(name: transaction.counterpartName, status: status, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if status == .planned {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                    }
                    Text(transaction.counterpartName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(transaction.purpose)

            hints
                .frame(width: 210, alignment: .leading)

            AmountText(cents: transaction.amountCents, currency: transaction.currency, colorsInflow: status != .cancelled, signed: true)
                .fontWeight(status == .booked ? .medium : .regular)
                // A minimum, not a fixed width: columns line up, larger text grows instead of clipping.
                .frame(minWidth: 110, alignment: .trailing)
                .layoutPriority(1)

            if !info.showsAccountName {
                Group {
                    if let running = info.running {
                        AmountText(cents: running, currency: transaction.currency, colorsInflow: false)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("–").foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 100, alignment: .trailing)
                .layoutPriority(1)
            }
        }
        .italic(status.isUpcoming)
        .strikethrough(status == .cancelled)
        .opacity(status == .cancelled ? 0.55 : 1)
        .padding(.vertical, 3)
        .tag(transaction.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(accessibilityAmount)
        .modifier(RowCategoryActions(transaction: transaction))
    }

    private var accessibilityText: String {
        var parts = [transaction.counterpartName]
        switch status {
        case .pending: parts.append("vorgemerkt")
        case .planned: parts.append("geplant")
        case .cancelled: parts.append("storniert")
        case .booked: break
        }
        let sub = subtitle
        if !sub.isEmpty { parts.append(sub) }
        if let category = transaction.categoryID {
            parts.append(model.needsReview(transaction) ? "Kategorievorschlag \(category.title)" : "Kategorie \(category.title)")
        }
        if info.isRecurring, status != .cancelled { parts.append("wiederkehrend") }
        if transaction.isImported { parts.append("importiert") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityAmount: String {
        model.hideAmounts ? "Betrag ausgeblendet" : Money.format(transaction.amountCents, currency: transaction.currency, signed: true)
    }

    private var subtitle: String {
        var parts: [String] = []
        if info.showsDate { parts.append(listDate(transaction.effectiveDate)) }
        if let person = info.initiatorName { parts.append("von \(person)") }
        if let account = info.accountName { parts.append(account) }
        if !transaction.purpose.isEmpty { parts.append(transaction.purpose) }
        // ⇧⌘H: the original amount in a foreign currency is an amount too.
        if let foreign = model.foreignAmountText(of: transaction) { parts.append(foreign) }
        if status == .planned {
            parts.append("fällig \(shortDate(transaction.valueDate))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var hints: some View {
        HStack(spacing: 4) {
            switch status {
            case .pending:
                HintChip(text: "Vorgemerkt", dashed: true)
            case .planned:
                HintChip(text: "Geplant · \(shortDate(transaction.valueDate))", dashed: true)
            case .cancelled:
                HintChip(text: "Storniert", muted: true)
            case .booked:
                EmptyView()
            }
            if let category = transaction.categoryID {
                if model.needsReview(transaction) {
                    SuggestionChip(transaction: transaction, category: category)
                } else {
                    CategoryChip(transaction: transaction)
                }
            }
            if status != .cancelled, info.isRecurring {
                HintChip(text: "Wiederkehrend")
            }
            if transaction.isImported {
                ImportedMarker()
            }
        }
        .italic(false)
        .strikethrough(false)
    }

    private static let dayMonth = Date.FormatStyle(locale: Locale(identifier: "de_DE"), timeZone: BankDay.bankTimeZone).day().month(.abbreviated)
    private static let dayMonthYear = dayMonth.year()

    /// "3. Nov." this year, "3. Nov. 2025" otherwise.
    private func listDate(_ day: BankDay) -> String {
        day.startDate.formatted(day.year == BankDay.today.year ? Self.dayMonth : Self.dayMonthYear)
    }

    private func shortDate(_ day: BankDay) -> String {
        day.startDate.formatted(Self.dayMonth)
    }
}

/// Chip actions of a row stay reachable for VoiceOver although the row is one element.
private struct RowCategoryActions: ViewModifier {
    let transaction: MFNCore.Transaction
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Vorschlag übernehmen") { model.acceptSuggestion(for: transaction) }
            .accessibilityAction(named: "Kategorie ändern") { model.showCategoryPicker(for: [transaction.id]) }
    }
}

/// End of a long list: loads the next page when it scrolls into view, or on click.
private struct LoadMoreRow: View {
    let remaining: Int
    let pageSize: Int
    let load: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Weitere \(min(remaining, pageSize)) von \(remaining) Umsätzen anzeigen", action: load)
                .buttonStyle(.link)
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear(perform: load)
    }
}

// MARK: - Helpers


extension AccountType {
    var title: String {
        switch self {
        case .giro: "Girokonto"
        case .tagesgeld: "Tagesgeld"
        case .depot: "Depot"
        case .card: "Kreditkarte"
        }
    }
}

enum IBANFormat {
    /// "DE87300209005320200054" → "DE87 3002 0900 5320 2000 54"
    static func grouped(_ iban: String) -> String {
        var result = ""
        for (index, character) in iban.filter({ !$0.isWhitespace }).enumerated() {
            if index > 0, index.isMultiple(of: 4) { result.append(" ") }
            result.append(character)
        }
        return result
    }
}

// MARK: - Search, sort, filter

extension TransactionQuery.Sort {
    var title: String {
        switch self {
        case .newestFirst: "Datum, neueste zuerst"
        case .oldestFirst: "Datum, älteste zuerst"
        case .largestOutflow: "Größte Ausgaben zuerst"
        case .largestInflow: "Größte Eingänge zuerst"
        case .counterpart: "Empfänger/Auftraggeber A–Z"
        }
    }
}

extension TransactionQuery.Direction {
    var title: String {
        switch self {
        case .all: "Ein- und Ausgänge"
        case .inflow: "Nur Eingänge"
        case .outflow: "Nur Ausgänge"
        }
    }
}

extension TransactionQuery.Period {
    var title: String {
        switch self {
        case .all: "Gesamter Zeitraum"
        case .thisMonth: "Dieser Monat"
        case .lastMonth: "Letzter Monat"
        case .last30Days: "Letzte 30 Tage"
        case .last90Days: "Letzte 90 Tage"
        case .thisYear: "Dieses Jahr"
        case .lastYear: "Letztes Jahr"
        }
    }
}

private struct SortMenu: View {
    @Binding var query: TransactionQuery

    var body: some View {
        Menu {
            Picker("Sortieren", selection: $query.sort) {
                ForEach(TransactionQuery.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sortieren", systemImage: "arrow.up.arrow.down")
        }
        .help("Sortieren: \(query.sort.title)")
    }
}

private struct FilterMenu: View {
    @Binding var query: TransactionQuery
    let ledger: LedgerContent

    var body: some View {
        Menu {
            Picker("Richtung", selection: $query.direction) {
                ForEach(TransactionQuery.Direction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Zeitraum", selection: $query.period) {
                ForEach(TransactionQuery.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Nur ohne Kategorie", isOn: $query.onlyUncategorized)
            Toggle(ledger.importedCount > 0 ? "Nur importierte (\(ledger.importedCount))" : "Nur importierte", isOn: $query.onlyImported)
                .help("Nur Umsätze aus CSV-Importen (⌃⌘I)")
            if !ledger.categories.isEmpty || query.category != nil {
                Picker("Kategorie", selection: $query.category) {
                    Text("Alle Kategorien").tag(CategoryID?.none)
                    ForEach(ledger.categories, id: \.self) { Text($0.title).tag(CategoryID?.some($0)) }
                }
                .disabled(query.onlyUncategorized)
            }
            if !ledger.people.isEmpty || query.initiator != nil {
                Picker("Person", selection: $query.initiator) {
                    Text("Alle Personen").tag(String?.none)
                    ForEach(ledger.people, id: \.key) { Text($0.name).tag(String?.some($0.key)) }
                }
            }
            if ledger.filterAccounts.count > 1 {
                Picker("Konto", selection: Binding(
                    get: { query.accounts.first },
                    set: { query.accounts = $0.map { [$0] } ?? [] }
                )) {
                    Text("Alle Konten").tag(AccountID?.none)
                    ForEach(ledger.filterAccounts) { account in
                        Text(ledger.accountName(account.id)).tag(AccountID?.some(account.id))
                    }
                }
            }
            Divider()
            Button("Filter zurücksetzen") { query.resetFilters() }
                .disabled(!ledger.query.isFiltering)
        } label: {
            Label("Filter", systemImage: ledger.query.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filtern")
    }
}

/// Shown while a search or filter narrows the list: what is active, matches and their sum.
private struct FilterBar: View {
    let ledger: LedgerContent
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(description)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(ledger.listedCount) Treffer · \(model.hideAmounts ? "•••••" : Money.format(ledger.listedCents, currency: ledger.sumCurrency))")
                .accessibilityLabel(model.hideAmounts ? "\(ledger.listedCount) Treffer, Betrag ausgeblendet" : "\(ledger.listedCount) Treffer, Summe \(Money.format(ledger.listedCents, currency: ledger.sumCurrency))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if ledger.query.onlyImported {
                // The filter lists imported rows only: the IDs (and the check that all are
                // imported, in `requestRemoveImports`) are needed on press, not per body pass.
                Button("Alle entfernen …") { model.requestRemoveImports(ledger.listedImportedIDs) }
                    .buttonStyle(.link)
                    .disabled(ledger.listedCount == 0 || model.lock.isLocked)
                    .help("Die angezeigten importierten Umsätze entfernen (fragt nach)")
            }
            Button("Zurücksetzen") {
                model.ledgerQuery.resetFilters()
                model.ledgerQuery.text = ""
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var description: String {
        let query = ledger.query
        var parts: [String] = []
        let words = query.text.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { parts.append("„\(words)“") }
        if query.direction != .all { parts.append(query.direction.title) }
        if query.period != .all { parts.append(query.period.title) }
        if query.onlyUncategorized {
            parts.append("ohne Kategorie")
        } else if let category = query.category {
            parts.append(category.title)
        }
        if query.onlyImported { parts.append("importiert") }
        if let key = query.initiator { parts.append("von \(ledger.person(key)?.name ?? "…")") }
        if let account = query.accounts.first { parts.append(ledger.accountName(account)) }
        return parts.joined(separator: " · ")
    }
}

extension TransactionQuery {
    /// Filters back to default; search text and sort stay.
    mutating func resetFilters() {
        direction = .all
        period = .all
        category = nil
        accounts = []
        initiator = nil
        onlyUncategorized = false
        onlyImported = false
    }
}

// MARK: - Suggestion and setup notice

/// A suggestion waiting for review: dashed chip with "?" (not colour alone). Click takes it,
/// the arrow offers likely categories and the full list.
struct SuggestionChip: View {
    let transaction: MFNCore.Transaction
    let category: CategoryID
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.acceptSuggestion(for: transaction)
            } label: {
                Label("\(category.title) übernehmen", systemImage: "checkmark")
            }
            Divider()
            ForEach(model.likelyCategories(for: transaction).filter { $0 != category }.prefix(5), id: \.self) { other in
                Button {
                    model.setCategory(other, for: [transaction.id])
                } label: {
                    Label(other.title, systemImage: other.symbol)
                }
            }
            Divider()
            Button("Andere Kategorie …") { model.showCategoryPicker(for: [transaction.id]) }
        } label: {
            // Between the default menu size (too large) and `CategoryChip` (too small next to it):
            // small control, callout text, own arrow (the menu's indicator follows the control size).
            HStack(spacing: 3) {
                Image(systemName: category.symbol)
                    .imageScale(.small)
                Text(category.title + "?")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
                    .opacity(0.8)
                    // Decoration: the menu button already says it opens a menu.
                    .accessibilityHidden(true)
            }
            .font(.callout)
        } primaryAction: {
            model.acceptSuggestion(for: transaction)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .font(.callout)
        .fixedSize()
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .help("Vorschlag \(category.title): Klick übernimmt (⌘⏎), Pfeil für andere Kategorien (⌘K) · \(CategoryFormat.provenance(transaction))")
        .accessibilityLabel("Vorschlag \(category.title), übernehmen oder ändern")
    }
}

