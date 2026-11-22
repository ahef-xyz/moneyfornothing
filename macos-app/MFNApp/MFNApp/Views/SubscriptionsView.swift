import MFNCore
import SwiftUI

/// What can be done with a row of the list (context menu, keyboard, VoiceOver actions).
private enum RowAction {
    case edit, showTransactions, hide, unhide, delete, reset
}

/// "Fixkosten": what books at a fixed rhythm, with what it costs per month and year.
struct SubscriptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsHidden = false
    @State private var filter = RecurringFilter()
    /// What is typed; `filter.text` follows after a pause, so the list is not refiltered per key.
    @State private var searchText = ""
    @State private var draft: RecurringDraft?
    @State private var actionError: String?
    /// ID of the selected payment: what Return, ⌫ and the context menu act on.
    @State private var selection: String?
    @State private var pendingDelete: RecurringPayment?
    @State private var memo = OverviewMemo()
    @FocusState private var searchFocused: Bool
    /// From this width of the detail area on, expenses and income get a column each. Grows with
    /// the text size: the sums above the columns need the room.
    @ScaledMetric(relativeTo: .title2) private var splitWidth: CGFloat = 760

    private static let searchDebounce = Duration.milliseconds(200)

    var body: some View {
        let payments = model.recurringPayments
        let overview = memo.overview(payments ?? [], filter: filter, hidden: model.hiddenRecurring, isHidden: model.isRecurringHidden)
        Group {
            if let payments {
                if payments.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine regelmäßigen Zahlungen", systemImage: "repeat")
                    } description: {
                        Text("MFN erkennt Abos, Miete, Versicherungen und Gehalt, sobald sie dreimal im gleichen Abstand gebucht wurden (jährliche nach zwei Buchungen). Du kannst auch eigene Einträge anlegen.")
                    } actions: {
                        Button("Eigenen Eintrag anlegen …") { addOwn() }
                            .disabled(defaultAccount == nil)
                    }
                } else {
                    content(overview, accounts: memo.accounts(payments, model: model))
                }
            } else {
                // The first detection of this unlock is still running.
                ProgressView("Regelmäßige Zahlungen werden gesucht …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Off the main actor; a newer publish cancels the wait of an older one.
        .task(id: model.snapshotRevision) { await model.refreshRecurringDetection() }
        .navigationTitle("Fixkosten")
        .navigationSubtitle(payments == nil ? "" : subtitle(overview))
        // The search field is in the header, not `.searchable`: the lists of the accounts put theirs
        // into the toolbar, and going from this view to one of them with the arrow keys made AppKit
        // insert the toolbar's search item twice (NSInternalInconsistencyException, crash).
        // Typing waits for a pause; clearing applies at once.
        .task(id: searchText) {
            guard searchText != filter.text else { return }
            if !searchText.isEmpty {
                try? await Task.sleep(for: Self.searchDebounce)
                guard !Task.isCancelled else { return }
            }
            filter.text = searchText
        }
        .onChange(of: filter.text) { _, text in
            if text != searchText { searchText = text }
        }
        // ⌘F ("Umsätze durchsuchen" in the menu) searches this list while it is shown.
        .onAppear { takeSearchFocus() }
        .onChange(of: model.searchFocusRequested) { takeSearchFocus() }
        .sheet(item: $draft) { RecurringEntryEditor(draft: $0) }
        .confirmationDialog("Diesen Eintrag löschen?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { payment in
            Button("Löschen", role: .destructive) {
                if let id = payment.entryID { remove(id) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { payment in
            Text("„\(payment.title)“ ist dein eigener Eintrag. Er lässt sich nicht wiederherstellen.")
        }
        .alert("Das hat nicht geklappt", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func content(_ overview: RecurringOverview, accounts: [Account]) -> some View {
        GeometryReader { proxy in
            // Side by side when there is room and both sides have entries; else one list.
            let split = proxy.size.width >= splitWidth && filter.kind == .all
                && overview.hasBothSides(showingHidden: showsHidden)
            VStack(spacing: 0) {
                // Stays in place: only the lists below scroll.
                SubscriptionHeader(overview: overview, filter: $filter, showsHidden: $showsHidden,
                                   searchText: $searchText, searchFocused: $searchFocused,
                                   accounts: accounts, split: split,
                                   add: defaultAccount == nil ? nil : { addOwn() })
                if split {
                    HStack(spacing: 0) {
                        list(overview, income: false)
                        Divider()
                        list(overview, income: true)
                    }
                } else {
                    list(overview, income: nil)
                }
            }
        }
        .overlay {
            if overview.isEmpty(showingHidden: showsHidden) {
                ContentUnavailableView {
                    Label("Keine Treffer", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text(filter.isActive ? "Zu diesem Filter gibt es keine regelmäßige Zahlung." : "Alle Einträge sind ausgeblendet.")
                } actions: {
                    if filter.isActive {
                        Button("Filter zurücksetzen") { filter = RecurringFilter() }
                    } else {
                        Button("Ausgeblendete zeigen") { showsHidden = true }
                    }
                }
                .padding(.top, 120)
            }
        }
    }

    private func takeSearchFocus() {
        guard model.searchFocusRequested else { return }
        // The field may not be in the window yet when the request comes with the view.
        Task { @MainActor in
            searchFocused = true
            model.searchFocusRequested = false
        }
    }

    /// Account a new own entry starts with: the filtered one, else the first in the sidebar.
    private var defaultAccount: AccountID? {
        if let chosen = filter.account, model.account(chosen) != nil { return chosen }
        return model.orderedConnections.lazy.flatMap { model.orderedAccounts(of: $0.id) }.first?.id
    }

    private func addOwn() {
        draft = RecurringDraft(account: defaultAccount, isExpense: filter.kind != .income)
    }

    /// One list. `income`: only that side (two columns); `nil`: everything, expenses first.
    private func list(_ overview: RecurringOverview, income: Bool?) -> some View {
        func side(_ payments: [RecurringPayment]) -> [RecurringPayment] {
            income.map { wanted in payments.filter { $0.isIncome == wanted } } ?? payments
        }
        return List(selection: $selection) {
            if income != true { section("Ausgaben", overview.expenses) }
            if income != false { section("Einnahmen", overview.income) }
            section("Beendet", side(overview.ended), footer: "Die nächste Zahlung ist ausgeblieben. Kommt keine mehr, verschwindet der Eintrag von selbst.")
            if showsHidden {
                section("Ausgeblendet", side(overview.hidden), hidden: true,
                        footer: "Zählen nicht in die Summen. Mit der Rückschritttaste oder über das Kontextmenü blendest du einen gewählten Eintrag wieder ein.")
            }
        }
        .listStyle(.inset)
        .accessibilityLabel(income == true ? "Einnahmen" : income == false ? "Ausgaben" : "Fixkosten")
        // Everything the context menu offers is reachable from the keyboard: arrows select,
        // Return (or a double click) edits, ⌫ hides or deletes, the menu key opens the menu.
        .contextMenu(forSelectionType: String.self) { ids in
            if let found = ids.first.flatMap({ find($0, in: overview) }) {
                RowActionButtons(payment: found.payment, isHidden: found.hidden) { perform($0, on: found.payment) }
            }
        } primaryAction: { ids in
            if let found = ids.first.flatMap({ find($0, in: overview) }) { perform(.edit, on: found.payment) }
        }
        .onKeyPress(.return) {
            guard let found = selection.flatMap({ find($0, in: overview) }) else { return .ignored }
            perform(.edit, on: found.payment)
            return .handled
        }
        .onDeleteCommand {
            guard let found = selection.flatMap({ find($0, in: overview) }) else { return }
            perform(found.hidden ? .unhide : found.payment.isOwn ? .delete : .hide, on: found.payment)
        }
    }

    private func find(_ id: String, in overview: RecurringOverview) -> (payment: RecurringPayment, hidden: Bool)? {
        if let payment = (overview.expenses + overview.income + overview.ended).first(where: { $0.id == id }) { return (payment, false) }
        return overview.hidden.first { $0.id == id }.map { ($0, true) }
    }

    private func perform(_ action: RowAction, on payment: RecurringPayment) {
        switch action {
        case .edit:
            draft = RecurringDraft(payment, stored: model.snapshot.recurringEntries.first { $0.id == payment.entryID })
        case .showTransactions: model.showTransactions(of: payment)
        case .hide: model.setRecurringHidden(true, payment)
        case .unhide: model.setRecurringHidden(false, payment)
        case .delete: pendingDelete = payment
        case .reset:
            if let id = payment.entryID { remove(id) }
        }
    }

    private func remove(_ id: UUID) {
        Task { actionError = await model.removeRecurringEntry(id) }
    }

    @ViewBuilder
    private func section(_ title: String, _ payments: [RecurringPayment], hidden: Bool = false, footer: String? = nil) -> some View {
        if !payments.isEmpty {
            Section {
                ForEach(payments) { payment in
                    SubscriptionRow(payment: payment, isHidden: hidden) { perform($0, on: payment) }
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func subtitle(_ overview: RecurringOverview) -> String {
        let count = overview.expenses.count + overview.income.count
        let text = count == 1 ? "1 regelmäßige Zahlung" : "\(count) regelmäßige Zahlungen"
        return filter.isActive ? text + " (gefiltert)" : text
    }
}

/// The split list and the accounts of the filter menu, kept between renders: the body runs on
/// every change of the model it reads, the list only changes with these inputs.
@MainActor
private final class OverviewMemo {
    private var overviewKey: (payments: [RecurringPayment], filter: RecurringFilter, hidden: Set<String>)?
    private var overviewValue = RecurringOverview([], isHidden: { _ in false })
    private var accountsKey: (payments: [RecurringPayment], revision: Int)?
    private var accountsValue: [Account] = []

    func overview(_ payments: [RecurringPayment], filter: RecurringFilter, hidden: Set<String>, isHidden: (RecurringPayment) -> Bool) -> RecurringOverview {
        if let key = overviewKey, key.filter == filter, key.hidden == hidden, key.payments == payments { return overviewValue }
        overviewValue = RecurringOverview(payments, filter: filter, isHidden: isHidden)
        overviewKey = (payments, filter, hidden)
        return overviewValue
    }

    /// Accounts that have a recurring payment, in sidebar order.
    func accounts(_ payments: [RecurringPayment], model: AppModel) -> [Account] {
        if let key = accountsKey, key.revision == model.snapshotRevision, key.payments == payments { return accountsValue }
        let used = Set(payments.map(\.accountID))
        accountsValue = model.orderedConnections.flatMap { model.orderedAccounts(of: $0.id) }.filter { used.contains($0.id) }
        accountsKey = (payments, model.snapshotRevision)
        return accountsValue
    }
}

/// Sums and filter above the list.
private struct SubscriptionHeader: View {
    let overview: RecurringOverview
    @Binding var filter: RecurringFilter
    @Binding var showsHidden: Bool
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let accounts: [Account]
    /// Two columns below: each side's sums stand above its column.
    let split: Bool
    /// "Eigener Eintrag"; `nil` without an account to put it on.
    let add: (() -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if split {
                HStack(alignment: .top, spacing: 0) {
                    expenseFigures.frame(maxWidth: .infinity, alignment: .leading)
                    incomeFigures.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // In one row where they fit, expenses above income otherwise (narrow window, large text).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        if filter.kind != .income { expenseFigures }
                        if filter.kind != .expenses { incomeFigures }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if filter.kind != .income { expenseFigures }
                        if filter.kind != .expenses { incomeFigures }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Filters and buttons in one row where they fit, in two otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filters
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { filters }
                    HStack(spacing: 12) { buttons }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var filters: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Fixkosten durchsuchen", text: $searchText)
                .textFieldStyle(.plain)
                .focused(searchFocused)
                .onExitCommand { searchText = "" }
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minWidth: 140, idealWidth: 200, maxWidth: 240)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        Picker("Art", selection: $filter.kind) {
            ForEach(RecurringFilter.Kind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Picker("Rhythmus", selection: $filter.cadence) {
            Text("Jeder Rhythmus").tag(RecurringPayment.Cadence?.none)
            Divider()
            ForEach(RecurringPayment.Cadence.allCases, id: \.self) { Text($0.title).tag(RecurringPayment.Cadence?.some($0)) }
        }
        .labelsHidden()
        .fixedSize()
        if accounts.count > 1 {
            Picker("Konto", selection: $filter.account) {
                Text("Alle Konten").tag(AccountID?.none)
                Divider()
                ForEach(accounts) { Text(model.displayName(of: $0)).tag(AccountID?.some($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
        }
        if filter.isActive {
            Button("Zurücksetzen") { filter = RecurringFilter() }
                .buttonStyle(.link)
                .accessibilityLabel("Filter zurücksetzen")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if let add {
            Button(action: add) { Label("Eigener Eintrag", systemImage: "plus") }
                .help("Eine regelmäßige Ausgabe oder Einnahme anlegen, die MFN nicht erkannt hat")
        }
        if !overview.hidden.isEmpty {
            Toggle(isOn: $showsHidden) {
                Label("Ausgeblendete (\(overview.hidden.count))", systemImage: showsHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(showsHidden ? "Ausgeblendete Einträge verbergen" : "Ausgeblendete Einträge am Ende der Liste zeigen")
            // The toggle's own value says whether they are shown.
            .accessibilityLabel("Ausgeblendete Einträge, \(overview.hidden.count)")
        }
    }

    private var expenseFigures: some View {
        HStack(alignment: .top, spacing: 28) {
            figure("Ausgaben pro Monat", cents: -overview.expensesPerMonth)
            figure("Ausgaben pro Jahr", cents: -overview.expensesPerYear)
        }
    }

    private var incomeFigures: some View {
        HStack(alignment: .top, spacing: 28) {
            figure("Einnahmen pro Monat", cents: overview.incomePerMonth)
            figure("Einnahmen pro Jahr", cents: overview.incomePerYear)
        }
    }

    private func figure(_ title: String, cents: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            AmountText(cents: cents, signed: cents > 0)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The actions of a row as buttons: the same set in the context menu and for VoiceOver.
private struct RowActionButtons: View {
    let payment: RecurringPayment
    let isHidden: Bool
    let perform: (RowAction) -> Void

    var body: some View {
        Button("Bearbeiten …") { perform(.edit) }
        if payment.isOwn {
            Button("Eintrag löschen …", role: .destructive) { perform(.delete) }
        } else {
            if payment.isEdited {
                Button("Auf erkannte Werte zurücksetzen") { perform(.reset) }
            }
            Divider()
            Button("Umsätze zeigen") { perform(.showTransactions) }
            if isHidden {
                Button("Wieder einblenden") { perform(.unhide) }
            } else {
                Button("Ausblenden (keine regelmäßige Zahlung)") { perform(.hide) }
            }
        }
    }
}

private struct SubscriptionRow: View {
    let payment: RecurringPayment
    let isHidden: Bool
    let perform: (RowAction) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            // Only the picture is dimmed for ended and hidden rows: the text keeps its contrast,
            // and a chip says what the row is.
            MonogramAvatar(name: payment.title, status: payment.isEnded ? .cancelled : .booked)
                .opacity(payment.isEnded || isHidden ? 0.5 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(payment.title)
                        .lineLimit(1)
                        .help(payment.title)
                    if let change = payment.priceChange {
                        HintChip(text: model.hideAmounts ? "Preis geändert" : "Preis geändert, vorher \(Money.format(abs(change.previousCents)))")
                    }
                    if payment.isEnded {
                        HintChip(text: "Ausgeblieben", dashed: true)
                    }
                    if isHidden {
                        HintChip(text: "Ausgeblendet", dashed: true)
                    }
                    if payment.isOwn {
                        HintChip(text: "Eigener Eintrag")
                    } else if payment.isEdited {
                        HintChip(text: "Angepasst")
                            .help(detectedText ?? "")
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(cents: payment.cents, signed: true)
                    .monospacedDigit()
                Text(otherRhythmText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions { RowActionButtons(payment: payment, isHidden: isHidden, perform: perform) }
    }

    private var accountName: String {
        model.account(payment.accountID)?.name ?? "Konto"
    }

    /// A monthly payment per year, a yearly one per month.
    private var otherRhythmText: String {
        let (cents, unit) = payment.cadence != .yearly ? (payment.yearlyCents, "pro Jahr") : (payment.monthlyCents, "pro Monat")
        return model.hideAmounts ? "••••• \(unit)" : "\(Money.format(abs(cents))) \(unit)"
    }

    private var detail: String {
        let when = payment.isEnded
            ? "zuletzt am \(DayFormat.short(payment.last))"
            : "nächste um den \(DayFormat.short(payment.next))"
        return "\(payment.cadence.title) · \(accountName) · \(when)"
    }

    /// What MFN read from the bookings, for a payment the user changed.
    private var detectedText: String? {
        guard let detected = payment.detected else { return nil }
        let amount = model.hideAmounts ? "Betrag ausgeblendet" : Money.format(detected.cents, signed: true)
        return "Erkannt: \(detected.title), \(amount), \(detected.cadence.title.lowercased())"
    }

    /// Everything the row shows, in words: also what only a chip, the sign or the place in the
    /// list says to the eye.
    private var accessibilityText: String {
        var parts = [payment.title, payment.isIncome ? "Einnahme" : "Ausgabe", payment.cadence.title, accountName]
        if model.hideAmounts {
            parts.append("Betrag ausgeblendet")
        } else {
            parts.append(Money.format(payment.cents, signed: true))
            parts.append(otherRhythmText)
        }
        if let change = payment.priceChange {
            parts.append(model.hideAmounts ? "Preis geändert" : "Preis geändert, vorher \(Money.format(abs(change.previousCents)))")
        }
        if payment.isOwn {
            parts.append("eigener Eintrag")
        } else if let detectedText {
            parts.append("angepasst")
            parts.append(detectedText)
        }
        if isHidden { parts.append("ausgeblendet") }
        parts.append(payment.isEnded ? "ausgeblieben, zuletzt am \(DayFormat.short(payment.last))" : "nächste um den \(DayFormat.short(payment.next))")
        return parts.joined(separator: ", ")
    }
}

/// Sheet for an own entry or for other values of a detected payment.
private struct RecurringEntryEditor: View {
    private enum Field {
        case name, amount
    }

    @State var draft: RecurringDraft
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var focus: Field?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Art", selection: $draft.isExpense) {
                        Text("Ausgabe").tag(true)
                        Text("Einnahme").tag(false)
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $draft.title, prompt: Text("z. B. Miete"))
                        .focused($focus, equals: .name)
                    TextField("Betrag", text: $draft.amountText, prompt: Text("z. B. 49,90"))
                        .focused($focus, equals: .amount)
                    Picker("Rhythmus", selection: $draft.cadence) {
                        ForEach(RecurringPayment.Cadence.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if draft.isOwn {
                        Picker("Konto", selection: $draft.accountID) {
                            ForEach(accounts) { Text(model.displayName(of: $0)).tag(AccountID?.some($0.id)) }
                        }
                        DatePicker("Nächste Zahlung", selection: $draft.date, displayedComponents: .date)
                    }
                } header: {
                    Text(heading)
                } footer: {
                    Text(footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            if let error {
                // Icon and text: not by colour alone.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            HStack {
                if draft.detected != nil {
                    Button("Erkannte Werte einsetzen") { draft.revert() }
                        .disabled(draft.matchesDetected)
                        .help("Setzt Name, Betrag und Rhythmus auf das zurück, was MFN aus den Buchungen liest")
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || isSaving)
            }
            .padding(20)
        }
        // Wider with larger text; the form scrolls if it gets too tall.
        .frame(minWidth: 440, idealWidth: 440, maxWidth: 560)
        // Start where typing starts: the name of a new entry, the amount of an existing one.
        .onAppear { focus = draft.entryID == nil && draft.detected == nil ? .name : .amount }
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private var accounts: [Account] {
        model.orderedConnections.flatMap { model.orderedAccounts(of: $0.id) }
    }

    private var heading: String {
        if draft.detected != nil { return "Regelmäßige Zahlung anpassen" }
        return draft.entryID == nil ? "Eigener Eintrag" : "Eigenen Eintrag bearbeiten"
    }

    private var footnote: String {
        if let detected = draft.detected {
            let amount = model.hideAmounts ? "Betrag ausgeblendet" : Money.format(detected.cents, signed: true)
            return "Aus den Buchungen erkannt: \(detected.title), \(amount), \(detected.cadence.title.lowercased()). Deine Angaben gelten nur für die Fixkosten; die Buchungen bleiben, wie sie sind."
        }
        return "Für Zahlungen, die MFN nicht erkennt, etwa bar gezahlte Miete oder ein Konto, das nicht angebunden ist. Der Eintrag zählt nur in den Fixkosten, nicht im Kontostand."
    }

    private func save() {
        guard let entry = draft.entry() else { return }
        isSaving = true
        Task {
            // Back at the detected values: the change goes away instead of being stored.
            if draft.matchesDetected {
                error = draft.entryID == nil ? nil : await model.removeRecurringEntry(entry.id)
            } else {
                error = await model.saveRecurringEntry(entry)
            }
            isSaving = false
            if error == nil { dismiss() }
        }
    }
}
