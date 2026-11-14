import AppKit
import MFNCore
import SwiftUI

/// Right-hand detail pane for the selected transaction (⌥⌘I). Native grouped form, like
/// Finder's "Informationen": hero on top, then labelled sections.
struct TransactionInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let transaction = model.selectedTransaction {
            TransactionDetails(transaction: transaction)
                .id(transaction.id)
        } else if model.selectedTransactionIDs.count > 1 {
            MultiSelectionSummary()
        } else {
            ContentUnavailableView("Keine Buchung ausgewählt", systemImage: "sidebar.trailing",
                                   description: Text("Wähle eine Buchung, um Details zu sehen."))
        }
    }
}

// MARK: - Single transaction

private struct TransactionDetails: View {
    let transaction: MFNCore.Transaction
    @Environment(AppModel.self) private var model
    @State private var showsRaw = false

    private var status: TransactionStatus { transaction.status }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { StatusLabel(status: status) }
                if let booked = transaction.bookingDate {
                    LabeledContent("Buchungstag", value: InspectorFormat.date(booked))
                }
                LabeledContent(status == .planned ? "Fällig" : "Wertstellung", value: InspectorFormat.date(transaction.valueDate))
                if let person = model.initiators[transaction.id] {
                    LabeledContent("Ausgeführt von") {
                        Label(person.name, systemImage: "person")
                            .help(person.id.map { "ID bei der Bank: \($0)" } ?? person.name)
                    }
                }
                if let account = model.account(transaction.accountID),
                   let connection = model.snapshot.connections.first(where: { $0.id == account.connectionID }) {
                    LabeledContent("Konto") {
                        HStack(spacing: 6) {
                            BankBadge(connection: connection, size: 14)
                            Text("\(connection.displayName) · \(account.name)")
                        }
                    }
                }
            } header: {
                Hero(transaction: transaction)
            }

            categorySection

            Section("Gegenpartei") {
                LabeledContent("Name", value: transaction.counterpartName)
                if let iban = transaction.counterpartIBAN {
                    CopyableRow(label: "IBAN", value: IBANFormat.grouped(iban), copyValue: iban, monospaced: true)
                }
                if !transaction.purpose.isEmpty {
                    LabeledContent("Verwendungszweck") {
                        Text(transaction.purpose)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                if let original = transaction.originalAmountCents, let currency = transaction.originalCurrency {
                    LabeledContent("Originalbetrag") {
                        AmountText(cents: original, currency: currency, colorsInflow: false)
                    }
                }
            }

            if hasReferences {
                Section("Referenzen") {
                    if let eref = transaction.eref { CopyableRow(label: "End-to-End", value: eref, monospaced: true) }
                    if let mref = transaction.mref { CopyableRow(label: "Mandat", value: mref, monospaced: true) }
                    if let creditor = transaction.creditorID { CopyableRow(label: "Gläubiger-ID", value: creditor, monospaced: true) }
                    if let external = transaction.externalID { CopyableRow(label: "Bank-ID", value: external, monospaced: true) }
                    CopyableRow(
                        label: "Fingerprint",
                        value: "\(transaction.fingerprint.prefix(6))…\(transaction.fingerprint.suffix(6))",
                        copyValue: transaction.fingerprint,
                        monospaced: true
                    )
                }
            }

            HistorySection(transaction: transaction)

            if InspectorFormat.hasRawContent(transaction.rawJSON) {
                Section {
                    DisclosureGroup("Antwort der Bank", isExpanded: $showsRaw) {
                        // Pretty-printed only while expanded.
                        if showsRaw, let raw = InspectorFormat.prettyJSON(transaction.rawJSON) ?? String(data: transaction.rawJSON, encoding: .utf8) {
                            Text(raw)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } header: {
                    Text("Rohdaten")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hasReferences: Bool {
        transaction.eref != nil || transaction.mref != nil || transaction.creditorID != nil || transaction.externalID != nil
    }

    // MARK: Category

    @ViewBuilder
    private var categorySection: some View {
        Section("Kategorie") {
            if let category = transaction.categoryID, model.needsReview(transaction) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            Text("Vorschlag: **\(category.title)**")
                        } icon: {
                            Image(systemName: category.symbol).foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Button("Übernehmen") { model.acceptSuggestion(for: transaction) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Vorschlag übernehmen (⌘⏎)")
                    }
                    ConfidenceGauge(confidence: transaction.confidence ?? 0)
                    SourceLabel(source: transaction.categorySource)
                }
                .padding(.vertical, 2)
            } else if let category = transaction.categoryID {
                LabeledContent {
                    SourceLabel(source: transaction.categorySource)
                } label: {
                    Label(category.title, systemImage: category.symbol)
                }
                if let confidence = transaction.confidence, transaction.categorySource != .manual {
                    ConfidenceGauge(confidence: confidence)
                }
            } else {
                Label("Noch keine Kategorie", systemImage: "tag.slash")
                    .foregroundStyle(.secondary)
            }
            if transaction.status != .cancelled {
                HStack {
                    Button(model.needsReview(transaction) ? "Andere Kategorie …" : transaction.categoryID == nil ? "Kategorie zuweisen …" : "Ändern …") {
                        model.showCategoryPicker(for: [transaction.id])
                    }
                    .help("Kategorie zuweisen (⌘K)")
                    Button("Regel erstellen …") { model.showRuleEditor(for: transaction.id) }
                        .help("Immer diese Kategorie für ähnliche Umsätze (⇧⌘K)")
                    Spacer()
                }
                .controlSize(.small)
                .disabled(!model.canCategorize)
            }
        }
    }
}

// MARK: - Hero

private struct Hero: View {
    let transaction: MFNCore.Transaction

    var body: some View {
        VStack(spacing: 8) {
            MonogramAvatar(name: transaction.counterpartName, status: transaction.status, size: 56)
            Text(transaction.counterpartName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .strikethrough(transaction.status == .cancelled)
            AmountText(cents: transaction.amountCents, currency: transaction.currency,
                       colorsInflow: transaction.status != .cancelled, signed: true)
                .font(.system(size: 26, weight: .semibold))
                .italic(transaction.status.isUpcoming)
                .strikethrough(transaction.status == .cancelled)
            if let line = subtitle {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .textCase(nil)
        .textSelection(.enabled)
    }

    private var subtitle: String? {
        guard let original = transaction.originalAmountCents, let currency = transaction.originalCurrency else { return nil }
        return "ursprünglich \(Money.format(original, currency: currency))"
    }
}

// MARK: - Pieces

/// Status with icon and text, never colour alone.
private struct StatusLabel: View {
    let status: TransactionStatus

    var body: some View {
        switch status {
        case .booked: Label("Gebucht", systemImage: "checkmark.circle")
        case .pending: Label("Vorgemerkt", systemImage: "hourglass").italic()
        case .planned: Label("Geplant", systemImage: "clock").italic()
        case .cancelled: Label("Storniert", systemImage: "xmark.circle").strikethrough()
        }
    }
}

private struct SourceLabel: View {
    let source: CategorySource?

    var body: some View {
        Group {
            switch source {
            case let source?: Label(source.title, systemImage: source.symbol)
            case nil: Label("Unbekannt", systemImage: "questionmark.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct ConfidenceGauge: View {
    let confidence: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("Konfidenz")
                .foregroundStyle(.secondary)
            Gauge(value: confidence, in: 0...1) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(confidence < Categorizer.reviewThreshold ? Color.accentColor : Color.secondary)
            Text(confidence.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE"))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct CopyableRow: View {
    let label: String
    let value: String
    var copyValue: String?
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(monospaced ? .callout.monospaced() : nil)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.copyConcealed(copyValue ?? value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("\(label) kopieren")
                .accessibilityLabel("\(label) kopieren")
            }
        }
    }
}

/// Other bookings with the same counterparty: summary of the last 12 months plus the latest five.
private struct HistorySection: View {
    let transaction: MFNCore.Transaction
    @Environment(AppModel.self) private var model

    var body: some View {
        let all = model.bookedHistory(counterpart: transaction.counterpartName.lowercased()).filter { $0.id != transaction.id }
        if !all.isEmpty {
            let since = BankDay(Date()).adding(months: -12)
            // Summed in this transaction's currency only (others are not converted).
            let lastYear = all.filter { $0.effectiveDate >= since && $0.currency == transaction.currency }
            Section {
                if !lastYear.isEmpty {
                    LabeledContent("Letzte 12 Monate") {
                        HStack(spacing: 4) {
                            Text("\(lastYear.count)×")
                            Text("·")
                            AmountText(cents: lastYear.sumCents, currency: transaction.currency, colorsInflow: false)
                        }
                        .monospacedDigit()
                    }
                    LabeledContent("Durchschnitt") {
                        AmountText(cents: lastYear.sumCents / lastYear.count, currency: transaction.currency, colorsInflow: false)
                    }
                }
                ForEach(all.prefix(5)) { other in
                    HStack(spacing: 8) {
                        Text(InspectorFormat.shortDate(other.effectiveDate))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        if other.categoryID != nil {
                            CategoryChip(transaction: other)
                        } else {
                            Text("ohne Kategorie").foregroundStyle(.tertiary)
                        }
                        Spacer()
                        AmountText(cents: other.amountCents, currency: other.currency, signed: true)
                    }
                }
            } header: {
                Text("Verlauf")
            }
        }
    }
}

private struct MultiSelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.transactions(model.selectedTransactionIDs)
        // EUR only (other currencies are not converted), cancelled ones never moved money.
        let summed = selected.filter { $0.status != .cancelled && $0.currency == "EUR" }
        let inflow = summed.filter { $0.amountCents > 0 }.sumCents
        let outflow = summed.filter { $0.amountCents < 0 }.sumCents
        Form {
            Section {
                LabeledContent("Eingänge") { AmountText(cents: inflow, signed: true) }
                LabeledContent("Ausgänge") { AmountText(cents: outflow) }
                LabeledContent("Summe") { AmountText(cents: summed.sumCents, colorsInflow: false).fontWeight(.semibold) }
                HStack {
                    let reviewable = model.reviewable()
                    if !reviewable.isEmpty {
                        Button("\(reviewable.count) Vorschläge übernehmen") { model.acceptSuggestions() }
                            .help("Vorschläge übernehmen (⌘⏎)")
                    }
                    Button("Kategorie zuweisen …") { model.showCategoryPicker() }
                        .help("Allen ausgewählten Umsätzen eine Kategorie geben (⌘K)")
                    Spacer()
                }
                .controlSize(.small)
                .disabled(!model.canCategorize)
            } header: {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("\(selected.count) Buchungen ausgewählt")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}

enum InspectorFormat {
    private static let style = Date.FormatStyle(locale: Locale(identifier: "de_DE"), timeZone: BankDay.bankTimeZone)

    /// "Mo., 9. Nov. 2026"
    static func date(_ day: BankDay) -> String {
        day.startDate.formatted(style.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    /// "12. Okt."
    static func shortDate(_ day: BankDay) -> String {
        day.startDate.formatted(style.day().month(.abbreviated))
    }

    /// Raw data worth showing: not empty and not `{}` (checked without parsing).
    static func hasRawContent(_ data: Data) -> Bool {
        let text = data.filter { !(" \n\r\t".utf8.contains($0)) }
        return !text.isEmpty && text != Data("{}".utf8)
    }

    static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              !((object as? [String: Any])?.isEmpty ?? false),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}


extension NSPasteboard {
    /// Copies a string and flags it as concealed/transient so clipboard managers skip it
    /// (nspasteboard.org convention).
    func copyConcealed(_ string: String) {
        clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        declareTypes([.string, concealed, transient], owner: nil)
        setString(string, forType: .string)
        setString("", forType: concealed)
        setString("", forType: transient)
    }
}
