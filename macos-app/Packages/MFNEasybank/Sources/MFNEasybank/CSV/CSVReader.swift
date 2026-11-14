import Foundation
import MFNCore

/// Minimal RFC-4180 reader for bank CSV exports.
///
/// - Encoding: UTF-8 (with or without BOM), otherwise Windows-1252 (German bank exports).
/// - Delimiter: `;`, `,` or tab, detected from the first non-empty line (outside quotes).
/// - Quoted fields with `""` escapes and line breaks inside quotes; `\r\n`, `\n` and `\r` line ends.
/// - Empty lines are skipped. Cells are trimmed of surrounding whitespace.
enum CSVReader {
    static func rows(from data: Data) throws(ConnectorError) -> [[String]] {
        guard let text = decode(data) else { throw .formatChanged(detail: "CSV: Zeichenkodierung unbekannt") }
        let scalars = Array(text.unicodeScalars)
        let delimiter = detectDelimiter(scalars)

        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var index = 0

        func endField() {
            row.append(String(field).trimmingCharacters(in: .whitespaces))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case "\"" where String(field).trimmingCharacters(in: .whitespaces).isEmpty:
                    field = String.UnicodeScalarView()
                    inQuotes = true
                case delimiter:
                    endField()
                case "\r":
                    if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                    endRow()
                case "\n":
                    endRow()
                default:
                    field.append(scalar)
                }
            }
            index += 1
        }
        if inQuotes { throw .formatChanged(detail: "CSV: Anführungszeichen nicht geschlossen") }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    static func decode(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        return String(data: bytes, encoding: .windowsCP1252)
    }

    /// Exports may start with a preamble (account name, period) before the header,
    /// so the delimiter is counted over the first lines, not just the first one.
    static let sampleLines = 10

    static func detectDelimiter(_ scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var counts: [Unicode.Scalar: Int] = [";": 0, ",": 0, "\t": 0]
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
            if counts[scalar] != nil { counts[scalar, default: 0] += 1 }
        }
        // Ties prefer `;` (German exports use `,` as decimal separator).
        let order: [Unicode.Scalar] = [";", "\t", ","]
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ";"
    }
}
