import Foundation
import MFNCore

/// Which CSV columns hold what, by header name.
///
/// Headers are matched case-, diacritic- and punctuation-insensitively against the aliases.
///
/// **Provisional:** `Fixtures/Easybank/export.csv` does not exist yet (STATUS.md), so `standard`
/// lists common German card-export headers and is unverified against a real easybank export.
/// It must be checked and narrowed once the fixture is there. Missing required columns always
/// throw `formatChanged`, so an unknown layout can never import silently wrong data.
public struct EasybankCSVLayout: Hashable, Sendable {
    public var bookingDate: [String]
    public var transactionDate: [String]
    public var amount: [String]
    public var currency: [String]
    public var merchant: [String]
    public var details: [String]
    public var originalAmount: [String]
    public var originalCurrency: [String]
    public var status: [String]

    public init(
        bookingDate: [String], transactionDate: [String], amount: [String], currency: [String] = [],
        merchant: [String], details: [String] = [], originalAmount: [String] = [], originalCurrency: [String] = [],
        status: [String] = []
    ) {
        self.bookingDate = bookingDate
        self.transactionDate = transactionDate
        self.amount = amount
        self.currency = currency
        self.merchant = merchant
        self.details = details
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.status = status
    }

    public static let standard = EasybankCSVLayout(
        bookingDate: ["Buchungsdatum", "Buchungstag", "Buchung"],
        transactionDate: ["Transaktionsdatum", "Belegdatum", "Umsatzdatum", "Kaufdatum", "Datum"],
        amount: ["Betrag", "Betrag (EUR)", "Betrag in EUR", "Umsatz"],
        currency: ["Währung", "Waehrung"],
        merchant: ["Händler", "Haendler", "Beschreibung", "Empfänger", "Verwendungszweck"],
        details: ["Details", "Zusatzinformation", "Ort"],
        originalAmount: ["Originalbetrag", "Betrag in Fremdwährung", "Fremdwährungsbetrag"],
        originalCurrency: ["Originalwährung", "Fremdwährung"],
        status: ["Status", "Umsatzstatus"]
    )
}

/// Imports the transaction export of the easybank app/web banking (CLAUDE.md §7: mandatory
/// fallback in case the web-banking connector breaks).
///
/// Produces the same `Transaction`s as the connector (shared `EasybankTransactionBuilder`), so
/// a CSV import and a later sync deduplicate via fingerprint/ID instead of doubling.
public struct EasybankCSVImporter: Sendable {
    public var layout: EasybankCSVLayout
    /// How many leading rows may precede the header (export preamble).
    public var maxPreambleRows: Int

    public init(layout: EasybankCSVLayout = .standard, maxPreambleRows: Int = 20) {
        self.layout = layout
        self.maxPreambleRows = maxPreambleRows
    }

    /// Parses `data` into transactions of `account`.
    ///
    /// - Partner cards book into the same card account (web API: one account per credit line),
    ///   so rows of all cards are imported; the card number stays in `rawJSON`.
    /// - Throws `formatChanged` (column name or row number, never cell values) for unknown layouts,
    ///   unparsable amounts/dates or unknown status values.
    public func transactions(from data: Data, account: Account) throws(ConnectorError) -> [Transaction] {
        let rows = try CSVReader.rows(from: data)
        let columns = try locateHeader(in: rows)
        var result: [Transaction] = []

        for (offset, row) in rows.dropFirst(columns.headerRow + 1).enumerated() {
            let line = columns.headerRow + offset + 2 // 1-based, header line counted
            func cell(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let value = row[index]
                return value.isEmpty ? nil : value
            }
            // Footer lines ("Summe", "Saldo …") and separators carry no amount or no date.
            guard row.count > 1, let amountText = cell(columns.amount),
                  cell(columns.bookingDate) != nil || cell(columns.transactionDate) != nil else { continue }

            guard let amount = GermanFormats.cents(amountText) else {
                throw .formatChanged(detail: "CSV Zeile \(line): Betrag nicht lesbar")
            }
            let bookingDate: BankDay?
            if let text = cell(columns.bookingDate) {
                guard let day = GermanFormats.day(text) else { throw .formatChanged(detail: "CSV Zeile \(line): Buchungsdatum nicht lesbar") }
                bookingDate = day
            } else {
                bookingDate = nil
            }
            let transactionDate: BankDay
            if let text = cell(columns.transactionDate) {
                guard let day = GermanFormats.day(text) else { throw .formatChanged(detail: "CSV Zeile \(line): Transaktionsdatum nicht lesbar") }
                transactionDate = day
            } else if let bookingDate {
                transactionDate = bookingDate
            } else {
                throw .formatChanged(detail: "CSV Zeile \(line): kein Datum")
            }

            let status: TransactionStatus
            if let text = cell(columns.status) {
                guard let parsed = Self.status(text) else { throw .formatChanged(detail: "CSV Zeile \(line): Status unbekannt") }
                status = parsed
            } else {
                // Without a status column, a missing booking date means "not yet booked".
                status = bookingDate == nil ? .pending : .booked
            }

            let merchant = cell(columns.merchant) ?? ""
            let details = cell(columns.details)
            guard !merchant.isEmpty || details != nil else {
                throw .formatChanged(detail: "CSV Zeile \(line): Händler/Beschreibung fehlt")
            }

            let originalAmount = cell(columns.originalAmount).flatMap(GermanFormats.cents)
            var originalCurrency = cell(columns.originalCurrency)
            // Some exports put the currency into the amount cell ("12,00 USD").
            if originalCurrency == nil, let text = cell(columns.originalAmount) {
                originalCurrency = Self.currencyCode(in: text)
            }

            result.append(EasybankTransactionBuilder.make(.init(
                accountID: account.id,
                status: status,
                bookingDate: bookingDate,
                transactionDate: transactionDate,
                amountCents: amount,
                currency: cell(columns.currency).flatMap(Self.currencyCode(in:)) ?? account.currency,
                merchant: merchant.isEmpty ? (details ?? "") : merchant,
                details: merchant.isEmpty ? nil : details,
                originalAmountCents: originalAmount,
                originalCurrency: originalCurrency,
                // No externalID: the ID must be the fingerprint so that CSV import and web sync
                // of the same booking collide instead of doubling. References stay in rawJSON.
                externalID: nil,
                rawJSON: Self.rawJSON(header: columns.names, row: row)
            )))
        }
        return Transaction.uniquingIDs(result)
    }

    // MARK: - Header

    struct Columns {
        var headerRow: Int
        var names: [String]
        var bookingDate: Int?
        var transactionDate: Int?
        var amount: Int?
        var currency: Int?
        var merchant: Int?
        var details: Int?
        var originalAmount: Int?
        var originalCurrency: Int?
        var status: Int?
    }

    func locateHeader(in rows: [[String]]) throws(ConnectorError) -> Columns {
        for (index, row) in rows.prefix(maxPreambleRows + 1).enumerated() {
            let keys = row.map(Self.key)
            func find(_ aliases: [String]) -> Int? {
                // Alias order is priority order.
                for alias in aliases.map(Self.key) {
                    if let position = keys.firstIndex(of: alias) { return position }
                }
                return nil
            }
            let columns = Columns(
                headerRow: index, names: row,
                bookingDate: find(layout.bookingDate), transactionDate: find(layout.transactionDate),
                amount: find(layout.amount), currency: find(layout.currency),
                merchant: find(layout.merchant), details: find(layout.details),
                originalAmount: find(layout.originalAmount), originalCurrency: find(layout.originalCurrency),
                status: find(layout.status)
            )
            let hasDate = columns.bookingDate != nil || columns.transactionDate != nil
            let hasText = columns.merchant != nil || columns.details != nil
            if columns.amount != nil, hasDate, hasText { return columns }
        }
        throw .formatChanged(detail: "CSV: Kopfzeile nicht erkannt (Betrag, Datum oder Händler fehlt)")
    }

    static func key(_ header: String) -> String {
        header.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Values

    static func status(_ text: String) -> TransactionStatus? {
        switch key(text) {
        case "gebucht", "booked", "abgerechnet", "verbucht": .booked
        case "vorgemerkt", "pending", "offen", "inbearbeitung", "nichtgebucht", "autorisiert", "reserviert": .pending
        case "storniert", "cancelled", "canceled", "abgelehnt", "zuruckgewiesen": .cancelled
        default: nil
        }
    }

    static func currencyCode(in text: String) -> String? {
        let letters = text.filter(\.isLetter).uppercased()
        if letters == "EUR" || text.contains("€") { return "EUR" }
        return letters.count == 3 && letters.allSatisfy(\.isASCII) ? letters : nil
    }

    /// The CSV row as a JSON object `{header: cell}` with stable key order.
    static func rawJSON(header: [String], row: [String]) -> Data {
        var object: [String: String] = [:]
        for (index, value) in row.enumerated() {
            let name = index < header.count && !header[index].isEmpty ? header[index] : "column\(index + 1)"
            object[name] = value
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
