import Charts
import MFNCore
import SwiftUI

/// "Übersicht" (⌘0): every bank with its sync state and sum, its accounts with balance and budget,
/// and each account's newest transactions. Plain sections with dividers, no cards (CLAUDE.md §6).
///
/// Everything per account comes from `SnapshotIndex` (built once per snapshot revision), so the
/// body never scans the ledger.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(OverviewSection.storageKey) private var hiddenRaw = ""
    /// Keyboard focus: tiles, account rows and transactions in reading order (`targets`).
    @FocusState private var focus: OverviewFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Not `LazyVGrid`: with many accounts arriving at once (C24, 7 accounts) while a sheet closes,
    // the lazy placement looped on the main thread for minutes. The grids hold a few boxes only.
    private static let chartColumns = AdaptiveColumns(minimum: 380, spacing: 16)
    private static let bankColumns = AdaptiveColumns(minimum: 340, spacing: 16)
    private static let figureColumns = AdaptiveColumns(minimum: 190, spacing: 16)

    private var hidden: Set<OverviewSection> { OverviewSection.decode(hiddenRaw) }

    var body: some View {
        let connections = model.orderedConnections
        Group {
            if connections.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Bank", systemImage: "building.columns")
                } description: {
                    Text("Füge eine Bank hinzu, um hier Konten, Salden und die neuesten Umsätze zu sehen.")
                } actions: {
                    Button("Bank hinzufügen …") { model.showBankSetup() }
                        .disabled(!model.canAddBank)
                        .help(model.isDemo ? String(localized: "In der Demo nicht verfügbar") : String(localized: "Bank hinzufügen (⇧⌘N)"))
                }
            } else if hidden.count == OverviewSection.allCases.count {
                ContentUnavailableView {
                    Label("Alles ausgeblendet", systemImage: "rectangle.dashed")
                } description: {
                    Text("Über „Anpassen“ in der Symbolleiste lassen sich die Bereiche wieder einblenden.")
                } actions: {
                    Button("Alle einblenden") { hiddenRaw = "" }
                }
            } else {
                let data = OverviewData(model: model, connections: connections)
                // The focus order is only built on a key press, not on every redraw.
                let targets = { self.targets(connections, data: data) }
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if shows(.balance) {
                            DashboardBox(.balance, hide: hide) { OverviewHero(data: data) }
                        }
                        if shows(.figures) {
                            KeyFigures(data: data, columns: Self.figureColumns, focus: $focus, hide: hide)
                        }
                        if shows(.flows) || shows(.spending) {
                            Self.chartColumns {
                                if shows(.flows) {
                                    DashboardBox(.flows, subtitle: "Letzte 6 Monate, ohne Umbuchungen zwischen eigenen Konten", hide: hide) {
                                        FlowChart(months: data.flows)
                                    }
                                }
                                if shows(.spending) {
                                    DashboardBox(.spending, subtitle: "Dieser Monat", hide: hide) {
                                        SpendingChart(groups: data.spending)
                                    }
                                }
                            }
                        }
                        if shows(.accounts) {
                            Self.bankColumns {
                                ForEach(connections) { connection in
                                    BankOverviewSection(connection: connection, focus: $focus, hide: hide)
                                }
                            }
                        }
                        if shows(.latest) {
                            DashboardBox(.latest, hide: hide, accessory: {
                                Button("Alle Umsätze") { model.selection = .allAccounts }
                                    .buttonStyle(.link)
                                    .focusable()
                                    .focused($focus, equals: .allTransactions)
                                    .onKeyPress(.return) {
                                        model.selection = .allAccounts
                                        return .handled
                                    }
                                    .id(OverviewFocus.allTransactions)
                            }) {
                                LatestSection(transactions: data.latest, focus: $focus)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Arrows move through the targets; ← on the first one and Esc go back to the sidebar.
                    .onKeyPress(keys: [.downArrow, .rightArrow]) { _ in move(by: 1, in: targets(), proxy: proxy) }
                    .onKeyPress(keys: [.upArrow, .leftArrow]) { press in
                        let list = targets()
                        if press.key == .leftArrow, focus == list.first || focus == nil { return toSidebar() }
                        return move(by: -1, in: list, proxy: proxy)
                    }
                    .onKeyPress(.escape) { toSidebar() }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                // Tab moves the focus too: keep the focused element in view.
                .onChange(of: focus) { _, target in
                    guard let target else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { proxy.scrollTo(target) }
                }
                .onChange(of: model.focusRequest) { takeFocus(targets(), proxy: proxy) }
                .onAppear { takeFocus(targets(), proxy: proxy) }
                }
            }
        }
        // Empty states have nothing to focus: drop a request from the sidebar, so it does not
        // reach a list shown later.
        .onChange(of: model.focusRequest) { _, request in
            if request == .content, connections.isEmpty || hidden.count == OverviewSection.allCases.count {
                model.focusRequest = nil
            }
        }
        .navigationTitle("Übersicht")
        .navigationSubtitle(subtitle(connections))
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(OverviewSection.allCases) { section in
                        Toggle(isOn: binding(section)) {
                            Label(section.title, systemImage: section.symbol)
                        }
                    }
                    Divider()
                    Button("Alle einblenden") { hiddenRaw = "" }
                        .disabled(hidden.isEmpty)
                } label: {
                    Label("Anpassen", systemImage: "slider.horizontal.3")
                }
                .help("Bereiche der Übersicht ein- und ausblenden")
            }
        }
    }

    private func shows(_ section: OverviewSection) -> Bool { !hidden.contains(section) }

    /// Focusable elements in reading order: figures, per bank its sync button (when usable) and
    /// accounts, "Alle Umsätze" and the newest transactions.
    private func targets(_ connections: [Connection], data: OverviewData) -> [OverviewFocus] {
        var list: [OverviewFocus] = []
        if shows(.figures) {
            list += [.pending, .review]
            if let next = model.plannedOverview.next, model.account(next.accountID) != nil { list.append(.planned) }
        }
        if shows(.accounts) {
            for connection in connections {
                // A disabled button cannot take the focus: the arrows would lose their place.
                if !model.lock.isLocked, connection.connectorID.hasConnector, BankOverviewHeader.canSync(model.syncState(connection.id)) {
                    list.append(.sync(connection.id))
                }
                list += model.orderedAccounts(of: connection.id).map { .account($0.id) }
            }
        }
        if shows(.latest) { list += [.allTransactions] + data.latest.map { .transaction($0.id) } }
        return list
    }

    private func move(by offset: Int, in targets: [OverviewFocus], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !targets.isEmpty else { return .ignored }
        let current = focus.flatMap { targets.firstIndex(of: $0) } ?? (offset > 0 ? -1 : targets.count)
        focusScrolled(targets[min(max(current + offset, 0), targets.count - 1)], proxy: proxy)
        return .handled
    }

    /// Scrolls first, focuses afterwards: rows of the lazy grids far below are not built yet and
    /// could not take the focus (it would fall back to nil and the arrows restart at the top).
    private func focusScrolled(_ target: OverviewFocus, proxy: ScrollViewProxy) {
        proxy.scrollTo(target)
        Task { @MainActor in focus = target }
    }

    private func toSidebar() -> KeyPress.Result {
        focus = nil
        model.focusRequest = .sidebar
        return .handled
    }

    /// The sidebar handed the focus over (→ or Return there).
    private func takeFocus(_ targets: [OverviewFocus], proxy: ScrollViewProxy) {
        guard model.focusRequest == .content else { return }
        model.focusRequest = nil
        if let first = targets.first { focusScrolled(first, proxy: proxy) }
    }

    private func hide(_ section: OverviewSection) {
        hiddenRaw = OverviewSection.encode(hidden.union([section]))
    }

    private func binding(_ section: OverviewSection) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(section) },
            set: { visible in
                var set = hidden
                if visible { set.remove(section) } else { set.insert(section) }
                hiddenRaw = OverviewSection.encode(set)
            }
        )
    }

    private func subtitle(_ connections: [Connection]) -> String {
        let accounts = model.snapshot.accounts.count
        let banks = connections.count == 1 ? String(localized: "1 Bank") : String(localized: "\(connections.count) Banken")
        let accountsText = accounts == 1 ? String(localized: "1 Konto") : String(localized: "\(accounts) Konten")
        return "\(banks) · \(accountsText)"
    }
}

// MARK: - Sections and boxes

/// The parts of the overview the user can hide ("Anpassen" in the toolbar, or a box's context menu).
enum OverviewSection: String, CaseIterable, Identifiable {
    case balance, figures, flows, spending, accounts, latest

    static let storageKey = "overviewHiddenSections"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balance: String(localized: "Gesamtsaldo")
        case .figures: String(localized: "Kennzahlen")
        case .flows: String(localized: "Einnahmen und Ausgaben")
        case .spending: String(localized: "Ausgaben nach Bereich")
        case .accounts: String(localized: "Banken und Konten")
        case .latest: String(localized: "Neueste Umsätze")
        }
    }

    var symbol: String {
        switch self {
        case .balance: "chart.line.uptrend.xyaxis"
        case .figures: "square.grid.2x2"
        case .flows: "chart.bar"
        case .spending: "chart.bar.doc.horizontal"
        case .accounts: "building.columns"
        case .latest: "list.bullet"
        }
    }

    static func decode(_ raw: String) -> Set<OverviewSection> {
        Set(raw.split(separator: ",").compactMap { OverviewSection(rawValue: String($0)) })
    }

    static func encode(_ sections: Set<OverviewSection>) -> String {
        sections.map(\.rawValue).sorted().joined(separator: ",")
    }
}

/// A flat box for one area of the dashboard: control background, rounded corners, a hairline
/// border, no shadow. Agreed exception to "keine Karten" for the overview only (CLAUDE.md §6).
private struct DashboardBox<Accessory: View, Content: View>: View {
    let title: String?
    let symbol: String?
    let subtitle: LocalizedStringKey?
    let section: OverviewSection?
    let hide: ((OverviewSection) -> Void)?
    let accessory: Accessory
    let content: Content

    init(_ section: OverviewSection, subtitle: LocalizedStringKey? = nil, hide: @escaping (OverviewSection) -> Void,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        title = section == .balance ? nil : section.title
        symbol = section.symbol
        self.subtitle = subtitle
        self.section = section
        self.hide = hide
        self.accessory = accessory()
        self.content = content()
    }

    /// Box without a section of its own (a bank, a figure tile).
    init(title: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        symbol = nil
        subtitle = nil
        section = nil
        hide = nil
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DashboardBoxBackground())
        .contextMenu {
            if let section, let hide {
                Button("„\(section.title)“ ausblenden") { hide(section) }
            }
        }
    }
}

struct DashboardBoxBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

// MARK: - Data

/// Everything the charts show, summed over the visible accounts from the per-revision
/// `SnapshotIndex` (accounts × 12 months, never the whole ledger). Chart values are euros as
/// `Double` for plotting only; sums stay in cents.
private struct OverviewData {
    struct BalancePoint: Identifiable {
        let month: Date
        let cents: Int
        var id: Date { month }
    }

    struct MonthFlow: Identifiable {
        let month: Date
        let income: Int
        let spending: Int
        var id: Date { month }
    }

    struct GroupSpending: Identifiable {
        let title: String
        let symbol: String
        let cents: Int
        var id: String { title }
    }

    let totalCents: Int
    /// Change of the counted balances since the start of this month (booked, without depots).
    let monthChangeCents: Int
    let balance: [BalancePoint]
    let flows: [MonthFlow]
    let spending: [GroupSpending]
    let latest: [MFNCore.Transaction]
    let thisMonth: MonthFlow?

    static let flowMonths = 6
    static let spendingGroups = 6

    @MainActor
    init(model: AppModel, connections: [Connection]) {
        let accounts = connections.flatMap { model.orderedAccounts(of: $0.id) }
        let visible = Set(accounts.map(\.id))
        let counted = accounts.filter { model.isCountedInTotals($0.id) && model.snapshot.balances[$0.id]?.currency == "EUR" }
        let count = SnapshotIndex.overviewMonths
        let starts = Self.monthStarts(count: count)

        // Balance at the end of each month: today's balance walked back by the booked amounts.
        // Depots move with prices, not bookings: they stay flat at today's value.
        var nets = Array(repeating: 0, count: count)
        var current = 0
        for account in counted {
            current += model.snapshot.balances[account.id]?.bookedCents ?? 0
            guard account.type != .depot else { continue }
            for (slot, flow) in model.overviewMonths(of: account.id).enumerated() { nets[slot] += flow.bookedNet }
        }
        totalCents = model.totalBalanceCents
        monthChangeCents = nets[count - 1]
        var points: [BalancePoint] = []
        var running = current
        for slot in stride(from: count - 1, through: 0, by: -1) {
            points.insert(BalancePoint(month: starts[slot], cents: running), at: 0)
            running -= nets[slot]
        }
        balance = points

        var income = Array(repeating: 0, count: count)
        var spent = Array(repeating: 0, count: count)
        var groups: [CategoryInfo.Group?: Int] = [:]
        // Same scope as the balance: accounts counted in totals.
        for account in counted {
            for (slot, flow) in model.overviewMonths(of: account.id).enumerated() {
                income[slot] += flow.income
                spent[slot] += flow.spending
            }
            for (group, cents) in model.overviewSpending(of: account.id) { groups[group, default: 0] += cents }
        }
        flows = (count - Self.flowMonths..<count).map { MonthFlow(month: starts[$0], income: income[$0], spending: spent[$0]) }
        thisMonth = flows.last

        let sorted = groups.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        var top = sorted.prefix(Self.spendingGroups - 1).map { entry in
            GroupSpending(title: entry.key?.localizedTitle ?? String(localized: "Ohne Kategorie"), symbol: entry.key.map(Self.symbol) ?? "questionmark.circle", cents: entry.value)
        }
        let rest = sorted.dropFirst(Self.spendingGroups - 1).reduce(0) { $0 + $1.value }
        if rest > 0 { top.append(GroupSpending(title: String(localized: "Übrige"), symbol: "ellipsis.circle", cents: rest)) }
        spending = top

        latest = Array(model.latestOverall.filter { visible.contains($0.accountID) }.prefix(8))
    }

    private static func monthStarts(count: Int) -> [Date] {
        let today = BankDay.today
        return (0..<count).map { slot in
            let back = count - 1 - slot
            let index = today.year * 12 + (today.month - 1) - back
            return BankDay(year: index / 12, month: index % 12 + 1, day: 1)?.startDate ?? today.startDate
        }
    }

    static func symbol(_ group: CategoryInfo.Group) -> String {
        switch group {
        case .einnahmen: "arrow.down.circle"
        case .wohnen: "house"
        case .lebenshaltung: "cart"
        case .mobilitaet: "car"
        case .freizeit: "theatermasks"
        case .einkaufen: "bag"
        case .gesundheit: "cross.case"
        case .familie: "figure.2.and.child.holdinghands"
        case .finanzen: "building.columns"
        case .sonstiges: "square.grid.2x2"
        }
    }
}

/// Compact euro labels for chart axes ("12 Tsd. €").
private enum ChartFormat {
    static let locale = Locale.autoupdatingCurrent

    static func axis(_ euros: Double) -> String {
        Int(euros.rounded()).formatted(.number.notation(.compactName).locale(locale)) + " €"
    }

    static let monthShort = Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).month(.abbreviated)
    static let monthLong = Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).month(.wide).year()
}

private struct OverviewSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero

/// The total balance as the headline, next to its course over twelve months.
private struct OverviewHero: View {
    let data: OverviewData
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gesamtsaldo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                AmountText(cents: data.totalCents, colorsInflow: false)
                    .font(.system(.largeTitle, design: .default).weight(.semibold))
                    .accessibilityLabel(model.hideAmounts ? String(localized: "Gesamtsaldo, Betrag ausgeblendet") : String(localized: "Gesamtsaldo \(Money.format(data.totalCents))"))
                HStack(spacing: 4) {
                    // The direction alone would tell what hidden amounts hide.
                    if !model.hideAmounts {
                        Image(systemName: data.monthChangeCents >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .accessibilityHidden(true)
                    }
                    // A balance change, not income: no green (CLAUDE.md §6).
                    AmountText(cents: data.monthChangeCents, colorsInflow: false, signed: true)
                    Text("seit Monatsanfang")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                if let last = model.lastCompleteSync {
                    Text("Abgeglichen \(DayFormat.syncTime(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            BalanceChart(points: data.balance)
                .frame(minWidth: 240, maxWidth: .infinity)
                .frame(height: 130)
        }
    }
}

private struct BalanceChart: View {
    let points: [OverviewData.BalancePoint]
    @Environment(AppModel.self) private var model
    @State private var selected: Date?

    private var selectedPoint: OverviewData.BalancePoint? {
        guard let selected else { return nil }
        return points.min { abs($0.month.timeIntervalSince(selected)) < abs($1.month.timeIntervalSince(selected)) }
    }

    var body: some View {
        if model.hideAmounts {
            HiddenChart(title: String(localized: "Saldo der letzten 12 Monate"))
        } else {
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Monat", point.month, unit: .month), y: .value("Saldo", Double(point.cents) / 100))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Monat", point.month, unit: .month), y: .value("Saldo", Double(point.cents) / 100))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(Color.primary.opacity(0.7))
                }
                if let point = selectedPoint {
                    RuleMark(x: .value("Monat", point.month, unit: .month))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(title: Self.pointTitle(point, last: point.id == points.last?.id), lines: [(String(localized: "Saldo"), point.cents)])
                        }
                    PointMark(x: .value("Monat", point.month, unit: .month), y: .value("Saldo", Double(point.cents) / 100))
                        .symbolSize(60)
                        .foregroundStyle(Color.primary)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 3)) { _ in
                    AxisValueLabel(format: ChartFormat.monthShort)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel { if let euros = value.as(Double.self) { Text(ChartFormat.axis(euros)) } }
                }
            }
            .chartXSelection(value: $selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Saldo der letzten 12 Monate")
            .accessibilityValue(summary)
        }
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "" }
        return String(localized: "von \(Money.format(first.cents)) Ende \(first.month.formatted(ChartFormat.monthLong)) auf \(Money.format(last.cents)) heute")
    }

    /// Each point is the balance at the end of its month (plotted at the month's start); the last is today.
    private static func pointTitle(_ point: OverviewData.BalancePoint, last: Bool) -> String {
        last ? String(localized: "Heute") : String(localized: "Ende \(point.month.formatted(ChartFormat.monthLong))")
    }
}

/// Charts hide with the amounts (⇧⌘H): their shape alone would tell too much.
private struct HiddenChart: View {
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title2)
            Text("Beträge ausgeblendet")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): Beträge ausgeblendet")
    }
}

private struct ChartTooltip: View {
    let title: String
    let lines: [(String, Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            ForEach(lines, id: \.0) { line in
                HStack(spacing: 8) {
                    Text(line.0)
                    Spacer(minLength: 4)
                    Text(Money.format(line.1)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Key figures

/// Four figures in one row, separated by dividers: income and spending of this month, pending,
/// review. Income is green (the only place for green, CLAUDE.md §6), the review count accent.
private struct KeyFigures: View {
    let data: OverviewData
    let columns: AdaptiveColumns
    let focus: FocusState<OverviewFocus?>.Binding
    let hide: (OverviewSection) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        columns {
            tile(String(localized: "Einnahmen im \(monthName)"), symbol: "arrow.down.left") {
                AmountText(cents: data.thisMonth?.income ?? 0)
            }
            tile(String(localized: "Ausgaben im \(monthName)"), symbol: "arrow.up.right") {
                AmountText(cents: -(data.thisMonth?.spending ?? 0), colorsInflow: false)
            }
            tile(model.pendingCount == 1 ? String(localized: "1 vorgemerkter Umsatz") : String(localized: "\(model.pendingCount) vorgemerkte Umsätze"), symbol: "clock", opens: true) {
                AmountText(cents: model.pendingTotalCents, colorsInflow: false)
            }
            .overviewTarget(.pending, focus: focus, cornerRadius: 12, highlight: false) { model.selection = .pending }
            .help("Vorgemerkte anzeigen (⌘2)")
            tile(String(localized: "Zu prüfen"), symbol: "checklist", opens: true) {
                Text(model.reviewCount == 0 ? String(localized: "Nichts") : "\(model.reviewCount)")
                    .monospacedDigit()
                    .foregroundStyle(model.reviewCount == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            }
            .overviewTarget(.review, focus: focus, cornerRadius: 12, highlight: false) { model.selection = .review }
            .help("Zu prüfen anzeigen (⌘1)")
            // Only with self-planned payments: opens the forecast of the next one's account.
            let planned = model.plannedOverview
            if let next = planned.next, let account = model.account(next.accountID) {
                // Short enough for one line: a wrapped title made this tile taller than the others.
                tile(planned.count == 1 ? String(localized: "1 geplante Buchung") : String(localized: "\(planned.count) geplante Buchungen"), symbol: "calendar.badge.plus", opens: true) {
                    // One line like the other tiles (same height); the next one is in the tooltip.
                    AmountText(cents: planned.cents, colorsInflow: false)
                }
                .overviewTarget(.planned, focus: focus, cornerRadius: 12, highlight: false) { model.showForecast(for: account) }
                .accessibilityHint("Nächste: \(next.title) am \(ForecastFormat.text(max(next.day, model.index.day), today: model.index.day)). Öffnet die Prognose von \(account.name).")
                .help("Selbst geplant. Nächste: \(next.title) am \(ForecastFormat.text(max(next.day, model.index.day), today: model.index.day)). Öffnet die Prognose von \(account.name).")
            }
        }
        .contextMenu {
            Button("„\(OverviewSection.figures.title)“ ausblenden") { hide(.figures) }
        }
    }

    private var monthName: String {
        Date().formatted(Date.FormatStyle(locale: ChartFormat.locale, timeZone: BankDay.bankTimeZone).month(.wide))
    }

    private func tile<Value: View>(_ title: String, symbol: String, opens: Bool = false, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            value()
                .font(.title2.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardBoxBackground())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Charts

/// Income and spending of the last six months, side by side.
private struct FlowChart: View {
    let months: [OverviewData.MonthFlow]
    @Environment(AppModel.self) private var model
    @State private var selected: Date?

    private var selectedMonth: OverviewData.MonthFlow? {
        guard let selected else { return nil }
        return months.min { abs($0.month.timeIntervalSince(selected)) < abs($1.month.timeIntervalSince(selected)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hideAmounts {
                HiddenChart(title: String(localized: "Einnahmen und Ausgaben")).frame(height: 200)
            } else {
                Chart {
                    ForEach(months) { month in
                        BarMark(x: .value("Monat", month.month, unit: .month), y: .value("Betrag", Double(month.income) / 100))
                            .position(by: .value("Art", String(localized: "Einnahmen")))
                            .foregroundStyle(by: .value("Art", String(localized: "Einnahmen")))
                            .cornerRadius(4)
                        BarMark(x: .value("Monat", month.month, unit: .month), y: .value("Betrag", Double(month.spending) / 100))
                            .position(by: .value("Art", String(localized: "Ausgaben")))
                            .foregroundStyle(by: .value("Art", String(localized: "Ausgaben")))
                            .cornerRadius(4)
                    }
                    if let month = selectedMonth {
                        RuleMark(x: .value("Monat", month.month, unit: .month))
                            .foregroundStyle(Color.secondary.opacity(0.15))
                            .lineStyle(StrokeStyle(lineWidth: 28))
                            .zIndex(-1)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                ChartTooltip(title: month.month.formatted(ChartFormat.monthLong),
                                             lines: [(String(localized: "Einnahmen"), month.income), (String(localized: "Ausgaben"), -month.spending), (String(localized: "Saldo"), month.income - month.spending)])
                            }
                    }
                }
                .chartForegroundStyleScale([String(localized: "Einnahmen"): Color.green, String(localized: "Ausgaben"): Color.secondary.opacity(0.8)])
                .chartLegend(position: .top, alignment: .leading)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: ChartFormat.monthShort, centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel { if let euros = value.as(Double.self) { Text(ChartFormat.axis(euros)) } }
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 200)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Einnahmen und Ausgaben der letzten 6 Monate")
                .accessibilityValue(months.map { String(localized: "\($0.month.formatted(ChartFormat.monthLong)): Einnahmen \(Money.format($0.income)), Ausgaben \(Money.format($0.spending))") }.joined(separator: "; "))
            }
        }
    }
}

/// This month's spending by category group: the biggest first, the rest as "Übrige".
private struct SpendingChart: View {
    let groups: [OverviewData.GroupSpending]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hideAmounts {
                HiddenChart(title: String(localized: "Ausgaben nach Bereich")).frame(height: 200)
            } else if groups.isEmpty {
                Text("Noch keine Ausgaben in diesem Monat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                let largest = max(groups.map(\.cents).max() ?? 1, 1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        SpendingBar(group: group, share: Double(group.cents) / Double(largest))
                    }
                }
                .frame(minHeight: 200, alignment: .top)
            }
        }
    }
}

/// One group: symbol, name, a bar relative to the biggest group, the amount as text.
private struct SpendingBar: View {
    let group: OverviewData.GroupSpending
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(group.title)
                Spacer(minLength: 8)
                Text(Money.format(group.cents))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: max(proxy.size.width * share, 4))
                    }
            }
            .frame(height: 6)
            .padding(.leading, 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.title)
        .accessibilityValue(Money.format(group.cents))
    }
}

// MARK: - Bank

/// One bank: header with state, sum and sync button, then one line per account.
private struct BankOverviewSection: View {
    let connection: Connection
    let focus: FocusState<OverviewFocus?>.Binding
    let hide: (OverviewSection) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.orderedAccounts(of: connection.id)
        VStack(alignment: .leading, spacing: 6) {
            BankOverviewHeader(connection: connection, state: model.syncState(connection.id), focus: focus)
                .padding(.bottom, 4)
            Divider()
            if accounts.isEmpty {
                Text("Keine sichtbaren Konten")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            } else {
                ForEach(accounts) { account in
                    AccountOverviewRow(account: account, focus: focus)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DashboardBoxBackground())
        .contextMenu {
            Button("„\(OverviewSection.accounts.title)“ ausblenden") { hide(.accounts) }
        }
    }
}

private struct BankOverviewHeader: View {
    let connection: Connection
    let state: SyncState
    let focus: FocusState<OverviewFocus?>.Binding

    /// The sync button is enabled (and can take the focus).
    static func canSync(_ state: SyncState) -> Bool {
        switch state.phase {
        case .syncing, .waitingForApproval: false
        case .idle, .failed, .storeFailed: true
        }
    }
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.showBankIcons) private var showIcons = true

    private var isBusy: Bool {
        switch state.phase {
        case .syncing, .waitingForApproval: true
        case .idle, .failed, .storeFailed: false
        }
    }

    /// An open decoupled/push approval waits in the bank's app (see the sidebar's approval hint).
    private var hasOpenApproval: Bool {
        guard let request = model.presenter.request(for: connection.id) else { return false }
        switch request.challenge {
        case .decoupled, .pushConfirm: return true
        case .code, .webLogin, .choice, .imageCode, .secret: return false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showIcons {
                BankBadge(connection: connection, size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            AmountText(cents: model.totalBalanceCents(of: connection.id), colorsInflow: false)
                .font(.headline)
                .accessibilityLabel(model.hideAmounts ? String(localized: "Summe \(connection.displayName), Betrag ausgeblendet") : String(localized: "Summe \(connection.displayName): \(Money.format(model.totalBalanceCents(of: connection.id)))"))
            action
        }
        // The state changes on its own: VoiceOver hears problems without looking for them.
        .onChange(of: state.phase) { _, phase in
            if let text = Self.announcement(phase, bank: connection.displayName) {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    private static func announcement(_ phase: SyncState.Phase, bank: String) -> String? {
        switch phase {
        case .waitingForApproval: String(localized: "\(bank): Anmeldung nötig")
        case let .failed(error): String(localized: "\(bank): Fehler – \(error.description)")
        case .storeFailed: String(localized: "\(bank): Speichern fehlgeschlagen")
        case .idle, .syncing: nil
        }
    }

    @ViewBuilder
    private var action: some View {
        if connection.isManual {
            // v10: nothing to sync.
            EmptyView()
        } else if case .waitingForApproval = state.phase, !hasOpenApproval {
            Button("Jetzt anmelden") { model.syncConnection(connection.id) }
                .controlSize(.small)
                .disabled(model.lock.isLocked)
        } else {
            Button {
                model.syncConnection(connection.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .focusable()
            .focused(focus, equals: .sync(connection.id))
            .onKeyPress(.return) {
                model.syncConnection(connection.id)
                return .handled
            }
            .id(OverviewFocus.sync(connection.id))
            .disabled(isBusy || model.lock.isLocked)
            .help("\(connection.displayName) abgleichen")
            .accessibilityLabel("\(connection.displayName) abgleichen")
        }
    }

    /// Same states and symbols as the sidebar header, here with the text spelled out.
    @ViewBuilder
    private var status: some View {
        switch state.phase {
        case .syncing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Abgleich läuft")
            }
            .accessibilityElement(children: .combine)
        case .waitingForApproval:
            Label {
                Text(hasOpenApproval ? String(localized: "Anmeldung nötig – bitte in der \(connection.displayName)-App freigeben") : String(localized: "Anmeldung nötig"))
            } icon: {
                Image(systemName: "person.badge.key").foregroundStyle(.orange)
            }
        case let .failed(error):
            Label {
                Text("Fehler: \(error.description)")
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .help("Fehler: \(error.description)")
        case let .storeFailed(message):
            Label {
                Text("Speichern fehlgeschlagen: \(message)")
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
            }
            .help("Speichern fehlgeschlagen: \(message)")
        case .idle:
            if connection.isManual {
                Label("ohne Anbindung", systemImage: "tray.and.arrow.down")
            } else if let last = state.lastSuccess {
                Label("abgeglichen \(DayFormat.syncTime(last))", systemImage: "clock")
                    .monospacedDigit()
            } else {
                Label("Noch nicht abgeglichen", systemImage: "clock")
            }
        }
    }
}

// MARK: - Account

/// One account in one line; the whole line opens the account.
private struct AccountOverviewRow: View {
    let account: Account
    let focus: FocusState<OverviewFocus?>.Binding
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            let newCount = model.newCount(of: account.id)
            if newCount > 0 {
                NewCountBadge(count: newCount)
                    // Read with the row's label, not as a separate element.
                    .accessibilityHidden(true)
            }
            if let shortfall = model.shortfall(for: account.id) {
                Image(systemName: ShortfallFormat.symbol)
                    .foregroundStyle(.orange)
                    .help(ShortfallFormat.short(shortfall))
            }
            if let status = model.budgetStatus(for: account.id) {
                BudgetRing(status: status)
            }
            if let balance = model.snapshot.balances[account.id] {
                let counted = model.isCountedInTotals(account.id)
                HStack(spacing: 3) {
                    // Not colour alone (CLAUDE.md §6): a symbol marks accounts left out of the sums.
                    if !counted {
                        Image(systemName: "minus.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    AmountText(cents: balance.bookedCents, currency: balance.currency, colorsInflow: false)
                        .fontWeight(.medium)
                        .foregroundStyle(counted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .help("\(account.name) öffnen")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accountLabel)
        .accessibilityValue(balanceValue)
        .accessibilityHint("Konto öffnen")
        .overviewTarget(.account(account.id), focus: focus) { model.selection = .account(account.id) }
    }

    private var symbol: String {
        switch account.type {
        case .giro: "building.columns"
        case .tagesgeld: "banknote"
        case .depot: "chart.line.uptrend.xyaxis"
        case .card: "creditcard"
        }
    }

    /// Type, card digits.
    private var detail: String {
        var parts = [account.type.title]
        if let last4 = account.cardLast4 { parts.append("·· \(last4)") }
        return parts.joined(separator: " · ")
    }

    private var accountLabel: String {
        var parts = [account.name, detail]
        let newCount = model.newCount(of: account.id)
        if newCount > 0 { parts.append(NewCountBadge.text(newCount)) }
        if !model.isCountedInTotals(account.id) { parts.append(String(localized: "nicht in der Summe")) }
        if let shortfall = model.shortfall(for: account.id) { parts.append(ShortfallFormat.short(shortfall)) }
        if let status = model.budgetStatus(for: account.id) {
            parts.append(String(localized: "Budget \(Int((status.spentFraction * 100).rounded())) Prozent ausgegeben, \(BudgetRing.stateWord(status))"))
        }
        return parts.joined(separator: ", ")
    }

    private var balanceValue: String {
        guard let balance = model.snapshot.balances[account.id] else { return String(localized: "kein Saldo") }
        return model.hideAmounts ? String(localized: "Betrag ausgeblendet") : Money.format(balance.bookedCents, currency: balance.currency)
    }
}

// MARK: - Latest

/// The newest transactions of all accounts, with the account they belong to.
private struct LatestSection: View {
    let transactions: [MFNCore.Transaction]
    let focus: FocusState<OverviewFocus?>.Binding
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if transactions.isEmpty {
                Text("Noch keine Umsätze.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            } else {
                ForEach(transactions) { transaction in
                    OverviewTransactionLine(transaction: transaction, accountName: model.account(transaction.accountID)?.name)
                        .overviewTarget(.transaction(transaction.id), focus: focus) { model.reveal(transaction) }
                }
            }
        }
    }
}

/// One transaction: date, counterpart with its account, amount. Pending is italic with a dashed
/// chip, like the list.
private struct OverviewTransactionLine: View {
    let transaction: MFNCore.Transaction
    let accountName: String?
    @Environment(AppModel.self) private var model

    private var isPending: Bool { transaction.status == .pending }

    var body: some View {
        HStack(spacing: 10) {
            MonogramAvatar(name: transaction.counterpartName, status: transaction.status, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(transaction.counterpartName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isPending {
                        HintChip(text: "Vorgemerkt", dashed: true)
                            .italic(false)
                    }
                    if model.isNew(transaction.id) {
                        AccentBadge(text: "Neu")
                            .italic(false)
                    }
                }
                Text([Self.date(transaction.effectiveDate), accountName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(transaction.purpose)
            Spacer(minLength: 8)
            AmountText(cents: transaction.amountCents, currency: transaction.currency, signed: true)
        }
        .italic(isPending)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(model.hideAmounts ? String(localized: "Betrag ausgeblendet") : Money.format(transaction.amountCents, currency: transaction.currency, signed: true))
        .accessibilityHint("Im Konto anzeigen")
    }

    private var label: String {
        var parts = [transaction.counterpartName]
        if isPending { parts.append(String(localized: "vorgemerkt")) }
        if model.isNew(transaction.id) { parts.append(String(localized: "neu")) }
        parts.append(Self.date(transaction.effectiveDate))
        if let accountName { parts.append(accountName) }
        // The purpose is otherwise only in the tooltip.
        let purpose = transaction.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if !purpose.isEmpty { parts.append(String(purpose.prefix(120))) }
        return parts.joined(separator: ", ")
    }

    private static let dayMonth = Date.FormatStyle(locale: Locale.autoupdatingCurrent, timeZone: BankDay.bankTimeZone).day().month(.abbreviated)
    private static let dayMonthYear = dayMonth.year(.twoDigits)

    /// "3. Nov." this year, "3. Nov. 25" otherwise.
    private static func date(_ day: BankDay) -> String {
        day.startDate.formatted(day.year == BankDay.today.year ? dayMonth : dayMonthYear)
    }
}

/// What can have the keyboard focus in the overview.
enum OverviewFocus: Hashable {
    case pending, review, planned
    case sync(ConnectionID)
    case account(AccountID)
    case allTransactions
    case transaction(TransactionID)
}

/// Hover background and keyboard focus ring of a focusable element. Placed inside it (before
/// `.focusable()`), so `isFocused` is its own and only this leaf redraws when the focus moves.
struct FocusHighlight: View {
    var cornerRadius: CGFloat
    /// Rows get a quiet background on hover and focus; tiles and the chart only the ring.
    var fill = true
    var hovering = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        ZStack {
            if fill, focused || hovering {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            }
            if focused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Click and keyboard target in the overview: focusable (also without "Tastaturnavigation" in
/// System Settings), Return or Space opens it, a quiet highlight on hover and focus (like a Finder
/// row) plus the system focus ring colour, no border or shadow otherwise.
private struct OverviewTarget: ViewModifier {
    let id: OverviewFocus
    let focus: FocusState<OverviewFocus?>.Binding
    var cornerRadius: CGFloat = 5
    /// Rows get a background on hover/focus; tiles have their own and only get the ring.
    var highlight = true
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, highlight ? 6 : 0)
            .padding(.vertical, highlight ? 3 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background { FocusHighlight(cornerRadius: cornerRadius, fill: highlight, hovering: hovering) }
            .onHover { hovering = $0 }
            // A click opens without leaving a focus ring behind (the ring is for the keyboard).
            .onTapGesture {
                focus.wrappedValue = nil
                action()
            }
            .focusable()
            .focused(focus, equals: id)
            .focusEffectDisabled()
            .onKeyPress(keys: [.return, .space]) { _ in
                action()
                return .handled
            }
            .id(id)
            // One element with one action: the row's own label, the button trait, no second path.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    fileprivate func overviewTarget(_ id: OverviewFocus, focus: FocusState<OverviewFocus?>.Binding, cornerRadius: CGFloat = 5,
                                    highlight: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(OverviewTarget(id: id, focus: focus, cornerRadius: cornerRadius, highlight: highlight, action: action))
    }
}

// MARK: - Account header

/// Small balance graph of one account for the list header: the last 31 days (solid) and the
/// forecast from pending and planned bookings (dotted), both from `SnapshotIndex.BalanceCurve`
/// (built once per snapshot, the same payments as the shortfall warning). A zero line and an
/// orange mark at the lowest point show when the money would not last. Lower than the header's
/// text block. Hidden with the amounts (⇧⌘H). Click, Return or Space open the forecast panel
/// (`ForecastSheet`); the tooltip has the exact values.
struct AccountBalanceChart: View {
    let account: AccountID
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private func open() {
        if let account = model.account(account) { model.showForecast(for: account) }
    }

    var body: some View {
        if !model.hideAmounts, let curve = model.balanceCurve(of: account) {
            let all = curve.past + curve.forecast
            let minimum = all.map(\.cents).min() ?? 0
            let summary = Self.summary(curve)
            VStack(alignment: .leading, spacing: 3) {
                Chart {
                    ForEach(all) { point in
                        LineMark(x: .value("Tag", point.day.startDate), y: .value("Saldo", Double(point.cents) / 100),
                                 series: .value("Art", point.isForecast ? "Prognose" : "Saldo"))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Color.primary.opacity(point.isForecast ? 0.5 : 0.75))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round,
                                                   dash: point.isForecast ? [2, 3] : []))
                    }
                    if minimum < 0 {
                        RuleMark(y: .value("Null", 0))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 0.5))
                    }
                    RuleMark(x: .value("Heute", model.index.day.startDate))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                    if let low = curve.lowest {
                        PointMark(x: .value("Tag", low.day.startDate), y: .value("Saldo", Double(low.cents) / 100))
                            .symbolSize(24)
                            .foregroundStyle(.orange)
                    }
                }
                .chartLegend(.hidden)
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 200, height: 36)
                // Legend as text: solid and dotted are told apart by shape, not colour. Its own
                // width, so larger text is not cut off.
                HStack(spacing: 8) {
                    LegendLine(dashed: false, text: "Saldo")
                    LegendLine(dashed: true, text: "Prognose")
                    Text("bis \(curve.end.startDate.formatted(Self.dayFormat))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .padding(4)
            .background {
                FocusHighlight(cornerRadius: 6, fill: false)
            }
            .contentShape(Rectangle())
            .help(summary + "\n" + String(localized: "Klicken öffnet die Prognose (⌥⌘P)."))
            .onTapGesture {
                focused = false   // the ring is for the keyboard
                open()
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.return, .space]) { _ in
                open()
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Saldoverlauf der letzten 31 Tage mit Prognose")
            .accessibilityValue(summary)
            .accessibilityHint("Öffnet die Prognose")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityChartDescriptor(BalanceChartDescriptor(curve: curve))
        }
    }

    private struct LegendLine: View {
        let dashed: Bool
        let text: LocalizedStringKey

        var body: some View {
            HStack(spacing: 3) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 10, y: 1))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [2, 3] : []))
                .frame(width: 10, height: 2)
                Text(text)
            }
        }
    }

    static let dayFormat = Date.FormatStyle(locale: Locale.autoupdatingCurrent, timeZone: BankDay.bankTimeZone).day().month(.abbreviated)

    private static func summary(_ curve: SnapshotIndex.BalanceCurve) -> String {
        var lines: [String] = []
        if let first = curve.past.first { lines.append(String(localized: "Vor 30 Tagen: \(Money.format(first.cents))")) }
        lines.append(String(localized: "Heute gebucht: \(Money.format(curve.todayCents))"))
        lines.append(String(localized: "Prognose \(curve.end.startDate.formatted(dayFormat)): \(Money.format(curve.endCents)) (mit vorgemerkten, geplanten und regelmäßigen Buchungen)"))
        if let low = curve.lowest {
            lines.append(String(localized: "Tiefster Stand: \(Money.format(low.cents)) am \(low.day.startDate.formatted(dayFormat))"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Audio graph and data table for VoiceOver (Rotor → "Diagramm"): balance and forecast per day.
private struct BalanceChartDescriptor: AXChartDescriptorRepresentable {
    let curve: SnapshotIndex.BalanceCurve

    func makeChartDescriptor() -> AXChartDescriptor {
        let all = curve.past + curve.forecast
        // Categories must be unique: forecast days are marked, repeated days numbered.
        var seen: [String: Int] = [:]
        func label(_ point: SnapshotIndex.BalanceCurve.Point) -> String {
            let dayText = point.day.startDate.formatted(AccountBalanceChart.dayFormat)
            let base = point.isForecast ? String(localized: "\(dayText) (Prognose)") : dayText
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base) \(count + 1)"
        }
        let labelled = all.map { (label($0), $0) }
        let values = all.map { Double($0.cents) / 100 }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: String(localized: "Tag"), categoryOrder: labelled.map(\.0))
        let yAxis = AXNumericDataAxisDescriptor(title: String(localized: "Saldo"), range: low...max(high, low + 1), gridlinePositions: []) {
            Money.format(Int(($0 * 100).rounded()))
        }
        let past = AXDataSeriesDescriptor(name: String(localized: "Saldo"), isContinuous: true, dataPoints: labelled.filter { !$0.1.isForecast }.map {
            AXDataPoint(x: $0.0, y: Double($0.1.cents) / 100)
        })
        let forecast = AXDataSeriesDescriptor(name: String(localized: "Prognose"), isContinuous: true, dataPoints: labelled.filter { $0.1.isForecast }.map {
            AXDataPoint(x: $0.0, y: Double($0.1.cents) / 100)
        })
        return AXChartDescriptor(title: String(localized: "Saldoverlauf"), summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [past, forecast])
    }
}

// MARK: - Layout

/// Like `LazyVGrid` with one `.adaptive(minimum:)` column, but eager: as many columns of at least
/// `minimum` as fit, rows as high as their highest cell, cells top-leading.
struct AdaptiveColumns: Layout {
    let minimum: CGFloat
    let spacing: CGFloat

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimum + spacing)))
        return (count, max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count)))
    }

    private func rowHeights(_ subviews: Subviews, count: Int, cellWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: count).map { start in
            subviews[start..<min(start + count, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimum * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        let (count, cellWidth) = columns(for: width)
        let heights = rowHeights(subviews, count: count, cellWidth: cellWidth)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, cellWidth) = columns(for: bounds.width)
        let heights = rowHeights(subviews, count: count, cellWidth: cellWidth)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<count {
                let index = row * count + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (cellWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: cellWidth, height: nil))
            }
            y += height + spacing
        }
    }
}
