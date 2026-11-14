import Foundation
import MFNCore

/// Parsing of amounts and dates as German web banking and CSV exports write them.
enum GermanFormats {
    /// Amount text → signed cents, without `Double`.
    ///
    /// Accepts `-1.234,56`, `1234,56`, `−12,30 €`, `12,30-` (trailing sign), `+5,00`, `EUR 7,5`,
    /// and `1234.56` (dot as decimal separator only if no comma is present and exactly one or two
    /// digits follow the last dot). Returns `nil` for anything else.
    static func cents(_ text: String) -> Int? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        var negative = false
        let minus: Set<Character> = ["-", "−", "–"]
        if let first = string.first, minus.contains(first) || first == "+" {
            negative = minus.contains(first)
            string.removeFirst()
        }
        // Currency codes or symbols around the number.
        string = string.filter { !$0.isLetter && $0 != "€" && !$0.isWhitespace && $0 != "\u{00A0}" }
        if let first = string.first, minus.contains(first) {
            negative.toggle()
            string.removeFirst()
        }
        if let last = string.last, minus.contains(last) {
            negative.toggle()
            string.removeLast()
        }
        guard !string.isEmpty, string.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }

        let integerPart: Substring
        let fractionPart: Substring
        if let comma = string.lastIndex(of: ",") {
            integerPart = string[..<comma]
            fractionPart = string[string.index(after: comma)...]
            guard !integerPart.contains(","), !fractionPart.contains("."), !fractionPart.isEmpty else { return nil }
        } else if let dot = string.lastIndex(of: "."),
                  string.filter({ $0 == "." }).count == 1,
                  (1...2).contains(string.distance(from: dot, to: string.endIndex) - 1) {
            integerPart = string[..<dot]
            fractionPart = string[string.index(after: dot)...]
        } else {
            integerPart = Substring(string)
            fractionPart = ""
        }
        guard fractionPart.count <= 2 else { return nil }
        // Thousands separators: dots in the integer part.
        let digits = integerPart.filter { $0 != "." }
        guard let units = digits.isEmpty ? 0 : Int(digits) else { return nil }
        let fraction = fractionPart.padding(toLength: 2, withPad: "0", startingAt: 0)
        guard let hundredths = Int(fraction) else { return nil }
        let (scaled, overflow1) = units.multipliedReportingOverflow(by: 100)
        let (total, overflow2) = scaled.addingReportingOverflow(hundredths)
        guard !overflow1, !overflow2 else { return nil }
        return negative ? -total : total
    }

    /// `dd.MM.yyyy`, `dd.MM.yy` (20xx) or `yyyy-MM-dd`, optionally followed by a time.
    static func day(_ text: String) -> BankDay? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let datePart = trimmed.split(whereSeparator: { $0 == " " || $0 == "T" }).first.map(String.init) ?? ""
        if datePart.contains("-") { return BankDay(iso: datePart) }
        let parts = datePart.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let d = Int(parts[0]), let m = Int(parts[1]), var y = Int(parts[2]) else { return nil }
        if parts[2].count == 2 { y += 2000 } else if parts[2].count != 4 { return nil }
        return BankDay(year: y, month: m, day: d)
    }
}
