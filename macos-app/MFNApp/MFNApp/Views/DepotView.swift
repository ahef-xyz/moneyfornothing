import MFNCore
import SwiftUI

/// Depot account: positions instead of a transaction list. Native `Table` (sortable columns),
/// monospaced digits, no gain/loss colours (green is for inflows only, CLAUDE.md §6 UI): gain or
/// loss against the purchase price (protocol v9) is told by its sign.
/// If the depot also has transactions, the toolbar switches between positions and transactions.
struct DepotView: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .positions
    @State private var sortOrder = [KeyPathComparator(\PositionRow.valueCents, order: .reverse)]
    @FocusState private var tableFocused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case positions = "Positionen"
        case transactions = "Umsätze"
        var id: Self { self }
    }

    var body: some View {
        let content = DepotContent(account: account, model: model)
        Group {
            if mode == .transactions && content.hasTransactions {
                TransactionListView(item: .account(account.id))
            } else {
                positions(content)
                    .navigationTitle(account.name)
                    .navigationSubtitle(model.connectionName(account.connectionID))
                    // The sidebar handed the focus over (→ or Return there).
                    .onChange(of: model.focusRequest) { takeFocus() }
                    .onAppear { takeFocus() }
            }
        }
        .toolbar {
            if content.hasTransactions {
                ToolbarItem(placement: .principal) {
                    Picker("Ansicht", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Positionen oder Umsätze des Depots anzeigen")
                }
            }
        }
    }

    private func takeFocus() {
        guard model.focusRequest == .content else { return }
        model.focusRequest = nil
        tableFocused = true
    }

    @ViewBuilder
    private func positions(_ content: DepotContent) -> some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            DepotHeader(content: content)
                .layoutPriority(1)
            DepotHistoryChart(account: account)
            Divider()
            if content.rows.isEmpty {
                ContentUnavailableView("Keine Positionen", systemImage: "chart.pie",
                                       description: Text("Nach dem nächsten Abgleich erscheinen hier die Wertpapiere."))
            } else {
                Table(content.rows.sorted(using: sortOrder), selection: $model.selectedPositionISIN, sortOrder: $sortOrder) {
                    TableColumn("Wertpapier", value: \PositionRow.name) { row in
                        HStack(spacing: 10) {
                            MonogramAvatar(name: row.name, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).lineLimit(1)
                                Text(row.isin)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn("Stück", value: \PositionRow.quantity) { row in
                        Text(model.hideAmounts ? "•••" : PositionFormat.quantity(row.quantity))
                            .monospacedDigit()
                            .hiddenAmountLabel(model.hideAmounts)
                    }
                    .width(min: 80, ideal: 110)
                    .alignment(.trailing)

                    TableColumn("Kurs", value: \PositionRow.priceCents) { row in
                        PriceText(row: row)
                    }
                    .width(min: 80, ideal: 110)
                    .alignment(.trailing)

                    TableColumn("Wert", value: \PositionRow.valueCents) { row in
                        if row.isBelowOneCent {
                            Text("–")
                                .foregroundStyle(.secondary)
                                .help("Kurs unter 1 Cent: Wert nur in der Depotsumme enthalten")
                        } else {
                            AmountText(cents: row.valueCents, currency: row.currency, colorsInflow: false)
                                .fontWeight(.medium)
                        }
                    }
                    .width(min: 90, ideal: 120)
                    .alignment(.trailing)

                    if content.hasPurchasePrices {
                        TableColumn("Gewinn/Verlust", value: \PositionRow.gainSortKey) { row in
                            GainCell(row: row)
                        }
                        .width(min: 110, ideal: 130)
                        .alignment(.trailing)
                    }

                    TableColumn("Anteil", value: \PositionRow.share) { row in
                        ShareCell(share: row.share)
                    }
                    .width(min: 90, ideal: 130)
                }
                .tableStyle(.inset)
                .focused($tableFocused)
                .onKeyPress(.leftArrow) {
                    model.focusRequest = .sidebar
                    return .handled
                }
                // Esc first clears the selection, then goes back to the sidebar.
                .onKeyPress(.escape) {
                    if model.selectedPositionISIN != nil {
                        model.selectedPositionISIN = nil
                    } else {
                        model.focusRequest = .sidebar
                    }
                    return .handled
                }
            }
            Divider()
            DepotFooter(content: content)
        }
        // Pinned to the top like the transaction list: without minHeight 0 a short window makes the
        // column overflow and get centred, so header and chart slide under the toolbar.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Content

/// One table row. `id` is the ISIN (unique per depot).
struct PositionRow: Identifiable, Hashable {
    let position: SecurityPosition
    let share: Double

    var id: String { position.isin }
    var name: String { position.name }
    var isin: String { position.isin }
    var quantity: Decimal { position.quantity }
    var priceCents: Int { position.priceCents }
    var valueCents: Int { position.valueCents }
    var currency: String { position.currency }
    var gainCents: Int? { position.gainCents }
    /// Sortable stand-in: positions without a purchase price sort below every loss.
    var gainSortKey: Int { position.gainCents ?? .min }
    /// `priceCents` is whole cents (protocol v3): penny stocks round to 0 although they have value.
    var isBelowOneCent: Bool { position.priceCents == 0 && position.quantity != 0 }
}

@MainActor
struct DepotContent {
    let account: Account
    let rows: [PositionRow]
    let balance: Balance?
    let hasTransactions: Bool
    let asOf: Date?
    let lastSync: Date?
    /// Sum of the positions in the depot's currency.
    private let positionsCents: Int
    /// Gain over the positions with a purchase price in the depot's currency, and how many those are.
    let gain: (cents: Int, ratio: Double?, count: Int)?

    init(account: Account, model: AppModel) {
        self.account = account
        let snapshot = model.snapshot
        let positions = snapshot.securities.filter { $0.accountID == account.id }
        let balance = snapshot.balances[account.id]
        self.balance = balance
        // Total and shares in the depot's currency only; foreign-currency positions are not
        // converted (no share rather than a mixed sum).
        let currency = balance?.currency ?? account.currency
        let total = positions.filter { $0.currency == currency }.reduce(0) { $0 + $1.valueCents }
        rows = positions.map {
            PositionRow(position: $0, share: total > 0 && $0.currency == currency ? Double($0.valueCents) / Double(total) : 0)
        }
        positionsCents = total
        let priced = positions.filter { $0.currency == currency && $0.purchaseValueCents != nil }
        if priced.isEmpty {
            gain = nil
        } else {
            let purchase = priced.reduce(0) { $0 + ($1.purchaseValueCents ?? 0) }
            let cents = priced.reduce(0) { $0 + ($1.gainCents ?? 0) }
            gain = (cents, purchase > 0 ? Double(cents) / Double(purchase) : nil, priced.count)
        }
        hasTransactions = !snapshot.transactions(of: account.id).isEmpty
        asOf = positions.map(\.asOf).max()
        lastSync = snapshot.syncStates[account.connectionID]?.lastSuccess
    }

    /// Depot value: the connector's balance (exact prices) if known, else the sum of the rows.
    var valueCents: Int { balance?.bookedCents ?? positionsCents }
    var hasSubCentPrices: Bool { rows.contains(where: \.isBelowOneCent) }
    var hasPurchasePrices: Bool { rows.contains { $0.position.purchasePriceCents != nil } }
    var currency: String { balance?.currency ?? account.currency }
}

// MARK: - Header, footer, cells

private struct DepotHeader: View {
    let content: DepotContent
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text(content.account.name)
                    .font(.title2.weight(.semibold))
                Text(details)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("DEPOTWERT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AmountText(cents: content.valueCents, currency: content.balance?.currency ?? content.account.currency, colorsInflow: false)
                    .font(.title.weight(.semibold))
                Text(content.rows.count == 1 ? "1 Position" : "\(content.rows.count) Positionen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let gain = content.gain {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("GEWINN/VERLUST")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AmountText(cents: gain.cents, currency: content.currency, colorsInflow: false, signed: true)
                        .font(.title.weight(.semibold))
                    Text(gainCaption(gain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Gewinn/Verlust seit Kauf")
                .accessibilityValue(gainAccessibilityValue(gain))
                .help("Kurswert minus Einstandswert, ohne Kosten und Dividenden")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func gainAccessibilityValue(_ gain: (cents: Int, ratio: Double?, count: Int)) -> String {
        var parts = [model.hideAmounts ? "ausgeblendet" : GainText.spoken(gain.cents, ratio: gain.ratio, currency: content.currency)]
        if gain.count < content.rows.count { parts.append("\(gain.count) von \(content.rows.count) Positionen") }
        return parts.joined(separator: ", ")
    }

    private func gainCaption(_ gain: (cents: Int, ratio: Double?, count: Int)) -> String {
        var parts: [String] = []
        if let ratio = gain.ratio { parts.append(model.hideAmounts ? "••" : PositionFormat.signedPercent(ratio)) }
        if gain.count < content.rows.count { parts.append("\(gain.count) von \(content.rows.count) Positionen") }
        return parts.isEmpty ? "seit Kauf" : parts.joined(separator: " · ")
    }

    private var details: String {
        var parts = [model.connectionName(content.account.connectionID), content.account.type.title]
        if let lastSync = content.lastSync {
            parts.append("abgeglichen \(DayFormat.syncTime(lastSync))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct DepotFooter: View {
    let content: DepotContent
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let asOf = content.asOf {
                Text("Kurse vom \(asOf.formatted(date: .abbreviated, time: .shortened))")
            }
            if content.hasSubCentPrices {
                HintChip(text: "Kurse unter 1 Cent nur in der Summe")
                    .help("Einzelne Kurse liegen unter einem Cent und werden gerundet als 0,00 € geführt. Der Depotwert rechnet mit den genauen Kursen.")
            }
            Spacer()
            if let isin = model.selectedPositionISIN, let row = content.rows.first(where: { $0.id == isin }) {
                Text("Ausgewählt: \(row.name)")
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

private struct PriceText: View {
    let row: PositionRow
    @Environment(AppModel.self) private var model

    var body: some View {
        if row.isBelowOneCent {
            Text(model.hideAmounts ? "•••••" : "< 0,01 €")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .hiddenAmountLabel(model.hideAmounts)
                .help("Kurs unter einem Cent")
        } else {
            AmountText(cents: row.priceCents, currency: row.currency, colorsInflow: false)
        }
    }
}

/// Gain or loss of one position: signed amount, signed percentage below; "–" without purchase price.
private struct GainCell: View {
    let row: PositionRow
    @Environment(AppModel.self) private var model

    var body: some View {
        if let gain = row.gainCents {
            VStack(alignment: .trailing, spacing: 1) {
                AmountText(cents: gain, currency: row.currency, colorsInflow: false, signed: true)
                if let ratio = row.position.gainRatio {
                    Text(model.hideAmounts ? "••" : PositionFormat.signedPercent(ratio))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .hiddenAmountLabel(model.hideAmounts)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.hideAmounts ? "Gewinn/Verlust ausgeblendet"
                                : GainText.spoken(gain, ratio: row.position.gainRatio, currency: row.currency))
        } else {
            Text("–")
                .foregroundStyle(.secondary)
                .help("Die Bank liefert für diese Position keinen Einstandskurs")
                .accessibilityLabel("Kein Einstandskurs")
        }
    }
}

/// VoiceOver wording for a gain: "Gewinn 1.234,56 €, plus 12,3 %" / "Verlust …".
enum GainText {
    static func spoken(_ cents: Int, ratio: Double?, currency: String) -> String {
        let word = cents < 0 ? "Verlust" : "Gewinn"
        var text = "\(word) \(Money.format(abs(cents), currency: currency))"
        if let ratio { text += ", \(PositionFormat.signedPercent(ratio))" }
        return text
    }
}

/// Share of the depot: percentage plus a neutral bar (no colour meaning).
private struct ShareCell: View {
    let share: Double
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text(model.hideAmounts ? "••" : PositionFormat.percent(share))
                .monospacedDigit()
                .hiddenAmountLabel(model.hideAmounts)
                .frame(minWidth: 44, alignment: .trailing)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.secondary)
                        .frame(width: model.hideAmounts ? 0 : max(0, proxy.size.width * share))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

enum PositionFormat {
    private static let german = Locale(identifier: "de_DE")

    static func quantity(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 6)).locale(german))
    }

    /// "+12,3 %" / "−4,0 %": always one decimal and a sign.
    static func signedPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)).locale(german))
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(value < 0.1 ? 1 : 0)).locale(german))
    }
}

// MARK: - Inspector

/// Detail pane for the selected position (⌥⌘I), styled like the transaction inspector.
struct PositionInspector: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        let content = DepotContent(account: account, model: model)
        if let isin = model.selectedPositionISIN, let row = content.rows.first(where: { $0.id == isin }) {
            Form {
                Section {
                    LabeledContent("Stück") {
                        Text(model.hideAmounts ? "•••" : PositionFormat.quantity(row.quantity)).monospacedDigit()
                            .hiddenAmountLabel(model.hideAmounts)
                    }
                    LabeledContent("Kurs") { PriceText(row: row) }
                    LabeledContent("Wert") {
                        if row.isBelowOneCent {
                            Text("nur in der Depotsumme").foregroundStyle(.secondary)
                        } else {
                            AmountText(cents: row.valueCents, currency: row.currency, colorsInflow: false)
                        }
                    }
                    LabeledContent("Anteil am Depot") {
                        Text(model.hideAmounts ? "••" : PositionFormat.percent(row.share)).monospacedDigit()
                            .hiddenAmountLabel(model.hideAmounts)
                    }
                    LabeledContent("Kurs vom", value: row.position.asOf.formatted(date: .abbreviated, time: .shortened))
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        MonogramAvatar(name: row.name, size: 44)
                        Text(row.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.bottom, 6)
                }
                if let purchase = row.position.purchasePriceCents, let purchaseValue = row.position.purchaseValueCents {
                    Section {
                        LabeledContent("Einstandskurs") {
                            AmountText(cents: purchase, currency: row.currency, colorsInflow: false)
                        }
                        LabeledContent("Einstandswert") {
                            AmountText(cents: purchaseValue, currency: row.currency, colorsInflow: false)
                        }
                        LabeledContent("Gewinn/Verlust") { GainCell(row: row) }
                    } header: {
                        Text("Seit Kauf")
                    } footer: {
                        Text("Kurswert minus Einstandswert, ohne Kosten und Dividenden.")
                    }
                } else {
                    Section("Seit Kauf") {
                        Text("Die Bank liefert für diese Position keinen Einstandskurs.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Wertpapier") {
                    CopyableRow(label: "ISIN", value: row.isin, monospaced: true)
                    LabeledContent("Depot", value: "\(model.connectionName(account.connectionID)) · \(account.name)")
                }
            }
            .formStyle(.grouped)
            .id(row.id)
        } else {
            ContentUnavailableView("Keine Position ausgewählt", systemImage: "sidebar.trailing",
                                   description: Text("Wähle ein Wertpapier, um Details zu sehen."))
        }
    }
}
