import MFNCore
import SwiftUI

/// A `CategoryRule` being created (from a transaction, ⇧⌘K) or edited (Settings → Kategorien).
struct RuleDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case creditorID, mandateReference, counterpartIBAN, counterpart, purpose
        var id: Self { self }

        var title: String {
            switch self {
            case .creditorID: String(localized: "Gläubiger-ID")
            case .mandateReference: String(localized: "Mandatsreferenz")
            case .counterpartIBAN: String(localized: "IBAN der Gegenpartei")
            case .counterpart: String(localized: "Empfänger/Auftraggeber enthält")
            case .purpose: String(localized: "Verwendungszweck enthält")
            }
        }

        var explanation: String {
            switch self {
            case .creditorID: String(localized: "Alle Lastschriften dieses Gläubigers (genaue Übereinstimmung). Sicherstes Merkmal.")
            case .mandateReference: String(localized: "Nur Lastschriften dieses einen Mandats (genaue Übereinstimmung).")
            case .counterpartIBAN: String(localized: "Alle Umsätze von oder an dieses Konto (Leerzeichen egal).")
            case .counterpart: String(localized: "Name enthält den Text; Groß-/Kleinschreibung und Akzente egal.")
            case .purpose: String(localized: "Verwendungszweck enthält den Text; Groß-/Kleinschreibung und Akzente egal.")
            }
        }

        var isExact: Bool { self == .creditorID || self == .mandateReference || self == .counterpartIBAN }
    }

    /// The rule's ID: new for a new rule, the existing one when editing.
    let id: UUID
    let isNew: Bool
    let createdAt: Date
    var kind: Kind
    var value: String
    var categoryID: CategoryID?
    /// Values from the source transaction, offered when switching the kind.
    let prefills: [Kind: String]

    /// Prefilled with the most specific feature (`CategoryRule.Match.suggested(for:)`: creditor
    /// ID → mandate → IBAN → counterpart without branch numbers → purpose); `prefills` keep the
    /// other features for switching the kind.
    init(transaction: MFNCore.Transaction) {
        id = UUID()
        isNew = true
        createdAt = Date()
        var prefills: [Kind: String] = [:]
        prefills[.creditorID] = transaction.creditorID.flatMap(Self.nonEmpty)
        prefills[.mandateReference] = transaction.mref.flatMap(Self.nonEmpty)
        prefills[.counterpartIBAN] = transaction.counterpartIBAN.flatMap(Self.nonEmpty).map(IBANFormat.grouped)
        prefills[.counterpart] = Self.nonEmpty(transaction.counterpartName)
        prefills[.purpose] = Self.nonEmpty(Self.shortened(transaction.purpose))
        switch CategoryRule.Match.suggested(for: transaction) {
        case let .creditorID(v)?: kind = .creditorID; value = v
        case let .mandateReference(v)?: kind = .mandateReference; value = v
        case let .counterpartIBAN(v)?: kind = .counterpartIBAN; value = IBANFormat.grouped(v)
        case let .counterpart(v)?: kind = .counterpart; value = v
        case let .purpose(v)?: kind = .purpose; value = v
        case nil: kind = .counterpart; value = prefills[.counterpart] ?? ""
        }
        prefills[kind] = value
        self.prefills = prefills
        // A rule mostly confirms what the user sees, or what they just set.
        categoryID = transaction.categoryID
    }

    init(rule: CategoryRule) {
        id = rule.id
        isNew = false
        createdAt = rule.createdAt
        categoryID = rule.categoryID
        switch rule.match {
        case let .creditorID(v): kind = .creditorID; value = v
        case let .mandateReference(v): kind = .mandateReference; value = v
        case let .counterpartIBAN(v): kind = .counterpartIBAN; value = IBANFormat.grouped(v)
        case let .counterpart(v): kind = .counterpart; value = v
        case let .purpose(v): kind = .purpose; value = v
        }
        prefills = [kind: value]
    }

    /// Kinds the picker offers: with a value from the transaction, plus the free-text ones.
    var availableKinds: [Kind] {
        Kind.allCases.filter { !isNew || prefills[$0] != nil || !$0.isExact || $0 == kind }
    }

    /// The rule as it would be saved; `nil` while value or category are missing.
    var rule: CategoryRule? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let categoryID else { return nil }
        let match: CategoryRule.Match = switch kind {
        case .creditorID: .creditorID(trimmed)
        case .mandateReference: .mandateReference(trimmed)
        case .counterpartIBAN: .counterpartIBAN(trimmed.uppercased().filter { !$0.isWhitespace })
        case .counterpart: .counterpart(trimmed)
        case .purpose: .purpose(trimmed)
        }
        return CategoryRule(id: id, match: match, categoryID: categoryID, createdAt: createdAt)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Long purposes as prefill: the first words up to ~40 characters (the user narrows it down).
    static func shortened(_ purpose: String) -> String {
        var result = ""
        for word in purpose.split(whereSeparator: \.isWhitespace) {
            if !result.isEmpty, result.count + word.count + 1 > 40 { break }
            result += (result.isEmpty ? "" : " ") + word
        }
        return result
    }
}

extension CategoryRule.Match {
    /// "Gläubiger-ID DE98ZZZ09999999999", "Name enthält „REWE“".
    var summary: String {
        switch self {
        case let .creditorID(v): String(localized: "Gläubiger-ID \(v)")
        case let .mandateReference(v): String(localized: "Mandat \(v)")
        case let .counterpartIBAN(v): String(localized: "IBAN \(IBANFormat.grouped(v))")
        case let .counterpart(v): String(localized: "Name enthält „\(v)“")
        case let .purpose(v): String(localized: "Zweck enthält „\(v)“")
        }
    }
}

/// Sheet to create or edit a rule. Shows live how many transactions it hits.
struct RuleEditorSheet: View {
    @State var draft: RuleDraft
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        let rule = draft.rule
        let matches = rule.map(model.ruleMatches)
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Merkmal", selection: $draft.kind) {
                        ForEach(draft.availableKinds) { Text($0.title).tag($0) }
                    }
                    TextField(draft.kind.isExact ? "Wert" : "Text", text: $draft.value)
                        .font(draft.kind.isExact ? .body.monospaced() : .body)
                } header: {
                    Text(draft.isNew ? "Neue Regel" : "Regel bearbeiten")
                } footer: {
                    Text(draft.kind.explanation)
                        .foregroundStyle(.secondary)
                }
                Section {
                    CategoryMenuPicker(selection: $draft.categoryID)
                }
                Section("Vorschau") {
                    if let matches {
                        LabeledContent("Trifft") {
                            Text(matches.all.count == 1 ? "1 Umsatz" : "\(matches.all.count) Umsätze")
                                .monospacedDigit()
                        }
                        if matches.manual > 0 {
                            Text("Davon \(matches.manual) manuell kategorisiert – sie bleiben unverändert.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(matches.all.prefix(5)) { transaction in
                            HStack(spacing: 8) {
                                Text(InspectorFormat.shortDate(transaction.effectiveDate))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                Text(transaction.counterpartName)
                                    .lineLimit(1)
                                Spacer()
                                AmountText(cents: transaction.amountCents, currency: transaction.currency, signed: true)
                            }
                        }
                    } else {
                        Text(draft.categoryID == nil ? "Kategorie wählen." : "Wert eingeben.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Abbrechen", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Regel anlegen" : "Sichern") { save(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule == nil || isSaving)
            }
            .padding(16)
        }
        .frame(width: 480, height: 540)
        .onChange(of: draft.kind) { _, kind in
            if let prefill = draft.prefills[kind] { draft.value = prefill }
        }
    }

    private func save(_ rule: CategoryRule?) {
        guard let rule, !isSaving else { return }
        isSaving = true
        Task {
            error = await model.saveRule(rule)
            isSaving = false
            if error == nil { onClose() }
        }
    }
}
