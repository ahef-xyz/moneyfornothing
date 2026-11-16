import Foundation

/// Text encoding of a CSV file, as detected by `CSVParser.decode`.
public enum CSVEncoding: String, Sendable, Hashable, CaseIterable {
    case utf8BOM
    case utf8
    case utf16
    /// Windows-1252, a superset of ISO-8859-1 for printable text (older German bank exports).
    case windows1252

    public var displayName: String {
        switch self {
        case .utf8BOM: "UTF-8 (mit BOM)"
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .windows1252: "Windows-1252 / ISO-8859-1"
        }
    }
}

public enum CSVDelimiter: String, Sendable, Hashable, CaseIterable {
    case semicolon = ";"
    case comma = ","
    case tab = "\t"

    public var displayName: String {
        switch self {
        case .semicolon: "Semikolon"
        case .comma: "Komma"
        case .tab: "Tabulator"
        }
    }

    var scalar: Unicode.Scalar {
        switch self {
        case .semicolon: ";"
        case .comma: ","
        case .tab: "\t"
        }
    }
}

/// A decoded and split CSV file.
public struct CSVTable: Sendable, Hashable {
    public var encoding: CSVEncoding
    public var delimiter: CSVDelimiter
    /// Non-empty rows; cells trimmed of surrounding whitespace.
    public var rows: [[String]]
    /// 1-based line number in the file where each row starts (for messages; parallel to `rows`).
    public var lines: [Int]

    public init(encoding: CSVEncoding, delimiter: CSVDelimiter, rows: [[String]], lines: [Int]) {
        self.encoding = encoding
        self.delimiter = delimiter
        self.rows = rows
        self.lines = lines
    }
}

/// Why a CSV file could not be imported. Messages never contain cell values.
public enum CSVImportError: Error, Sendable, Hashable {
    case empty
    case unknownEncoding
    case unclosedQuote(line: Int)
    case noHeader

    public var message: String {
        switch self {
        case .empty: "Die Datei enthält keine Zeilen."
        case .unknownEncoding: "Die Zeichenkodierung der Datei ist unbekannt."
        case let .unclosedQuote(line): "Ein Anführungszeichen ab Zeile \(line) wird nicht geschlossen."
        case .noHeader: "Keine Kopfzeile mit Datum und Betrag gefunden."
        }
    }
}

/// RFC-4180 reader for bank CSV exports (generalised from the easybank fallback importer).
///
/// - Encoding: UTF-8 with or without BOM, UTF-16 with BOM, otherwise Windows-1252.
/// - Delimiter: `;`, `,` or tab, counted outside quotes over the first lines (exports put metadata
///   lines above the header, so the first line alone is not enough). Ties prefer `;`.
/// - Quoted fields with `""` escapes and line breaks inside quotes; `\r\n`, `\n` and `\r` line ends.
/// - Empty lines are skipped.
public enum CSVParser {
    public static func parse(_ data: Data, delimiter: CSVDelimiter? = nil) throws(CSVImportError) -> CSVTable {
        guard let (text, encoding) = decode(data) else { throw .unknownEncoding }
        // Walked in place: no `Array` copy of the whole file.
        let scalars = text.unicodeScalars
        let delimiter = delimiter ?? detectDelimiter(scalars)
        let separator = delimiter.scalar

        var rows: [[String]] = []
        var lines: [Int] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        /// `field` holds only whitespace so far (a `"` there opens a quoted field).
        var fieldIsBlank = true
        var inQuotes = false
        var line = 1
        var rowStart = 1
        var quoteStart = 1
        var index = scalars.startIndex
        let whitespace = CharacterSet.whitespaces

        func append(_ scalar: Unicode.Scalar) {
            field.append(scalar)
            if fieldIsBlank, !whitespace.contains(scalar) { fieldIsBlank = false }
        }
        func endField() {
            row.append(String(field).trimmingCharacters(in: .whitespaces))
            field = String.UnicodeScalarView()
            fieldIsBlank = true
        }
        func endRow() {
            endField()
            if !row.allSatisfy(\.isEmpty) {
                rows.append(row)
                lines.append(rowStart)
            }
            row = []
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            let following: Unicode.Scalar? = next < scalars.endIndex ? scalars[next] : nil
            if inQuotes {
                if scalar == "\"" {
                    if following == "\"" {
                        append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    if scalar == "\n" || (scalar == "\r" && following != "\n") { line += 1 }
                    append(scalar)
                }
            } else {
                switch scalar {
                case "\"" where fieldIsBlank:
                    field = String.UnicodeScalarView()
                    inQuotes = true
                    quoteStart = line
                case separator:
                    endField()
                case "\r":
                    if following == "\n" { index = next }
                    endRow()
                    line += 1
                    rowStart = line
                case "\n":
                    endRow()
                    line += 1
                    rowStart = line
                default:
                    append(scalar)
                }
            }
            index = scalars.index(after: index)
        }
        if inQuotes { throw .unclosedQuote(line: quoteStart) }
        if !field.isEmpty || !row.isEmpty { endRow() }
        guard !rows.isEmpty else { throw .empty }
        return CSVTable(encoding: encoding, delimiter: delimiter, rows: rows, lines: lines)
    }

    /// Decodes `data`, detecting the encoding. A leading BOM is removed.
    public static func decode(_ data: Data) -> (String, CSVEncoding)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8).map { ($0, .utf8BOM) }
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            // `.utf16` reads the BOM for the byte order; only a leading one is dropped (U+FEFF
            // further in is content, a zero-width no-break space).
            return String(data: data, encoding: .utf16).map { text in
                (text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text, .utf16)
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) { return (utf8, .utf8) }
        return String(data: data, encoding: .windowsCP1252).map { ($0, .windows1252) }
    }

    static let sampleLines = 30

    static func detectDelimiter<S: Sequence>(_ scalars: S) -> CSVDelimiter where S.Element == Unicode.Scalar {
        var counts: [CSVDelimiter: Int] = [:]
        var inQuotes = false
        var lines = 0
        for scalar in scalars {
            if scalar == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if scalar == "\n" {
                lines += 1
                if lines >= sampleLines { break }
                continue
            }
            switch scalar {
            case ";": counts[.semicolon, default: 0] += 1
            case ",": counts[.comma, default: 0] += 1
            case "\t": counts[.tab, default: 0] += 1
            default: break
            }
        }
        // Ties prefer `;` (German exports use `,` as decimal separator).
        let order: [CSVDelimiter] = [.semicolon, .tab, .comma]
        var best = CSVDelimiter.semicolon
        for candidate in order where (counts[candidate] ?? 0) > (counts[best] ?? 0) {
            best = candidate
        }
        return best
    }
}
