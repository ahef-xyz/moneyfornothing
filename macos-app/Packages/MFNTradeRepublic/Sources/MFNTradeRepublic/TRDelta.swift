import Foundation
import MFNCore

/// Applies a Trade Republic WebSocket delta (`<n> D <delta>`) to the last full answer.
///
/// The delta is a tab-separated list of operations on the previous payload text
/// (positions count Unicode scalars, like Python string indices in pytr):
/// - `=<k>` copy the next `k` characters,
/// - `-<k>` skip the next `k` characters,
/// - `+<text>` insert URL-encoded (`+` = space) text, surrounding whitespace trimmed.
enum TRDelta {
    static func apply(_ delta: String, to previous: String) throws(ConnectorError) -> String {
        let source = Array(previous.unicodeScalars)
        var index = 0
        var result = String.UnicodeScalarView()
        for operation in delta.split(separator: "\t", omittingEmptySubsequences: true) {
            guard let sign = operation.first else { continue }
            switch sign {
            case "+":
                // Same as pytr: unquote_plus on the whole operation turns the sign into a space, then strip.
                let inserted = unquotePlus(String(operation)).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(contentsOf: inserted.unicodeScalars)
            case "=", "-":
                guard let count = Int(operation.dropFirst()), count >= 0, index + count <= source.count else {
                    throw .formatChanged(detail: "Trade-Republic-Delta passt nicht zum letzten Stand")
                }
                if sign == "=" { result.append(contentsOf: source[index ..< index + count]) }
                index += count
            default:
                throw .formatChanged(detail: "Unbekannte Trade-Republic-Delta-Operation")
            }
        }
        return String(result)
    }

    static func unquotePlus(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
