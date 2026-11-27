import Foundation

/// What a CSV column can hold.
public enum CSVField: String, Sendable, Hashable, CaseIterable, Codable {
    case bookingDate
    case valueDate
    /// Signed amount.
    case amount
    /// Outflow as a positive number ("Soll"), together with `credit`.
    case debit
    /// Inflow as a positive number ("Haben"), together with `debit`.
    case credit
    /// "S"/"H" (Soll/Haben) next to an unsigned `amount`.
    case debitCreditMark
    case counterparty
    /// Payer and payee in separate columns (DKB): the counterparty is the payee of an outflow
    /// and the payer of an inflow.
    case payer
    case payee
    case counterpartIBAN
    case purpose
    /// "Lastschrift", "Gutschrift" … (kept in `rawJSON`, counterparty fallback).
    case bookingText
    case currency
    case status
    case creditorID
    case mandateReference
    case endToEndReference
    case originalAmount
    case originalCurrency
    /// Account column of a multi-account export (MFN's own): only rows of one account are imported.
    case account
    /// MFN's `CategoryID` (own export), preferred over `categoryName`.
    case categoryID
    /// Category title as `CategoryCatalog.title` writes it.
    case categoryName

    public var title: String {
        switch self {
        case .bookingDate: String(localized: "Buchungstag", bundle: .module)
        case .valueDate: String(localized: "Wertstellung", bundle: .module)
        case .amount: String(localized: "Betrag", bundle: .module)
        case .debit: String(localized: "Soll (Ausgang)", bundle: .module)
        case .credit: String(localized: "Haben (Eingang)", bundle: .module)
        case .debitCreditMark: String(localized: "Soll/Haben-Kennzeichen", bundle: .module)
        case .counterparty: String(localized: "Gegenpartei", bundle: .module)
        case .payer: String(localized: "Zahlungspflichtige*r", bundle: .module)
        case .payee: String(localized: "Zahlungsempfänger*in", bundle: .module)
        case .counterpartIBAN: String(localized: "IBAN Gegenkonto", bundle: .module)
        case .purpose: String(localized: "Verwendungszweck", bundle: .module)
        case .bookingText: String(localized: "Buchungstext", bundle: .module)
        case .currency: String(localized: "Währung", bundle: .module)
        case .status: String(localized: "Status", bundle: .module)
        case .creditorID: String(localized: "Gläubiger-ID", bundle: .module)
        case .mandateReference: String(localized: "Mandatsreferenz", bundle: .module)
        case .endToEndReference: String(localized: "Kundenreferenz", bundle: .module)
        case .originalAmount: String(localized: "Betrag in Fremdwährung", bundle: .module)
        case .originalCurrency: String(localized: "Fremdwährung", bundle: .module)
        case .account: String(localized: "Konto", bundle: .module)
        case .categoryID: String(localized: "Kategorie-ID", bundle: .module)
        case .categoryName: String(localized: "Kategorie", bundle: .module)
        }
    }

    /// Generic header names, in priority order. Matched by `CSVLayout.key` (case, diacritics,
    /// punctuation and spaces ignored).
    var aliases: [String] {
        switch self {
        case .bookingDate: ["Buchungstag", "Buchungsdatum", "Buchung", "Booking Date", "Datum", "Date", "Buchungs-Datum"]
        case .valueDate: ["Wertstellung", "Wertstellungsdatum", "Valuta", "Valutadatum", "Value Date", "Wertstellungstag"]
        case .amount: ["Betrag", "Betrag (EUR)", "Betrag (€)", "Betrag in EUR", "Amount (EUR)", "Amount", "Umsatz", "Umsatz in EUR"]
        case .debit: ["Soll", "Soll (EUR)", "Ausgang", "Ausgaben", "Belastung", "Debit"]
        case .credit: ["Haben", "Haben (EUR)", "Eingang", "Einnahmen", "Credit"]
        case .debitCreditMark: ["Soll/Haben", "S/H", "Soll-Haben-Kennzeichen"]
        case .counterparty: ["Gegenpartei/Name", "Gegenpartei", "Name", "Auftraggeber/Empfänger", "Auftraggeber / Begünstigter",
                             "Begünstigter/Zahlungspflichtiger", "Beguenstigter/Zahlungspflichtiger", "Name Zahlungsbeteiligter",
                             "Partner Name", "Händler", "Empfänger/Auftraggeber"]
        case .payer: ["Zahlungspflichtige*r", "Zahlungspflichtiger", "Zahler"]
        case .payee: ["Zahlungsempfänger*in", "Zahlungsempfänger", "Empfänger"]
        case .counterpartIBAN: ["IBAN Gegenkonto", "Gegenkonto IBAN", "IBAN Zahlungsbeteiligter", "Partner Iban", "IBAN",
                                "Kontonummer/IBAN", "Kontonummer"]
        case .purpose: ["Verwendungszweck", "Payment Reference", "Zweck", "Beschreibung", "Buchungsdetails", "Description"]
        case .bookingText: ["Buchungstext", "Umsatztyp", "Transaktionstyp", "Umsatzart", "Type"]
        case .currency: ["Währung", "Waehrung", "Currency"]
        case .status: ["Status", "Umsatzstatus"]
        case .creditorID: ["Gläubiger-ID", "Gläubiger ID", "Glaeubiger-ID", "Gläubiger-Identifikation", "Creditor ID"]
        case .mandateReference: ["Mandatsreferenz", "Mandate Reference"]
        case .endToEndReference: ["Ende-zu-Ende-Referenz", "Kundenreferenz", "Kundenreferenz (End-to-End)", "End-to-End-Referenz", "EREF"]
        case .originalAmount: ["Original Amount", "Betrag (Fremdwährung)", "Originalbetrag", "Betrag in Fremdwährung"]
        case .originalCurrency: ["Original Currency", "Fremdwährung", "Originalwährung"]
        case .account: ["Konto", "Account Name", "Kontoname"]
        case .categoryID: ["Kategorie-ID"]
        case .categoryName: ["Kategorie"]
        }
    }

    /// Assignment order: specific fields first, so a generic alias cannot take their column
    /// (payee before counterparty for "Empfänger", amount before original amount).
    static let matchingOrder: [CSVField] = [
        .bookingDate, .valueDate, .amount, .debit, .credit, .debitCreditMark, .originalAmount, .originalCurrency,
        .payer, .payee, .counterparty, .counterpartIBAN, .purpose, .bookingText, .currency, .status,
        .creditorID, .mandateReference, .endToEndReference, .account, .categoryID, .categoryName,
    ]

    /// Fields offered for manual mapping in the preview, in display order.
    public static let mappable: [CSVField] = [
        .bookingDate, .valueDate, .amount, .debit, .credit, .counterparty, .purpose, .counterpartIBAN, .currency,
    ]
}

/// Which column holds which field (column indexes of `CSVTable.rows`).
public struct CSVMapping: Sendable, Hashable {
    public var columns: [CSVField: Int]

    public init(_ columns: [CSVField: Int] = [:]) {
        self.columns = columns
    }

    public subscript(field: CSVField) -> Int? {
        get { columns[field] }
        set { columns[field] = newValue }
    }

    /// A booking date and either a signed amount or debit/credit columns.
    public var isComplete: Bool {
        columns[.bookingDate] != nil && (columns[.amount] != nil || columns[.debit] != nil || columns[.credit] != nil)
    }

    /// The field mapped to `column`, if any.
    public func field(at column: Int) -> CSVField? {
        columns.first { $0.value == column }?.key
    }
}

/// A known export layout. Presets only add aliases and a signature on top of the generic
/// matching; whatever they do not name is matched generically.
public struct CSVPreset: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Checked against a real export of the bank. Unverified presets come from public
    /// documentation and user reports; the preview says so.
    public let verified: Bool
    /// Headers that must all be present (by `CSVLayout.key`) for the preset to be detected.
    let signature: [String]
    /// Preferred header names per field, before the generic aliases.
    let aliases: [CSVField: [String]]
    /// Text cells starting with `'` + one of `= + - @ tab CR` lose the `'` (spreadsheet formula guard).
    let stripsFormulaQuote: Bool

    init(id: String, name: String, verified: Bool, signature: [String], aliases: [CSVField: [String]], stripsFormulaQuote: Bool = false) {
        self.id = id
        self.name = name
        self.verified = verified
        self.signature = signature
        self.aliases = aliases
        self.stripsFormulaQuote = stripsFormulaQuote
    }

    public var displayName: String { verified ? name : String(localized: "\(name) (ungeprüft)", bundle: .module) }

    /// MFN's own CSV export (⇧⌘E, `TransactionCSVExporter`): UTF-8 BOM, `;`, `dd.MM.yyyy`,
    /// `-1234,56`, status `gebucht`/`vorgemerkt`/`geplant`/`storniert`, text fields with a leading
    /// `'` against formula injection. Header text may vary slightly; matched tolerantly.
    /// Verified against the exporter's format description, not yet against a file from the app.
    public static let mfn = CSVPreset(
        id: "mfn", name: "MoneyForNothing-Export", verified: false,
        signature: ["Buchungstag", "Betrag", "Kategorie", "Konto"],
        aliases: [
            .counterparty: ["Gegenpartei/Name", "Gegenpartei", "Name"],
            .counterpartIBAN: ["IBAN Gegenkonto"],
            .endToEndReference: ["Ende-zu-Ende-Referenz"],
        ],
        stripsFormulaQuote: true
    )

    /// ING "Umsatzanzeige" (Windows-1252, metadata block above the header, two "Währung" columns).
    public static let ing = CSVPreset(
        id: "ing", name: "ING", verified: false,
        signature: ["Buchung", "Auftraggeber/Empfänger", "Buchungstext", "Betrag"],
        aliases: [
            .bookingDate: ["Buchung"],
            .valueDate: ["Wertstellungsdatum", "Valuta"],
            .counterparty: ["Auftraggeber/Empfänger"],
        ]
    )

    /// DKB web banking since 2023 (`dd.MM.yy`, payer and payee columns, status column).
    public static let dkb = CSVPreset(
        id: "dkb", name: "DKB", verified: false,
        signature: ["Buchungsdatum", "Zahlungsempfänger*in", "Betrag (€)"],
        aliases: [
            .bookingDate: ["Buchungsdatum"],
            .payer: ["Zahlungspflichtige*r"],
            .payee: ["Zahlungsempfänger*in"],
            .amount: ["Betrag (€)"],
            .bookingText: ["Umsatztyp"],
        ]
    )

    /// DKB web banking before 2023.
    public static let dkbLegacy = CSVPreset(
        id: "dkb-legacy", name: "DKB (bis 2023)", verified: false,
        signature: ["Buchungstag", "Auftraggeber / Begünstigter", "Betrag (EUR)"],
        aliases: [
            .counterparty: ["Auftraggeber / Begünstigter"],
            .amount: ["Betrag (EUR)"],
        ]
    )

    /// N26 (comma-separated, `yyyy-MM-dd`, decimal point).
    public static let n26 = CSVPreset(
        id: "n26", name: "N26", verified: false,
        signature: ["Booking Date", "Partner Name", "Amount (EUR)"],
        aliases: [
            .counterparty: ["Partner Name"],
            .counterpartIBAN: ["Partner Iban"],
            .purpose: ["Payment Reference"],
            .amount: ["Amount (EUR)"],
        ]
    )

    /// N26 before 2023.
    public static let n26Legacy = CSVPreset(
        id: "n26-legacy", name: String(localized: "N26 (älteres Format)", bundle: .module), verified: false,
        signature: ["Datum", "Empfänger", "Transaktionstyp", "Betrag (EUR)"],
        aliases: [
            .counterparty: ["Empfänger"],
            .amount: ["Betrag (EUR)"],
            .originalAmount: ["Betrag (Fremdwährung)"],
            .originalCurrency: ["Fremdwährung"],
        ]
    )

    /// Most specific first (more signature headers win).
    public static let all: [CSVPreset] = [.mfn, .dkb, .dkbLegacy, .ing, .n26, .n26Legacy]
}

/// Header detection and column matching.
public enum CSVLayout {
    /// Rows above the header that are searched (bank metadata blocks are 5–15 lines).
    public static let maxPreambleRows = 40

    /// Header comparison key: case, diacritics, punctuation and spaces ignored.
    public static func key(_ header: String) -> String {
        header.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Detected header row, preset and mapping. Without a header the mapping is empty and the
    /// user maps columns by position.
    public struct Detection: Sendable, Hashable {
        public var headerRow: Int?
        public var preset: CSVPreset?
        public var mapping: CSVMapping
    }

    public static func detect(in rows: [[String]]) -> Detection {
        for (index, row) in rows.prefix(maxPreambleRows + 1).enumerated() {
            let keys = row.map(key)
            let keySet = Set(keys)
            let preset = CSVPreset.all.first { preset in preset.signature.allSatisfy { keySet.contains(key($0)) } }
            let mapping = match(header: row, preset: preset)
            if mapping.isComplete, preset != nil || looksLikeHeader(row, mapping: mapping) {
                return Detection(headerRow: index, preset: preset, mapping: mapping)
            }
        }
        return Detection(headerRow: nil, preset: nil, mapping: CSVMapping())
    }

    /// A data row can contain a word like "Datum" by chance; a header has no parsable dates.
    static func looksLikeHeader(_ row: [String], mapping: CSVMapping) -> Bool {
        !row.contains { CSVValues.day($0) != nil }
    }

    /// Columns for `header`: preset aliases first, then generic ones. Exact key matches win;
    /// a header may also carry a short suffix ("Betrag (EUR)" for "Betrag", at most 3 characters).
    public static func match(header: [String], preset: CSVPreset? = nil) -> CSVMapping {
        let keys = header.map(key)
        var used: Set<Int> = []
        var mapping = CSVMapping()

        func candidates(for alias: String) -> [Int] {
            let aliasKey = key(alias)
            guard !aliasKey.isEmpty else { return [] }
            let exact = keys.indices.filter { !used.contains($0) && keys[$0] == aliasKey }
            if !exact.isEmpty { return exact }
            return keys.indices.filter {
                !used.contains($0) && keys[$0].hasPrefix(aliasKey) && keys[$0].count - aliasKey.count <= 3
            }
        }

        // Preset aliases for all fields first, so the generic aliases of an earlier field cannot
        // take a column the preset assigns to a later one.
        let passes: [(CSVField) -> [String]] = [{ preset?.aliases[$0] ?? [] }, { $0.aliases }]
        for aliases in passes {
            for field in CSVField.matchingOrder where mapping[field] == nil {
                for alias in aliases(field) {
                    let found = candidates(for: alias)
                    guard var column = found.first else { continue }
                    // Two "Währung" columns (ING: balance and amount): take the one next to the amount.
                    if field == .currency, found.count > 1, let amount = mapping[.amount] {
                        column = found.min { abs($0 - amount - 1) < abs($1 - amount - 1) } ?? column
                    }
                    mapping[field] = column
                    used.insert(column)
                    break
                }
            }
        }
        // Soll/Haben columns only make sense as a pair or without a signed amount.
        if mapping[.amount] != nil {
            mapping[.debit] = nil
            mapping[.credit] = nil
        }
        return mapping
    }
}
