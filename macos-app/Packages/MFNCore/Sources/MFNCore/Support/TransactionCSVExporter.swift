import Foundation

/// Transactions as a CSV file for German Excel and Numbers ("Umsätze als CSV exportieren …", ⇧⌘E).
///
/// Format (stable, MFN's own CSV import relies on it):
/// - UTF-8 with byte order mark (`EF BB BF`), so Excel does not read it as Windows-1252.
/// - Separator `;`, line ending CRLF, header row first, one row per transaction.
/// - Fields are quoted (RFC 4180) when they contain `;`, `"`, CR or LF, or start or end with a
///   space; quotes inside are doubled. Line breaks in a purpose are kept inside the quotes.
/// - Dates `dd.MM.yyyy`, empty when unknown (pending and planned transactions have no booking day).
/// - Amounts in the account currency, sign first, decimal comma, no thousands separator:
///   `-1234,56`, `0,05`, `1500,00`.
/// - Text fields that start with `=`, `+`, `-`, `@`, tab or CR get a leading `'`, so a spreadsheet
///   does not run them as a formula (CSV injection). An importer drops a leading `'` when the
///   next character is one of these.
///
/// Columns, in this order (`columns`):
///
/// | # | Header | Content |
/// | --- | --- | --- |
/// | 1 | `Buchungstag` | `bookingDate`, empty for pending/planned |
/// | 2 | `Wertstellung` | `valueDate` |
/// | 3 | `Status` | `gebucht`, `vorgemerkt`, `geplant`, `storniert` |
/// | 4 | `Gegenpartei` | `counterpartName` |
/// | 5 | `IBAN Gegenkonto` | `counterpartIBAN` |
/// | 6 | `Verwendungszweck` | `purpose` |
/// | 7 | `Betrag` | `amountCents` |
/// | 8 | `Währung` | `currency` |
/// | 9 | `Kategorie` | catalog title of `categoryID` (`CategoryCatalog.title`), empty if none |
/// | 10 | `Konto` | account name as shown in the app ("Bank Konto") |
/// | 11 | `IBAN Konto` | IBAN of the account, empty if it has none |
/// | 12 | `Ende-zu-Ende-Referenz` | `eref` |
/// | 13 | `Mandatsreferenz` | `mref` |
/// | 14 | `Gläubiger-ID` | `creditorID` |
/// | 15 | `Originalbetrag` | `originalAmountCents` (foreign-currency card payments) |
/// | 16 | `Originalwährung` | `originalCurrency` |
/// | 17 | `Kategorie-ID` | stable `categoryID.rawValue` (survives renamed titles), empty if none |
///
/// New columns are only ever added at the end; existing ones are never renamed or reordered.
public enum TransactionCSVExporter {
    public static let columns: [String] = [
        "Buchungstag", "Wertstellung", "Status", "Gegenpartei", "IBAN Gegenkonto", "Verwendungszweck",
        "Betrag", "Währung", "Kategorie", "Konto", "IBAN Konto", "Ende-zu-Ende-Referenz",
        "Mandatsreferenz", "Gläubiger-ID", "Originalbetrag", "Originalwährung", "Kategorie-ID",
    ]

    public static let separator: Character = ";"
    public static let lineEnding = "\r\n"
    public static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The file: byte order mark + `text(…)` as UTF-8.
    public static func data(
        _ transactions: [Transaction],
        accountName: (AccountID) -> String,
        accountIBAN: (AccountID) -> String? = { _ in nil },
        categoryTitle: (CategoryID) -> String = CategoryCatalog.title
    ) -> Data {
        var data = Data(byteOrderMark)
        data.append(Data(text(transactions, accountName: accountName, accountIBAN: accountIBAN, categoryTitle: categoryTitle).utf8))
        return data
    }

    /// Header and rows, each line ending in CRLF; no byte order mark.
    public static func text(
        _ transactions: [Transaction],
        accountName: (AccountID) -> String,
        accountIBAN: (AccountID) -> String? = { _ in nil },
        categoryTitle: (CategoryID) -> String = CategoryCatalog.title
    ) -> String {
        var lines = [line(columns.map { field($0) })]
        lines.reserveCapacity(transactions.count + 1)
        for transaction in transactions {
            let row: [String] = [
                transaction.bookingDate.map(date) ?? "",
                date(transaction.valueDate),
                status(transaction.status),
                text(transaction.counterpartName),
                text(transaction.counterpartIBAN),
                text(transaction.purpose),
                amount(transaction.amountCents),
                text(transaction.currency),
                text(transaction.categoryID.map(categoryTitle)),
                text(accountName(transaction.accountID)),
                text(accountIBAN(transaction.accountID)),
                text(transaction.eref),
                text(transaction.mref),
                text(transaction.creditorID),
                transaction.originalAmountCents.map(amount) ?? "",
                text(transaction.originalCurrency),
                text(transaction.categoryID?.rawValue),
            ]
            lines.append(line(row.map { field($0) }))
        }
        return lines.joined()
    }

    /// `MFN-<scope>-<yyyy-MM-dd>.csv`; characters that are awkward in file names become `-`.
    public static func fileName(scope: String, day: BankDay = .today) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        var cleaned = ""
        var lastWasDash = false
        for scalar in scope.unicodeScalars {
            let dash = forbidden.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
            if dash {
                if !lastWasDash, !cleaned.isEmpty { cleaned.append("-") }
                lastWasDash = true
            } else {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            }
        }
        while cleaned.hasSuffix("-") || cleaned.hasSuffix(".") { cleaned.removeLast() }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        let name = cleaned.isEmpty ? "Umsaetze" : String(cleaned.prefix(80))
        return "MFN-\(name)-\(day.iso).csv"
    }

    // MARK: Fields

    /// `dd.MM.yyyy`.
    public static func date(_ day: BankDay) -> String {
        String(format: "%02d.%02d.%04d", day.day, day.month, day.year)
    }

    /// `-1234,56`; integer arithmetic only.
    public static func amount(_ cents: Int) -> String {
        let magnitude = cents.magnitude
        let euros = magnitude / 100
        let rest = magnitude % 100
        return "\(cents < 0 ? "-" : "")\(euros),\(rest < 10 ? "0" : "")\(rest)"
    }

    public static func status(_ status: TransactionStatus) -> String {
        switch status {
        case .booked: "gebucht"
        case .pending: "vorgemerkt"
        case .planned: "geplant"
        case .cancelled: "storniert"
        }
    }

    /// Free text: neutralises formula starts (see type documentation).
    static func text(_ value: String?) -> String {
        guard let value, let first = value.unicodeScalars.first else { return "" }
        return formulaStarts.contains(first) ? "'" + value : value
    }

    private static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// RFC 4180 quoting with `;` as separator.
    static func field(_ value: String) -> String {
        let needsQuotes = value.contains(where: { $0 == separator || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func line(_ fields: [String]) -> String {
        fields.joined(separator: String(separator)) + lineEnding
    }
}
