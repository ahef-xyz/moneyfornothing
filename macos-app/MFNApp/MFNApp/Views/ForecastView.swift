import Charts
import MFNCore
import SwiftUI

/// The forecast panel of one account (`AppModel.showForecast`).
struct ForecastRequest: Identifiable {
    let account: Account
    /// Planned item to load into the form.
    var editing: UUID?
    var id: AccountID { account.id }
}

enum ForecastHorizon: Int, CaseIterable, Identifiable {
    case one = 1, three = 3, six = 6, twelve = 12

    var id: Int { rawValue }
    var title: String { rawValue == 1 ? String(localized: "1 Monat") : String(localized: "\(rawValue) Monate") }

    /// Shortest horizon that shows `day`, at least three months.
    static func covering(_ day: BankDay?, today: BankDay) -> ForecastHorizon {
        guard let day else { return .three }
        return allCases.first { $0.rawValue >= 3 && day <= today.adding(months: $0.rawValue) } ?? .twelve
    }
}

enum ForecastFormat {
    static let locale = Locale.autoupdatingCurrent
    static let day = Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).day().month(.abbreviated)
    static let dayYear = Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).day().month(.abbreviated).year()

    /// The year only when it is not this one.
    static func text(_ day: BankDay, today: BankDay = .today) -> String {
        day.startDate.formatted(day.year == today.year ? Self.day : dayYear)
    }

    static func kind(_ event: ForecastEvent) -> String {
        switch event.source {
        case .bank: String(localized: "Von der Bank angekündigt")
        case .manual: String(localized: "Selbst geplant")
        case .recurring: String(localized: "Regelmäßig, geschätzt")
        }
    }

    static func symbol(_ event: ForecastEvent) -> String {
        switch event.source {
        case .bank: "clock"
        case .manual: "calendar.badge.plus"
        case .recurring: "repeat"
        }
    }
}

/// Large balance forecast with everything expected on the account, and a form that shows what a
/// one-off payment would do to it before it is kept. Checkboxes take payments out for this view
/// only (what-if); nothing here reaches a bank.
struct ForecastSheet: View {
    let request: ForecastRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var horizon = ForecastHorizon.three
    /// Events left out of the forecast in this view (`ForecastEvent.id`).
    @State private var excluded: Set<String> = []
    /// What the form shows.
    @State private var draft = Draft()
    /// The draft the forecast is computed for: follows `draft` after a short pause, so typing
    /// does not recompute the forecast per keystroke.
    @State private var applied = Draft()
    /// The forecast of the last body evaluation, reused while its inputs are the same.
    @State private var memo = Memo()
    @State private var error: String?
    @FocusState private var amountFocused: Bool

    static let draftDebounce: Duration = .milliseconds(150)

    struct Draft: Equatable {
        var isExpense = true
        var amountText = ""
        var date = BankDay.today.startDate.addingTimeInterval(12 * 3600)
        var title = ""
        var editing: PlannedItem?

        var isEmpty: Bool { amountText.isEmpty && title.isEmpty && editing == nil }
        var day: BankDay { BankDay(date) }
        var cents: Int? { BudgetSheet.parseCents(amountText).map { isExpense ? -$0 : $0 } }

        var resolvedTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? (isExpense ? String(localized: "Geplante Ausgabe") : String(localized: "Geplante Einnahme")) : trimmed
        }
    }

    /// Everything `content` shows, derived from the basis, the horizon, the checkboxes and the
    /// applied draft.
    struct Derived {
        let all: [ForecastEvent]
        let included: [ForecastEvent]
        let path: ForecastPath
        let rows: [Row]
        let verdict: Verdict
    }

    @MainActor
    final class Memo {
        struct Key: Equatable {
            let revision: Int
            let today: BankDay
            let horizon: ForecastHorizon
            let excluded: Set<String>
            let applied: Draft
            let hideAmounts: Bool
        }

        var key: Key?
        var value: Derived?
    }

    /// Stands in for the ID of an item that is not kept yet.
    private static let newID = UUID()

    private var account: Account { request.account }
    private var today: BankDay { model.index.day }
    private var until: BankDay { today.adding(months: horizon.rawValue) }
    /// The applied draft as a forecast event.
    private var draftEvent: ForecastEvent? {
        applied.cents.map {
            ForecastEvent(source: .manual(applied.editing?.id ?? Self.newID), day: max(applied.day, today), dueDay: applied.day,
                          cents: $0, title: applied.resolvedTitle)
        }
    }

    /// Everything expected up to the horizon, the draft in place of the item it edits.
    private func events(_ basis: SnapshotIndex.ForecastBasis) -> [ForecastEvent] {
        var events = basis.forecast.events
        if let editing = applied.editing { events.removeAll { $0.source == .manual(editing.id) } }
        if let draftEvent {
            events.append(draftEvent)
            events.sort { ($0.day, -$0.cents, $0.id) < ($1.day, -$1.cents, $1.id) }
        }
        return events.filter { $0.day <= until }
    }

    private func derived(_ basis: SnapshotIndex.ForecastBasis) -> Derived {
        // The basis changes only with the snapshot, so its revision stands for it.
        let key = Memo.Key(revision: model.snapshotRevision, today: today, horizon: horizon, excluded: excluded,
                           applied: applied, hideAmounts: model.hideAmounts)
        if memo.key == key, let value = memo.value { return value }
        let all = events(basis)
        let included = all.filter { !excluded.contains($0.id) }
        let path = BalanceForecast.path(start: basis.startCents, events: included, today: today, until: until)
        let value = Derived(all: all, included: included, path: path,
                            rows: Self.rows(all, excluded: excluded, start: basis.startCents),
                            verdict: verdict(basis, included: included, path: path))
        memo.key = key
        memo.value = value
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let basis = model.forecastBasis(of: account.id) {
                content(basis)
            } else {
                ContentUnavailableView("Keine Prognose für dieses Konto", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        // Flexible: larger text and long titles get room instead of being clipped.
        .frame(minWidth: 780, idealWidth: 780, maxWidth: 1100, minHeight: 600, idealHeight: 700, maxHeight: 1000)
        .onAppear(perform: start)
        .task(id: draft) {
            guard draft != applied else { return }
            try? await Task.sleep(for: Self.draftDebounce)
            guard !Task.isCancelled else { return }
            applied = draft
        }
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    @ViewBuilder
    private func content(_ basis: SnapshotIndex.ForecastBasis) -> some View {
        let derived = derived(basis)
        let path = derived.path

        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prognose").font(.headline)
                Text(account.name).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Zeitraum", selection: $horizon) {
                ForEach(ForecastHorizon.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Zeitraum der Prognose")
        }

        HStack(spacing: 28) {
            figure("Heute, mit Vorgemerktem", cents: basis.startCents)
            figure("Tiefster Stand am \(ForecastFormat.text(path.lowestDay, today: today))", cents: path.lowestCents, warns: path.lowestCents < 0)
            figure("Stand am \(ForecastFormat.text(until, today: today))", cents: path.endCents)
            Spacer()
        }

        if model.hideAmounts {
            Label("Beträge ausgeblendet (⇧⌘H)", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ForecastChart(past: model.balanceCurve(of: account.id)?.past ?? [],
                          booked: basis.bookedCents, path: path, today: today, until: until, draft: draftEvent?.id)
                .frame(height: 170)
        }

        let matched = model.plannedItems(for: account.id).filter { basis.forecast.matches[$0.id] != nil && $0.id != applied.editing?.id }
        if !matched.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(matched) { item in
                    if let id = basis.forecast.matches[item.id], let booking = model.index.transactionsByID[id] {
                        matchRow(item, booking: booking)
                    }
                }
            }
        }

        List {
            let rows = derived.rows
            if rows.isEmpty {
                Text("Bis \(ForecastFormat.text(until, today: today)) ist nichts angekündigt, geplant oder regelmäßig zu erwarten.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                eventRow(row)
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 120, maxHeight: .infinity)

        Text("Geschätzt wird, was bisher jeden Monat etwa gleich hoch gebucht wurde. Ein entferntes Häkchen rechnet eine Buchung nur in dieser Ansicht heraus.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()
        form(derived.verdict)
    }

    // MARK: - Rows

    struct Row: Identifiable {
        let event: ForecastEvent
        /// Balance after the event; `nil` while it is taken out.
        let after: Int?
        var id: String { event.id }
    }

    static func rows(_ events: [ForecastEvent], excluded: Set<String>, start: Int) -> [Row] {
        var running = start
        return events.map { event in
            if excluded.contains(event.id) { return Row(event: event, after: nil) }
            running += event.cents
            return Row(event: event, after: running)
        }
    }

    private func eventRow(_ row: Row) -> some View {
        let event = row.event
        let isDraft = event.id == draftEvent?.id
        let isOn = Binding(
            get: { !excluded.contains(event.id) },
            set: { on in if on { excluded.remove(event.id) } else { excluded.insert(event.id) } }
        )
        // VoiceOver: the checkbox carries the whole row (date, title, kind, amount, balance), the
        // texts are hidden from it; the buttons name their item.
        return HStack(spacing: 10) {
            Toggle("\(event.title) einrechnen", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(rowLabel(row, isDraft: isDraft))
            Text(ForecastFormat.text(event.day, today: today))
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 92, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .strikethrough(row.after == nil)
                // The draft is told apart by its symbol and text, not by colour.
                Label(kindText(event, isDraft: isDraft), systemImage: isDraft ? "pencil" : ForecastFormat.symbol(event))
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(isDraft ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            if case let .manual(id) = event.source, !isDraft, let item = model.plannedItems(for: account.id).first(where: { $0.id == id }) {
                Button("Bearbeiten", systemImage: "pencil") { load(item) }
                    .help("\(item.title) bearbeiten")
                    .accessibilityLabel("\(item.title) bearbeiten")
                Button("Entfernen", systemImage: "trash") { remove(item) }
                    .help("\(item.title) entfernen")
                    .accessibilityLabel("\(item.title) entfernen")
            }
            AmountText(cents: event.cents, signed: true)
                .fixedSize()
                .frame(minWidth: 110, alignment: .trailing)
                .accessibilityHidden(true)
            Group {
                if let after = row.after {
                    HStack(spacing: 4) {
                        if after < 0, !model.hideAmounts {
                            Image(systemName: ShortfallFormat.symbol)
                                .foregroundStyle(.orange)
                        }
                        AmountText(cents: after, colorsInflow: false)
                    }
                } else {
                    Text("nicht eingerechnet")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(minWidth: 130, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        // Taken out: struck through and labelled; only slightly dimmed, the text stays readable.
        .opacity(row.after == nil ? 0.75 : 1)
        .padding(.vertical, 2)
    }

    private func rowLabel(_ row: Row, isDraft: Bool) -> String {
        let event = row.event
        var parts = [ForecastFormat.text(event.day, today: today), event.title, kindText(event, isDraft: isDraft)]
        parts.append(model.hideAmounts ? String(localized: "Betrag ausgeblendet") : Money.format(event.cents, signed: true))
        if let after = row.after {
            if !model.hideAmounts { parts.append(after < 0 ? String(localized: "Saldo danach \(Money.format(after)), unter null") : String(localized: "Saldo danach \(Money.format(after))")) }
        } else {
            parts.append(String(localized: "nicht eingerechnet"))
        }
        return parts.joined(separator: ", ")
    }

    private func kindText(_ event: ForecastEvent, isDraft: Bool) -> String {
        if isDraft { return applied.editing == nil ? String(localized: "Entwurf, noch nicht gemerkt") : String(localized: "In Bearbeitung") }
        let kind = ForecastFormat.kind(event)
        return event.isOverdue ? String(localized: "\(kind) · fällig seit \(ForecastFormat.text(event.dueDay, today: today))") : kind
    }

    /// A booking looks like the planned item: it is not counted until the user decides.
    private func matchRow(_ item: PlannedItem, booking: MFNCore.Transaction) -> some View {
        HStack(spacing: 10) {
            Label {
                Text("Schon gebucht? „\(item.title)“ (\(money(item.amountCents))) passt zu „\(booking.counterpartName)“ vom \(ForecastFormat.text(booking.effectiveDate, today: today)) (\(money(booking.amountCents))).")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.circle")
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            Button("Erledigt") { remove(item) }
                .help("Die geplante Buchung entfernen")
                .accessibilityLabel("„\(item.title)“ ist erledigt, entfernen")
            Button("Nein, kommt noch") {
                Task { error = await model.ignoreMatch(booking.id, for: item) }
            }
            .help("Die geplante Buchung wieder einrechnen")
            .accessibilityLabel("„\(item.title)“ kommt noch, wieder einrechnen")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func figure(_ title: LocalizedStringKey, cents: Int, warns: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if warns, !model.hideAmounts {
                    Image(systemName: ShortfallFormat.symbol)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("unter null")
                }
                AmountText(cents: cents, colorsInflow: false)
                    .font(.title3.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Form

    @ViewBuilder
    private func form(_ verdict: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.editing == nil ? String(localized: "Was wäre, wenn …") : String(localized: "Geplante Buchung ändern"))
                .font(.headline)
            HStack(spacing: 10) {
                Picker("Art", selection: $draft.isExpense) {
                    Text("Ausgabe").tag(true)
                    Text("Einnahme").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Art")
                TextField("Betrag", text: $draft.amountText, prompt: Text("Betrag, z. B. 1.200"))
                    .monospacedDigit()
                    .frame(width: 150)
                    .focused($amountFocused)
                    .accessibilityLabel("Betrag in Euro")
                DatePicker("Datum", selection: $draft.date, in: dateRange, displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
                    .environment(\.timeZone, BankDay.bankTimeZone)
                    .environment(\.locale, ForecastFormat.locale)
                    .accessibilityLabel("Datum")
                TextField("Bezeichnung", text: $draft.title, prompt: Text("Bezeichnung, z. B. Autoreparatur"))
                    .accessibilityLabel("Bezeichnung")
            }
            .textFieldStyle(.roundedBorder)
            // Fixed slot: the verdict must not make the sheet jump while typing.
            verdictView(verdict)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if !draft.isEmpty {
                    Button(draft.editing == nil ? String(localized: "Verwerfen") : String(localized: "Änderung verwerfen")) { reset() }
                }
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? String(localized: "Merken") : String(localized: "Sichern")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.cents == nil)
                    .help("Als geplante Buchung in die Prognose aufnehmen. MFN bewegt kein Geld.")
            }
        }
    }

    private var dateRange: ClosedRange<Date> {
        let first = min(today, draft.editing?.day ?? today)
        return first.startDate...today.adding(months: SnapshotIndex.forecastMonths).startDate.addingTimeInterval(86_399)
    }

    /// What the draft does to the forecast, in words.
    struct Verdict: Equatable {
        enum Kind { case hint, neutral, good, short }
        var kind: Kind
        var text: String
    }

    private func verdict(_ basis: SnapshotIndex.ForecastBasis, included: [ForecastEvent], path: ForecastPath) -> Verdict {
        guard let draftEvent else {
            return Verdict(kind: .hint, text: String(localized: "Betrag und Datum eingeben: Die Prognose zeigt sofort, ob es reicht. Gespeichert wird erst mit „Merken“."))
        }
        if model.hideAmounts { return Verdict(kind: .neutral, text: String(localized: "Beträge sind ausgeblendet (⇧⌘H).")) }
        guard let index = path.steps.firstIndex(where: { $0.event.id == draftEvent.id }) else {
            return Verdict(kind: .neutral, text: applied.day > until ? String(localized: "Das Datum liegt hinter dem gewählten Zeitraum.") : String(localized: "Die Buchung ist oben herausgerechnet."))
        }
        let after = path.steps[index...].min { $0.cents < $1.cents } ?? path.steps[index]
        let day = ForecastFormat.text(after.day, today: today)
        if after.cents >= 0 {
            return Verdict(kind: .good, text: String(localized: "Geht: Danach bleiben bis \(ForecastFormat.text(until, today: today)) mindestens \(Money.format(after.cents)) (am \(day))."))
        }
        guard draftEvent.cents < 0 else {
            return Verdict(kind: .short, text: String(localized: "Auch damit fehlen am \(day) noch \(Money.format(-after.cents))."))
        }
        let others = included.filter { $0.id != draftEvent.id }
        let earliest = BalanceForecast.earliestDay(spending: -draftEvent.cents, start: basis.startCents, events: others, today: today, until: until)
        let hint = earliest.map { String(localized: "Frühestens möglich ab \(ForecastFormat.text($0, today: today)).") }
            ?? String(localized: "Bis \(ForecastFormat.text(until, today: today)) reicht es an keinem Tag.")
        return Verdict(kind: .short, text: String(localized: "Reicht nicht: Am \(day) fehlen \(Money.format(-after.cents)). \(hint)"))
    }

    /// The verdict with its symbol (shape, not colour alone). VoiceOver hears a new verdict once
    /// typing pauses.
    private func verdictView(_ verdict: Verdict) -> some View {
        Group {
            switch verdict.kind {
            case .hint, .neutral:
                Text(verdict.text).foregroundStyle(.secondary)
            case .good:
                Label(verdict.text, systemImage: "checkmark.circle")
            case .short:
                Label {
                    Text(verdict.text)
                } icon: {
                    Image(systemName: ShortfallFormat.symbol).foregroundStyle(.orange)
                }
            }
        }
        .task(id: verdict) {
            guard verdict.kind == .good || verdict.kind == .short else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(verdict.text).post()
        }
    }

    // MARK: - Actions

    private func start() {
        let items = model.plannedItems(for: account.id)
        if let id = request.editing, let item = items.first(where: { $0.id == id }) {
            load(item)
        } else {
            horizon = .covering(items.last?.day, today: today)
            amountFocused = true
        }
    }

    private func load(_ item: PlannedItem) {
        draft = Draft(
            isExpense: item.amountCents < 0,
            amountText: RecurringDraft.text(item.amountCents, locale: ForecastFormat.locale),
            date: item.day.startDate.addingTimeInterval(12 * 3600),
            title: item.title,
            editing: item
        )
        applied = draft
        excluded.remove("manual:\(item.id.uuidString)")
        if item.day > until { horizon = .covering(item.day, today: today) }
        amountFocused = true
    }

    private func save() {
        guard let cents = draft.cents else { return }
        let item = PlannedItem(id: draft.editing?.id ?? UUID(), accountID: account.id, day: draft.day, amountCents: cents, title: draft.resolvedTitle,
                               createdAt: draft.editing?.createdAt ?? Date(), ignoredMatches: draft.editing?.ignoredMatches ?? [])
        Task {
            error = await model.savePlannedItem(item)
            if error == nil {
                excluded.remove("manual:\(Self.newID.uuidString)")
                if item.day > until { horizon = .covering(item.day, today: today) }
                reset()
            }
        }
    }

    private func remove(_ item: PlannedItem) {
        Task {
            error = await model.removePlannedItem(item.id)
            if error == nil, draft.editing?.id == item.id { reset() }
        }
    }

    /// Empties the form at once (no pause as while typing).
    private func reset() {
        draft = Draft()
        applied = draft
    }

    private func money(_ cents: Int) -> String {
        model.hideAmounts ? "•••••" : Money.format(cents)
    }
}

// MARK: - Chart

/// The last 31 days (solid) and the forecast (dotted, stepped). Self-planned payments are marked
/// with a diamond (filled when kept, hollow for the draft), the lowest point below zero with an
/// orange dot; hovering reads a day, VoiceOver gets the points through the chart descriptor.
private struct ForecastChart: View {
    let past: [SnapshotIndex.BalanceCurve.Point]
    let booked: Int
    let path: ForecastPath
    let today: BankDay
    let until: BankDay
    /// `ForecastEvent.id` of the payment that is not kept yet.
    let draft: String?
    @State private var selected: Date?

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let euros: Double
    }

    private var forecast: [Point] {
        var points = [(today, booked), (today, path.startCents)]
        points += path.steps.map { ($0.day, $0.cents) }
        points.append((until, path.endCents))
        return points.enumerated().map { Point(id: $0.offset, date: $0.element.0.startDate, euros: Double($0.element.1) / 100) }
    }

    private var manual: [ForecastPath.Step] {
        path.steps.filter { if case .manual = $0.event.source { true } else { false } }
    }

    /// Balance at the end of `date`'s day.
    private func reading(at date: Date) -> (day: BankDay, cents: Int)? {
        let day = BankDay(date)
        guard let first = past.first?.day, day >= first, day <= until else { return nil }
        if day < today { return past.first { $0.day == day }.map { (day, $0.cents) } }
        return (day, path.steps.last { $0.day <= day }?.cents ?? path.startCents)
    }

    var body: some View {
        Chart {
            ForEach(past) { point in
                LineMark(x: .value("Tag", point.day.startDate), y: .value("Saldo", Double(point.cents) / 100), series: .value("Art", "Saldo"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(forecast) { point in
                LineMark(x: .value("Tag", point.date), y: .value("Saldo", point.euros), series: .value("Art", "Prognose"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [2, 3]))
            }
            if path.lowestCents < 0 || (past.map(\.cents).min() ?? 0) < 0 {
                RuleMark(y: .value("Null", 0))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            RuleMark(x: .value("Heute", today.startDate))
                .foregroundStyle(Color.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Heute").font(.caption2).foregroundStyle(.secondary)
                }
            ForEach(manual, id: \.event.id) { step in
                if step.event.id == draft {
                    PointMark(x: .value("Tag", step.day.startDate), y: .value("Saldo", Double(step.cents) / 100))
                        .symbol(.diamond.strokeBorder(lineWidth: 2))
                        .symbolSize(90)
                        .foregroundStyle(Color.primary)
                } else {
                    PointMark(x: .value("Tag", step.day.startDate), y: .value("Saldo", Double(step.cents) / 100))
                        .symbol(.diamond)
                        .symbolSize(70)
                        .foregroundStyle(Color.primary)
                }
            }
            if path.lowestCents < 0 {
                PointMark(x: .value("Tag", path.lowestDay.startDate), y: .value("Saldo", Double(path.lowestCents) / 100))
                    .symbolSize(40)
                    .foregroundStyle(.orange)
            }
            if let selected, let reading = reading(at: selected) {
                RuleMark(x: .value("Auswahl", reading.day.startDate))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(ForecastFormat.text(reading.day, today: today)): \(Money.format(reading.cents))")
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartXScale(domain: (past.first?.day ?? today).startDate...until.startDate)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let euros = value.as(Double.self) {
                        Text(Int(euros.rounded()).formatted(.number.notation(.compactName).locale(ForecastFormat.locale)) + " €")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: ForecastFormat.day)
            }
        }
        .padding(.top, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saldoverlauf der letzten 31 Tage mit Prognose bis \(ForecastFormat.text(until, today: today))")
        .accessibilityValue("Heute \(Money.format(path.startCents)), tiefster Stand \(Money.format(path.lowestCents)) am \(ForecastFormat.text(path.lowestDay, today: today)), am Ende \(Money.format(path.endCents))")
        .accessibilityChartDescriptor(ForecastChartDescriptor(past: past, path: path, today: today, until: until))
    }
}

private struct ForecastChartDescriptor: AXChartDescriptorRepresentable {
    let past: [SnapshotIndex.BalanceCurve.Point]
    let path: ForecastPath
    let today: BankDay
    let until: BankDay

    func makeChartDescriptor() -> AXChartDescriptor {
        // Categories must be unique: forecast days are marked, repeated days numbered.
        var seen: [String: Int] = [:]
        func label(_ day: BankDay, forecast: Bool) -> String {
            let base = forecast ? String(localized: "\(ForecastFormat.text(day, today: today)) (Prognose)") : ForecastFormat.text(day, today: today)
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base) \(count + 1)"
        }
        let before = past.map { (label($0.day, forecast: false), $0.cents) }
        let future = ([(today, path.startCents)] + path.steps.map { ($0.day, $0.cents) } + [(until, path.endCents)])
            .map { (label($0.0, forecast: true), $0.1) }
        let values = (before + future).map { Double($0.1) / 100 }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: String(localized: "Tag"), categoryOrder: (before + future).map(\.0))
        let yAxis = AXNumericDataAxisDescriptor(title: String(localized: "Saldo"), range: low...max(high, low + 1), gridlinePositions: []) {
            Money.format(Int(($0 * 100).rounded()))
        }
        func series(_ name: String, _ points: [(String, Int)]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true, dataPoints: points.map { AXDataPoint(x: $0.0, y: Double($0.1) / 100) })
        }
        return AXChartDescriptor(title: String(localized: "Saldoverlauf mit Prognose"), summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [],
                                 series: [series(String(localized: "Saldo"), before), series(String(localized: "Prognose"), future)])
    }
}

// MARK: - List row

/// A self-planned payment in the account's list, above the bank's pending and planned ones.
/// Not a transaction: it cannot be selected or categorised, a click opens it in the forecast.
struct PlannedItemRow: View {
    let item: PlannedItem
    let account: Account
    /// Shown in lists over several accounts.
    var accountName: String?
    /// A booking looks like this item already (it waits for an answer in the forecast).
    let isMatched: Bool
    @Environment(AppModel.self) private var model
    /// A failed "Entfernen" (the item stays in the list).
    @State private var removeError: String?

    private func remove() {
        Task { removeError = await model.removePlannedItem(item.id) }
    }

    private var subtitle: String {
        let today = BankDay.today
        let own = accountName.map { String(localized: "\($0) · selbst geplant") } ?? String(localized: "Selbst geplant")
        if isMatched { return String(localized: "\(own) · schon gebucht? In der Prognose klären") }
        if item.day < today { return String(localized: "\(own) · fällig seit \(ForecastFormat.text(item.day, today: today))") }
        return String(localized: "\(own) · fällig am \(ForecastFormat.text(item.day, today: today))")
    }

    var body: some View {
        Button {
            model.showForecast(for: account, editing: item.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AmountText(cents: item.amountCents, signed: true)
                    .frame(width: 110, alignment: .trailing)
                // Same column as the running balance of the rows below.
                Text("–")
                    .foregroundStyle(.tertiary)
                    .frame(width: 100, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .italic()
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("In der Prognose öffnen")
        .contextMenu {
            Button("In der Prognose bearbeiten …") { model.showForecast(for: account, editing: item.id) }
            Button("Entfernen", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(item.title), \(subtitle)")
        .accessibilityValue(model.hideAmounts ? String(localized: "Betrag ausgeblendet") : Money.format(item.amountCents, signed: true))
        .accessibilityHint("Öffnet die Prognose")
        .accessibilityAction { model.showForecast(for: account, editing: item.id) }
        // The context menu's commands for VoiceOver and the keyboard (actions rotor).
        .accessibilityAction(named: "In der Prognose bearbeiten") { model.showForecast(for: account, editing: item.id) }
        .accessibilityAction(named: "Entfernen", remove)
        .alert("Entfernen fehlgeschlagen", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK") { removeError = nil }
        } message: {
            Text(removeError ?? "")
        }
    }
}
