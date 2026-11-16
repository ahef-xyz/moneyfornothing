import Foundation

/// A CSV file read and analysed for import: table, detected header, preset and mapping.
///
/// Flow: `CSVDocument(data:)` → (user adjusts `mapping`) → `transactions(for:)` →
/// `CSVImportPlan.make` against the stored transactions → `CSVImportPlan.merge` → `LedgerStore.apply`.
public struct CSVDocument: Sendable, Hashable {
    public var table: CSVTable
    /// Index into `table.rows`; `nil` = no header found, columns are mapped by position.
    public var headerRow: Int?
    public var preset: CSVPreset?
    public var mapping: CSVMapping
    public var decimalSeparator: CSVDecimalSeparator
    /// With an `.account` column: only rows whose account cell equals this are imported.
    public var accountFilter: String?

    /// `delimiter`: `nil` detects it.
    public init(data: Data, delimiter: CSVDelimiter? = nil) throws(CSVImportError) {
        let table = try CSVParser.parse(data, delimiter: delimiter)
        let detection = CSVLayout.detect(in: table.rows)
        self.table = table
        self.headerRow = detection.headerRow
        self.preset = detection.preset
        self.mapping = detection.mapping
        self.decimalSeparator = .comma
        self.accountFilter = nil
        self.decimalSeparator = detectDecimalSeparator()
        self.accountFilter = accountValues.count > 1 ? accountValues.first : nil
    }

    /// Rows after the header (all rows without one).
    public var dataRows: ArraySlice<[String]> {
        table.rows.dropFirst((headerRow ?? -1) + 1)
    }

    /// Number of columns of the widest row.
    public var columnCount: Int {
        table.rows.map(\.count).max() ?? 0
    }

    /// Column titles: the header cell, else "Spalte n".
    public var columnNames: [String] {
        let header = headerRow.map { table.rows[$0] } ?? []
        return (0..<columnCount).map { index in
            index < header.count && !header[index].isEmpty ? header[index] : "Spalte \(index + 1)"
        }
    }

    /// Distinct values of the account column, in file order (MFN multi-account export).
    public var accountValues: [String] {
        guard let column = mapping[.account] else { return [] }
        var seen: Set<String> = []
        return dataRows.compactMap { row in
            guard column < row.count, !row[column].isEmpty, seen.insert(row[column]).inserted else { return nil }
            return row[column]
        }
    }

    /// Re-detects the decimal separator from the amount columns of the current mapping.
    public func detectDecimalSeparator() -> CSVDecimalSeparator {
        let columns = [CSVField.amount, .debit, .credit].compactMap { mapping[$0] }
        let samples = dataRows.prefix(200).flatMap { row in columns.compactMap { $0 < row.count ? row[$0] : nil } }
        return CSVValues.detectDecimalSeparator(samples)
    }

    /// Parses the data rows into booked transactions of `account`.
    ///
    /// - Rows without date and amount (footers, separators, "Saldo" lines) are skipped silently.
    /// - Unreadable dates or amounts, pending/cancelled rows (status column) and rows of other
    ///   accounts are skipped and reported with their line number only, never their content.
    /// - IDs come from the fingerprint (no external ID), made unique within the file, so a
    ///   re-import of the same file yields the same IDs.
    /// - `importID`: the batch the rows will belong to (`ImportBatch`, v10); `nil` for previews.
    public func transactions(for account: Account, importID: ImportBatchID? = nil) -> CSVParseResult {
        var result = CSVParseResult()
        guard mapping.isComplete else { return result }
        let header = columnNames
        let firstRow = (headerRow ?? -1) + 1
        var transactions: [Transaction] = []

        for (offset, row) in dataRows.enumerated() {
            let line = table.lines[firstRow + offset]
            let strips = preset?.stripsFormulaQuote == true
            func cell(_ field: CSVField) -> String? {
                guard let index = mapping[field], index < row.count else { return nil }
                let value = strips ? Self.unquotedFormula(row[index]) : row[index]
                return value.isEmpty ? nil : value
            }
            let dateText = cell(.bookingDate)
            let amountText = cell(.amount) ?? cell(.debit) ?? cell(.credit)
            guard dateText != nil || amountText != nil else { continue }
            // Footer lines ("Summe", "Saldo", "Kontostand") carry text, not a date, in the date column.
            if let dateText, !dateText.contains(where: \.isNumber) { continue }
            // A repeated header line (some exports repeat it per page).
            if let dateText, CSVLayout.key(dateText) == CSVLayout.key(header[mapping[.bookingDate] ?? 0]) { continue }

            if let filter = accountFilter, mapping[.account] != nil, cell(.account) != filter {
                result.skipped.append(.init(line: line, reason: .otherAccount))
                continue
            }
            // Before the date: pending and planned rows have no booking day.
            if let status = cell(.status), let reason = Self.skipReason(status: status) {
                result.skipped.append(.init(line: line, reason: reason))
                continue
            }
            guard let dateText, let bookingDate = CSVValues.day(dateText) else {
                result.skipped.append(.init(line: line, reason: .unreadableDate))
                continue
            }
            guard let amount = amountCents(cell) else {
                result.skipped.append(.init(line: line, reason: .unreadableAmount))
                continue
            }
            let valueDate = cell(.valueDate).flatMap(CSVValues.day) ?? bookingDate

            let purpose = cell(.purpose) ?? ""
            var counterparty = cell(.counterparty)
                ?? (amount < 0 ? cell(.payee) ?? cell(.payer) : cell(.payer) ?? cell(.payee))
                ?? ""
            if counterparty.isEmpty, purpose.isEmpty { counterparty = cell(.bookingText) ?? "" }

            let iban = cell(.counterpartIBAN).map { Fingerprint.normalize(iban: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            let currency = cell(.currency).flatMap(CSVValues.currencyCode) ?? account.currency
            let originalAmount = cell(.originalAmount).flatMap { CSVValues.cents($0, decimal: decimalSeparator) }
            let originalCurrency = cell(.originalCurrency).flatMap(CSVValues.currencyCode)
                ?? cell(.originalAmount).flatMap(CSVValues.currencyCode)

            var transaction = Transaction(
                accountID: account.id,
                bookingDate: bookingDate,
                valueDate: valueDate,
                amountCents: amount,
                currency: currency,
                counterpartName: counterparty,
                counterpartIBAN: iban,
                purpose: purpose,
                eref: cell(.endToEndReference),
                mref: cell(.mandateReference),
                creditorID: cell(.creditorID),
                // Imported rows are booked: exports list bookings, the status column filtered the rest.
                status: .booked,
                externalID: nil,
                originalAmountCents: originalAmount == amount ? nil : originalAmount,
                originalCurrency: originalAmount == nil || originalAmount == amount ? nil : originalCurrency,
                rawJSON: Self.rawJSON(header: header, row: row, format: preset?.id),
                importID: importID
            )
            if let category = Self.category(id: cell(.categoryID), name: cell(.categoryName)) {
                // Restored from MFN's own export: the user's category, kept like a manual one.
                transaction.categoryID = category
                transaction.categorySource = .manual
            }
            transactions.append(transaction)
        }
        result.transactions = Transaction.uniquingIDs(transactions)
        return result
    }

    private func amountCents(_ cell: (CSVField) -> String?) -> Int? {
        let decimal = decimalSeparator
        if mapping[.amount] != nil {
            guard let text = cell(.amount), var cents = CSVValues.cents(text, decimal: decimal) else { return nil }
            if let mark = cell(.debitCreditMark) {
                switch CSVLayout.key(mark) {
                case "s", "soll", "d", "debit", "lastschrift": cents = -abs(cents)
                case "h", "haben", "c", "credit", "gutschrift": cents = abs(cents)
                default: return nil
                }
            }
            return cents
        }
        // Soll/Haben: both unsigned (some banks sign the debit column anyway).
        let debit = cell(.debit).map { CSVValues.cents($0, decimal: decimal) }
        let credit = cell(.credit).map { CSVValues.cents($0, decimal: decimal) }
        if case .some(nil) = debit { return nil }
        if case .some(nil) = credit { return nil }
        let out = abs(debit.flatMap { $0 } ?? 0)
        let into = abs(credit.flatMap { $0 } ?? 0)
        guard debit != nil || credit != nil else { return nil }
        return into - out
    }

    /// A catalog category by ID, else by title; `nil` for unknown ones (other apps' categories).
    static func category(id: String?, name: String?) -> CategoryID? {
        if let id, CategoryCatalog.info(CategoryID(id)) != nil { return CategoryID(id) }
        guard let name else { return nil }
        let wanted = CSVLayout.key(name)
        return CategoryCatalog.all.first { CSVLayout.key($0.title) == wanted }?.id
    }

    /// Drops the `'` a spreadsheet-safe export puts before `= + - @ tab CR`.
    static func unquotedFormula(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count >= 2, scalars.first == "'",
              let next = scalars.dropFirst().first, ["=", "+", "-", "@", "\t", "\r"].contains(next) else { return value }
        return String(scalars.dropFirst())
    }

    /// `nil` = import as booked (booked, empty or unknown status).
    static func skipReason(status: String) -> CSVSkippedRow.Reason? {
        switch CSVLayout.key(status) {
        case "vorgemerkt", "pending", "offen", "inbearbeitung", "nichtgebucht", "autorisiert", "reserviert", "vormerkung":
            .notBooked
        case "geplant", "planned", "terminiert":
            .notBooked
        case "storniert", "cancelled", "canceled", "abgelehnt", "zuruckgewiesen":
            .cancelled
        default:
            nil
        }
    }

    /// `{"source":"csv","format":<preset>,"row":{header: cell}}` with stable key order.
    static func rawJSON(header: [String], row: [String], format: String?) -> Data {
        var cells: [String: String] = [:]
        for (index, value) in row.enumerated() {
            var name = index < header.count ? header[index] : "Spalte \(index + 1)"
            if cells[name] != nil { name += " (\(index + 1))" }
            cells[name] = value
        }
        var object: [String: Any] = ["source": "csv", "row": cells]
        if let format { object["format"] = format }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

public struct CSVSkippedRow: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case unreadableDate
        case unreadableAmount
        /// Pending or planned per status column.
        case notBooked
        case cancelled
        /// Another account of a multi-account export.
        case otherAccount

        public var title: String {
            switch self {
            case .unreadableDate: "Datum nicht lesbar"
            case .unreadableAmount: "Betrag nicht lesbar"
            case .notBooked: "noch nicht gebucht"
            case .cancelled: "storniert"
            case .otherAccount: "anderes Konto"
            }
        }

        /// Problems with the file (shown as warning), not deliberate filtering.
        public var isProblem: Bool { self == .unreadableDate || self == .unreadableAmount }
    }

    /// 1-based line in the file.
    public var line: Int
    public var reason: Reason

    public init(line: Int, reason: Reason) {
        self.line = line
        self.reason = reason
    }
}

public struct CSVParseResult: Sendable, Hashable {
    public var transactions: [Transaction] = []
    public var skipped: [CSVSkippedRow] = []

    public init(transactions: [Transaction] = [], skipped: [CSVSkippedRow] = []) {
        self.transactions = transactions
        self.skipped = skipped
    }
}
