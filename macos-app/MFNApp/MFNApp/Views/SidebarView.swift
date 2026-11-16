import MFNCore
import SwiftUI

/// What the sidebar can select: one of the overview lists or a single account.
enum SidebarItem: Hashable {
    /// Dashboard: all banks with their accounts and latest transactions (`OverviewView`).
    case overview
    case allAccounts
    case review
    case pending
    case account(AccountID)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Bank currently dragged by its header (live reordering in `BankDropDelegate`).
    @State private var draggingBank: ConnectionID?
    @State private var editingCredentials: Connection?
    @State private var removing: Connection?
    @State private var renaming: RenameTarget?
    /// ⌘ held: banks and accounts can be dragged. Otherwise rows are not draggable at all, so a
    /// click never enters the table's drag tracking (which, together with the rows' tap gesture,
    /// could swallow the mouse-up and hang the app until the next mouse event).
    @State private var reordering = false
    @State private var flagsMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Preferences.showTreeLines) private var showTreeLines = true
    @FocusState private var listFocused: Bool

    var body: some View {
        // No `List(selection:)`: the system highlight is the full accent colour, which the sidebar
        // does not let us tone down. Rows select on click (`selectable`), arrow keys move the
        // selection (`onKeyPress`), the selected row gets a quiet background.
        List {
            Section {
                SidebarRow(title: "Übersicht", symbol: "square.grid.2x2") {
                    EmptyView()
                }
                .selectable(.overview)
                SidebarRow(title: "Alle Konten", symbol: "building.columns") {
                    AmountText(cents: model.totalBalanceCents, colorsInflow: false)
                }
                .selectable(.allAccounts)
                SidebarRow(title: "Zu prüfen", symbol: "checklist") {
                    if model.reviewCount > 0 {
                        AccentBadge(text: "\(model.reviewCount)")
                    }
                }
                .selectable(.review)
                SidebarRow(title: "Vorgemerkt", symbol: "clock") {
                    AmountText(cents: model.pendingTotalCents, colorsInflow: false)
                }
                .selectable(.pending)
            }

            let connections = model.orderedConnections
            // Separates the global lists above from the banks.
            if !connections.isEmpty {
                Section {} header: {
                    HStack {
                        Text("Banken")
                        Spacer()
                        ReorderInfoButton()
                            .padding(.trailing, SidebarMetrics.scrollerClearance)
                    }
                }
            }
            ForEach(connections) { connection in
                let state = model.snapshot.syncStates[connection.id] ?? SyncState()
                let accounts = model.orderedAccounts(of: connection.id)
                // Collapsing hides the rows directly (no `Section(isExpanded:)`: its own hover
                // disclosure arrow would compete with the header's chevron and sync button).
                Section {
                    ForEach(model.isCollapsed(connection.id) ? [] : accounts) { account in
                        AccountRow(
                            account: account,
                            isSelected: model.selection == .account(account.id),
                            isFirst: account.id == accounts.first?.id,
                            isLast: account.id == accounts.last?.id,
                            path: TreeBranch.Highlight(row: account.id, in: accounts, selection: model.selection)
                        )
                            .selectable(.account(account.id), emphasis: showTreeLines ? .bold : .none)
                            .accessibilityAction(named: "Konto nach oben") { model.moveAccount(account, by: -1) }
                            .accessibilityAction(named: "Konto nach unten") { model.moveAccount(account, by: 1) }
                            .pointerStyle(reordering ? .grabIdle : nil)
                            .contextMenu {
                                Button("Nach oben") { model.moveAccount(account, by: -1) }
                                    .disabled(accounts.first?.id == account.id)
                                Button("Nach unten") { model.moveAccount(account, by: 1) }
                                    .disabled(accounts.last?.id == account.id)
                                Divider()
                                Button("Umbenennen …") { renaming = .account(account) }
                                if connection.isManual {
                                    Button("Konto bearbeiten …") { model.showManualAccountEditor(for: account) }
                                        .disabled(!model.canAddBank || model.bankSetup != nil)
                                }
                                Button(model.budget(for: account.id) == nil ? "Budget festlegen …" : "Budget ändern …") { model.showBudgetEditor(for: account) }
                                if account.type != .depot {
                                    Button("Umsätze aus CSV importieren …") { model.beginCSVImport(for: account.id) }
                                        .disabled(!model.canImportCSV)
                                    Button("Umsätze als CSV exportieren …") { model.exportCSV(account: account.id) }
                                        .disabled(model.lock.isLocked)
                                    let imported = model.importedCount(of: account.id)
                                    Button(imported > 0 ? "Importierte Umsätze entfernen (\(imported)) …" : "Importierte Umsätze entfernen …") {
                                        model.requestRemoveImports(of: account.id)
                                    }
                                    .disabled(imported == 0 || model.lock.isLocked)
                                }
                                Toggle("In Summe einrechnen", isOn: Binding(
                                    get: { model.isCountedInTotals(account.id) },
                                    set: { model.setCountedInTotals($0, account: account.id) }
                                ))
                                Button("Konto ausblenden") { model.setHidden(true, account: account.id) }
                            }
                    }
                    // Drag and drop of accounts within their bank.
                    .onMove(perform: reordering ? { model.moveAccounts(of: connection.id, fromOffsets: $0, toOffset: $1) } : nil)
                    if case .waitingForApproval = state.phase {
                        ApprovalCard(connection: connection)
                            .selectionDisabled()
                    }
                } header: {
                    // Click on the bank (not on its sync button) collapses / expands its accounts.
                    ConnectionHeader(connection: connection, state: state, toggle: { toggleCollapsed(connection.id) },
                                     move: { moveConnection(connection.id, by: $0) })
                        .pointerStyle(reordering ? .grabIdle : nil)
                        // Drag a bank by its header: banks reorder live while dragging, like
                        // accounts (move operation, so no "+" copy cursor).
                        .modifier(BankDragSource(enabled: reordering) {
                            draggingBank = connection.id
                            return NSItemProvider(object: BankDrag.payload(connection.id) as NSString)
                        })
                        .onDrop(of: [.text], delegate: BankDropDelegate(target: connection.id, dragging: $draggingBank, model: model, animated: !reduceMotion))
                        .contextMenu {
                            Button("Bank nach oben") { moveConnection(connection.id, by: -1) }
                                .disabled(connections.first?.id == connection.id)
                            Button("Bank nach unten") { moveConnection(connection.id, by: 1) }
                                .disabled(connections.last?.id == connection.id)
                            Divider()
                            if connection.connectorID.hasConnector {
                                Button("\(connection.displayName) abgleichen") { model.syncConnection(connection.id) }
                                    .disabled(model.lock.isLocked)
                            }
                            AccountVisibilityMenu(connection: connection.id)
                            AccountTotalsMenu(connection: connection.id)
                            Button("Umbenennen …") { renaming = .bank(connection) }
                            // Developer mode: what merging a web connection into this FinTS one would do.
                            if DeveloperMode.isAvailable, BankAccess.of(connection).isFinTS {
                                let sources = connections.filter { $0.connectorID == connection.connectorID && !BankAccess.of($0).isFinTS }
                                if !sources.isEmpty {
                                    Menu("Zusammenführen prüfen") {
                                        ForEach(sources) { source in
                                            Button("„\(source.displayName)“ (Web-Banking) …") {
                                                model.mergeCheck = MergeRequest(source: source, target: connection)
                                            }
                                        }
                                    }
                                }
                            }
                            if !model.isDemo {
                                Divider()
                                if connection.isManual {
                                    Button("Konto entfernen …", role: .destructive) { removing = connection }
                                } else {
                                    Button("Zugangsdaten ändern …") { editingCredentials = connection }
                                    Button("Bank entfernen …", role: .destructive) { removing = connection }
                                }
                            }
                        }
                }
            }
        }
        .environment(\.amountArea, .sidebar)
        .listStyle(.sidebar)
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.home) { moveSelection(to: 0) }
        .onKeyPress(.end) { moveSelection(to: .max) }
        // Like Finder: ← collapses the bank of the selected account, → expands it again; on an
        // expanded bank → (and Return) hands the focus to the content.
        .onKeyPress(.leftArrow) {
            guard let bank = selectedBank, !model.isCollapsed(bank) else { return .ignored }
            toggleCollapsed(bank)
            return .handled
        }
        .onKeyPress(keys: [.rightArrow, .return]) { press in
            if press.key == .rightArrow, let bank = selectedBank, model.isCollapsed(bank) {
                toggleCollapsed(bank)
                return .handled
            }
            guard model.selection != nil else { return .ignored }
            model.focusRequest = .content
            return .handled
        }
        .onChange(of: model.focusRequest) { _, request in
            guard request == .sidebar else { return }
            model.focusRequest = nil
            listFocused = true
        }
        .defaultFocus($listFocused, true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.showBankSetup()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAddBank)
                .help(model.isDemo ? "In der Demo nicht verfügbar" : "Bank hinzufügen (⇧⌘N)")
                .accessibilityLabel("Bank hinzufügen")
                if reordering {
                    Text("Ziehen zum Verschieben")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let last = model.lastCompleteSync {
                    Text("Letzter vollständiger Abgleich: \(DayFormat.syncTime(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Accounts scroll underneath: system bar material (blur) and a hairline on top, like
            // the bottom bars of Finder and Mail.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .bankActions(editing: $editingCredentials, removing: $removing)
        .renameSheet($renaming)
        .sheet(item: Binding(get: { model.mergeCheck }, set: { model.mergeCheck = $0 })) { MergeReportSheet(request: $0) }
        .onAppear {
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let held = event.modifierFlags.contains(.command)
                if held != reordering { reordering = held }
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
            reordering = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in reordering = false }
    }

    private func toggleCollapsed(_ id: ConnectionID) {
        if reduceMotion {
            model.toggleCollapsed(id)
        } else {
            withAnimation(.snappy) { model.toggleCollapsed(id) }
        }
    }

    private func moveConnection(_ id: ConnectionID, by offset: Int) {
        if reduceMotion {
            model.moveConnection(id, by: offset)
        } else {
            withAnimation { model.moveConnection(id, by: offset) }
        }
    }
}

/// Info symbol next to "Banken": hovering (or clicking) shows how to reorder and collapse in a
/// popover; a tooltip would cut the text short.
private struct ReorderInfoButton: View {
    @State private var shown = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Banken und Konten sortieren, Symbole erklärt")
        .accessibilityHint("Halte die Befehlstaste gedrückt und ziehe eine Bank oder ein Konto. Alternativ: Aktionen „Bank nach oben“ und „nach unten“ im Kontextmenü oder in den Aktionen der Bank.")
        .onHover { inside in
            hoverTask?.cancel()
            guard inside else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { shown = true }
            }
        }
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            // Own text styles: the popover would otherwise inherit the sidebar header's (small, grey,
            // one line).
            VStack(alignment: .leading, spacing: 10) {
                Text("Reihenfolge ändern")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                InfoLine(symbol: "hand.draw", text: "⌘ gedrückt halten und eine Bank oder ein Konto ziehen.")
                InfoLine(symbol: "chevron.right", text: "Klick auf eine Bank klappt ihre Konten ein und aus, mit der Tastatur ← und → auf einem ihrer Konten.")
                InfoLine(symbol: "contextualmenu.and.cursorarrow", text: "Rechtsklick (ohne Maus: Kontextmenü oder VoiceOver-Aktionen): nach oben/unten, umbenennen, ausblenden, in Summe einrechnen.")
                Divider()
                    .padding(.vertical, 2)
                Text("Symbole")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                // Drawn like in the rows (same symbol, colour and pie), so they can be matched.
                InfoLine(text: "Budget: der gefüllte Teil ist ausgegeben.") {
                    ZStack {
                        Circle().fill(.quaternary)
                        PieSlice(fraction: 0.6).fill(Color.primary.opacity(0.65))
                        Circle().strokeBorder(.tertiary, lineWidth: 0.5)
                    }
                    .frame(width: 12, height: 12)
                }
                InfoLine(symbol: "exclamationmark.triangle", color: .orange, text: "Budget wird laut Prognose überschritten; gefüllt: schon überschritten.")
                InfoLine(symbol: ShortfallFormat.symbol, color: .orange, text: "Guthaben reicht nicht für vorgemerkte und geplante Zahlungen.")
                InfoLine(symbol: "minus.circle", text: "Konto zählt nicht zur Bank- und Gesamtsumme.")
                InfoLine(symbol: "arrow.clockwise", text: "Bank abgleichen (alle Banken: ⌘R).")
                InfoLine(symbol: "person.badge.key", color: .orange, text: "Anmeldung bei der Bank nötig.")
                InfoLine(symbol: "xmark.octagon.fill", color: .red, text: "Abgleich fehlgeschlagen; Details im Tooltip.")
                InfoLine(symbol: "externaldrive.badge.exclamationmark", color: .red, text: "Umsätze konnten nicht gespeichert werden.")
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(width: 300, alignment: .leading)
            .padding(14)
        }
    }
}

private struct InfoLine<Icon: View>: View {
    let text: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

extension InfoLine where Icon == InfoSymbol {
    init(symbol: String, color: Color? = nil, text: String) {
        self.init(text: text) { InfoSymbol(name: symbol, color: color) }
    }
}

/// SF Symbol of an `InfoLine`: in its sidebar colour, else secondary.
private struct InfoSymbol: View {
    let name: String
    let color: Color?

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    }
}

/// Bank header as drag source only while ⌘ is held (see `SidebarView.reordering`).
private struct BankDragSource: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag(provider)
        } else {
            content
        }
    }
}

extension SidebarView {
    /// Overview lists, then the visible accounts of expanded banks, in sidebar order.
    private var selectableItems: [SidebarItem] {
        allItems.filter(\.visible).map(\.item)
    }

    /// Every item in sidebar order, also the accounts of collapsed banks (the selection can stay on
    /// one after ← collapsed its bank; the arrows continue from its place).
    private var allItems: [(item: SidebarItem, visible: Bool)] {
        var items: [(item: SidebarItem, visible: Bool)] = [(.overview, true), (.allAccounts, true), (.review, true), (.pending, true)]
        for connection in model.orderedConnections {
            let visible = !model.isCollapsed(connection.id)
            items += model.orderedAccounts(of: connection.id).map { (.account($0.id), visible) }
        }
        return items
    }

    /// Bank of the selected account, if an account is selected.
    private var selectedBank: ConnectionID? {
        guard case let .account(id)? = model.selection else { return nil }
        return model.account(id)?.connectionID
    }

    private func moveSelection(to index: Int) -> KeyPress.Result {
        let items = selectableItems
        guard !items.isEmpty else { return .ignored }
        model.selection = items[min(max(index, 0), items.count - 1)]
        return .handled
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        // Selected account in a collapsed bank: step from its place to the next visible item.
        let all = allItems
        if let selection = model.selection, let position = all.firstIndex(where: { $0.item == selection }), !all[position].visible {
            let step = offset > 0 ? 1 : -1
            var index = position + step
            while all.indices.contains(index), !all[index].visible { index += step }
            if all.indices.contains(index) { model.selection = all[index].item }
            return .handled
        }
        let items = selectableItems
        guard !items.isEmpty else { return .ignored }
        let current = model.selection.flatMap { items.firstIndex(of: $0) } ?? (offset > 0 ? -1 : items.count)
        let next = min(max(current + offset, 0), items.count - 1)
        model.selection = items[next]
        return .handled
    }
}

/// How a selected sidebar row stands out.
enum SidebarEmphasis {
    /// Grey rounded background plus bold text, like the sidebars of Music and Finder.
    case background
    /// Bold text (accounts with tree lines, where the highlighted line also marks the selection).
    case bold
    /// The row draws its own background and weight (accounts without tree lines, because of the
    /// gap above the first account).
    case none
}

/// Quiet selection background, slightly larger than the row's content.
struct SidebarSelectionBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            .padding(.horizontal, -6)
            .padding(.vertical, -5)
            .accessibilityHidden(true)
    }
}

/// Click selection without the accent-coloured system highlight. Rows are one step smaller than
/// the system sidebar font.
private struct SelectableRow: ViewModifier {
    let item: SidebarItem
    let emphasis: SidebarEmphasis
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let selected = model.selection == item
        content
            .font(.callout)
            .fontWeight(selected && emphasis != .none ? .semibold : .regular)
            .background {
                if selected && emphasis == .background { SidebarSelectionBackground() }
            }
            .contentShape(Rectangle())
            // Simultaneous: a plain tap gesture delays the List's own drag (reordering accounts).
            .simultaneousGesture(TapGesture().onEnded { model.selection = item })
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { model.selection = item }
    }
}

extension View {
    fileprivate func selectable(_ item: SidebarItem, emphasis: SidebarEmphasis = .background) -> some View {
        modifier(SelectableRow(item: item, emphasis: emphasis))
    }
}

/// Drag payload for reordering banks. A prefixed string, so text dragged in from elsewhere is ignored.
private enum BankDrag {
    static let prefix = "mfn-bank:"

    static func payload(_ id: ConnectionID) -> String { prefix + id.rawValue }
}

/// Drop target on a bank header. Moves the dragged bank as soon as it enters the target (live
/// reordering with animation, like `List.onMove` for accounts) and proposes `.move`, so macOS shows
/// the move cursor instead of the "+" copy cursor.
private struct BankDropDelegate: DropDelegate {
    let target: ConnectionID
    @Binding var dragging: ConnectionID?
    let model: AppModel
    var animated = true

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        if animated {
            withAnimation(.snappy) { model.moveConnection(dragging.rawValue, onto: target) }
        } else {
            model.moveConnection(dragging.rawValue, onto: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct SidebarRow<Trailing: View>: View {
    let title: String
    /// SF Symbol in the system accent colour, like the sidebars of Music and Finder.
    let symbol: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .fontWeight(.regular)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectionHeader: View {
    let connection: Connection
    let state: SyncState
    /// Collapse / expand. Only the part left of the sync button reacts, so a sync click leaves the
    /// bank open. Simultaneous, so the click does not hold back the drag that reorders banks.
    let toggle: () -> Void
    /// Reorder by VoiceOver action (−1 up, +1 down).
    let move: (Int) -> Void
    @Environment(AppModel.self) private var model

    /// Bank icon size; account rows indent by it so their names line up with the bank name.
    static let badgeSize: CGFloat = 18
    static let spacing: CGFloat = 6
    @AppStorage(Preferences.showBankIcons) private var showIcons = true

    private var isBusy: Bool {
        switch state.phase {
        case .syncing, .waitingForApproval: true
        case .idle, .failed, .storeFailed: false
        }
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                if showIcons {
                    BankBadge(connection: connection, size: Self.badgeSize)
                }
                Text(connection.displayName.uppercased())
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(model.isCollapsed(connection.id) ? 0 : 90))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                status
                    .font(.caption)
                    .textCase(nil)
                AmountText(cents: model.totalBalanceCents(of: connection.id), colorsInflow: false, muted: true)
                    .textCase(nil)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(toggle))
            // One VoiceOver element (bank, status, total) that collapses; the sync button is its own.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityAction(named: "Bank nach oben") { move(-1) }
            .accessibilityAction(named: "Bank nach unten") { move(1) }
            .accessibilityHint(model.isCollapsed(connection.id) ? "Konten einblenden" : "Konten ausblenden")
            if connection.connectorID.hasConnector {
                Button {
                    model.syncConnection(connection.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(isBusy || model.lock.isLocked)
                .help("\(connection.displayName) abgleichen")
                .accessibilityLabel("\(connection.displayName) abgleichen")
                .padding(.leading, 4)
                .padding(.trailing, SidebarMetrics.scrollerClearance)
            } else {
                // Same width as the sync button, so the totals of all banks line up.
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .hidden()
                    .accessibilityHidden(true)
                    .padding(.leading, 4)
                    .padding(.trailing, SidebarMetrics.scrollerClearance)
            }
        }
        .help(syncHelp)
        // The state is only an icon here: VoiceOver hears when a bank fails or needs a login.
        .onChange(of: state.phase) { old, new in
            guard let message = Self.announcement(for: new, bank: connection.displayName), old != new else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    static func announcement(for phase: SyncState.Phase, bank: String) -> String? {
        switch phase {
        case let .failed(error): "\(bank): Abgleich fehlgeschlagen. \(error.description)"
        case .waitingForApproval: "\(bank): Anmeldung nötig"
        case .storeFailed: "\(bank): Speichern fehlgeschlagen"
        case .idle, .syncing: nil
        }
    }

    private var syncHelp: String {
        if connection.isManual { return "Ohne Anbindung: Umsätze per CSV-Import" }
        guard let last = state.lastSuccess else { return "Noch nicht abgeglichen" }
        return "Zuletzt abgeglichen: \(DayFormat.syncTime(last))"
    }

    @ViewBuilder
    private var status: some View {
        switch state.phase {
        // The header shows the bank total; the state is an icon (with text in the tooltip and for
        // VoiceOver), the last sync time is in the tooltip.
        case .syncing:
            ProgressView().controlSize(.mini)
                .help("Abgleich läuft")
                .accessibilityLabel("Abgleich läuft")
        case .waitingForApproval:
            Image(systemName: "person.badge.key")
                .foregroundStyle(.orange)
                .help("Anmeldung nötig – „Jetzt anmelden“ oder abgleichen")
                .accessibilityLabel("Anmeldung nötig")
        case let .failed(error):
            // Not the triangle: that marks an exceeded budget (shape, not only colour).
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help("Fehler: \(error.description)")
                .accessibilityLabel("Fehler: \(error.description)")
        case let .storeFailed(message):
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.red)
                .help("Speichern fehlgeschlagen: \(message)")
                .accessibilityLabel("Speichern fehlgeschlagen")
        case .idle:
            EmptyView()
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let isSelected: Bool
    var isFirst = false
    var isLast = false
    var path: TreeBranch.Highlight = .none
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.showBankIcons) private var showIcons = true
    @AppStorage(Preferences.showTreeLines) private var showLines = true

    /// Geometry, measured in the sidebar (2026-11-10): header icon starts at x = 12 pt, row text
    /// at 14.5 pt, so row-relative x = screen x − 14.5.
    private static let headerOrigin: CGFloat = 12
    private static let rowOrigin: CGFloat = 14.5

    /// Extra space between the bank header and its first account.
    static let firstRowGap: CGFloat = 5

    /// With lines: names start where the bank name starts (or a fixed step without icons).
    /// Without lines: no indent at all.
    private var indent: CGFloat {
        guard showLines else { return 0 }
        return showIcons ? ConnectionHeader.badgeSize + ConnectionHeader.spacing + Self.headerOrigin - Self.rowOrigin : 16
    }

    /// The line runs down from the middle of the bank icon (or the start of the bank name).
    private var lineX: CGFloat {
        (showIcons ? Self.headerOrigin + ConnectionHeader.badgeSize / 2 : Self.headerOrigin + 3) - Self.rowOrigin
    }


    var body: some View {
        HStack {
            Text(account.name)
                .lineLimit(1)
                // Slightly lighter unless selected: the selected account stands out, the rest stays readable.
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.75)))
                // Explicit in both cases: `Text.fontWeight(nil)` removes the weight instead of
                // inheriting the row's bold.
                .fontWeight(isSelected ? .semibold : .regular)
                .help(account.cardLast4.map { "\(account.name) ·· \($0)" } ?? account.name)
                // The shortfall warning belongs to the account, not to a separate symbol element.
                .accessibilityLabel(model.shortfall(for: account.id).map { "\(account.name), Warnung: \(ShortfallFormat.short($0))" } ?? account.name)
            Spacer(minLength: 8)
            if let shortfall = model.shortfall(for: account.id) {
                Image(systemName: ShortfallFormat.symbol)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(ShortfallFormat.short(shortfall))
                    // Read with the account name (see above), not as a separate element.
                    .accessibilityHidden(true)
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
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Nicht in der Summe")
                    }
                    AmountText(cents: balance.bookedCents, currency: balance.currency, colorsInflow: false)
                        .foregroundStyle(counted ? (isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)) : AnyShapeStyle(.tertiary))
                }
                .help(counted ? "" : "Nicht in der Bank- und Gesamtsumme")
            }
        }
        .padding(.leading, indent)
        // Without lines the selection is a background (before the top gap, so it hugs the text).
        .background {
            if isSelected && !showLines { SidebarSelectionBackground() }
        }
        .padding(.top, isFirst ? Self.firstRowGap : 0)
        .background(alignment: .leading) {
            if showLines {
                let branch = TreeBranch(x: lineX, endX: indent - 5, isLast: isLast, topInset: isFirst ? Self.firstRowGap : 0)
                let style = StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round)
                ZStack {
                    branch.stroke(.quaternary, style: style)
                    // Path from the bank to the selected account, a step stronger than the rest.
                    if path != .none {
                        branch.part(path).stroke(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }
}

/// Git-graph-like line from the bank to an account: vertical through the row (stopping at the
/// middle with a rounded bend for the last account) plus a branch to the name. Drawn beyond the
/// row's top and bottom so consecutive rows join up (views do not clip since macOS 14).
private struct TreeBranch: Shape {
    /// Which part of a row's line belongs to the path from the bank to the selected account.
    enum Highlight: Equatable {
        case none
        /// The selected account is further down: the vertical line passes through.
        case through
        /// This row is selected: line from the top down to the row and its branch.
        case target

        init(row: AccountID, in accounts: [Account], selection: SidebarItem?) {
            guard case let .account(selected)? = selection,
                  let target = accounts.firstIndex(where: { $0.id == selected }),
                  let index = accounts.firstIndex(where: { $0.id == row }) else { self = .none; return }
            self = index < target ? .through : index == target ? .target : .none
        }
    }

    let x: CGFloat
    let endX: CGFloat
    let isLast: Bool
    /// Extra space above the text (first row); the middle is the text's middle.
    var topInset: CGFloat = 0
    /// Half the gap between row contents (row pitch ≈ 32 pt, text ≈ 16 pt).
    var overreach: CGFloat = 9
    var radius: CGFloat = 4
    var segments: Set<Segment> = [.top, .bottom, .branch]

    enum Segment { case top, bottom, branch }

    func part(_ highlight: Highlight) -> TreeBranch {
        var copy = self
        copy.segments = switch highlight {
        case .none: []
        case .through: [.top, .bottom]
        case .target: [.top, .branch]
        }
        return copy
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY - overreach
        let mid = rect.minY + topInset + (rect.height - topInset) / 2
        let bend = isLast ? mid - radius : mid
        if segments.contains(.top) {
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: bend))
        }
        if segments.contains(.bottom), !isLast {
            path.move(to: CGPoint(x: x, y: mid))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + overreach))
        }
        if segments.contains(.branch) {
            path.move(to: CGPoint(x: x, y: bend))
            if isLast {
                path.addQuadCurve(to: CGPoint(x: x + radius, y: mid), control: CGPoint(x: x, y: mid))
            }
            path.addLine(to: CGPoint(x: max(endX, x + radius), y: mid))
        }
        return path
    }
}

/// Inline hint while a bank waits for approval in its app.
private struct ApprovalCard: View {
    let connection: Connection
    @Environment(AppModel.self) private var model

    /// Only decoupled/push approvals can be confirmed from here; codes need the sheet.
    private var hasOpenRequest: Bool {
        guard let request = model.presenter.request(for: connection.id) else { return false }
        switch request.challenge {
        case .decoupled, .pushConfirm: return true
        case .code, .webLogin: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasOpenRequest
                 ? "Bitte in der \(connection.displayName)-App freigeben, dann weiter abgleichen."
                 : "Anmeldung nötig. Der automatische Abgleich meldet sich nicht selbst an und wartet auf dich.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(hasOpenRequest ? "Freigegeben – weiter" : "Jetzt anmelden") {
                    if hasOpenRequest {
                        if let request = model.presenter.request(for: connection.id) { model.presenter.respond(to: request.id, .confirmed) }
                    } else {
                        model.syncConnection(connection.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                if hasOpenRequest {
                    Button("Später") { model.presenter.cancel(connection: connection.id) }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .padding(.vertical, 4)
    }
}

enum SidebarMetrics {
    /// Trailing space of header buttons, so the overlay scroller (about 11 pt plus inset) does not
    /// cover them.
    static let scrollerClearance: CGFloat = 16
}
