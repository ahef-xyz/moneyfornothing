import Foundation

/// Decimal separator of the amounts in a CSV file.
public enum CSVDecimalSeparator: String, Sendable, Hashable, CaseIterable {
    /// German: `1.234,56`.
    case comma
    /// English: `1,234.56` or `-12.5` (N26).
    case point

    public var displayName: String {
        switch self {
        case .comma: "1.234,56"
        case .point: "1,234.56"
        }
    }
}

/// Amounts and dates as bank CSV exports write them (generalised from `MFNEasybank.GermanFormats`).
public enum CSVValues {
    /// Largest amount the import accepts (100 billion in the major unit). Bigger values are
    /// nonsense in a bank export; capping keeps every sum of imported rows far from `Int` overflow.
    public static let maximumAbsoluteCents = 10_000_000_000_000

    /// Trailing debit/credit markers (German Soll/Haben, English DR/CR): `true` = negative.
    private static let signMarkers: [String: Bool] = ["s": true, "soll": true, "dr": true, "h": false, "haben": false, "cr": false]
    private static let currencySymbols: Set<Character> = ["€", "$", "£", "¥"]

    /// Amount text → signed cents, without `Double`.
    ///
    /// Accepts `-1.234,56`, `1234,56`, `−12,30 €`, `12,30-` (trailing sign), `+5,00`, `EUR 7,5`,
    /// `(12,30)` (accounting negative), `12,30 S` / `12,30 H` (Soll/Haben, also `Soll`, `Haben`,
    /// `DR`, `CR`; the marker sets the sign). With `.point`: `-1,234.56`, `12.5`.
    /// Without a hint (`nil`), a `.` followed by one or two digits and no `,` is a decimal point.
    /// Only ISO currency codes (three letters) and currency symbols are stripped; any other
    /// letters, or more than `maximumAbsoluteCents`, give `nil`.
    public static func cents(_ text: String, decimal: CSVDecimalSeparator? = .comma) -> Int? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        // A trailing Soll/Haben or DR/CR marker decides the sign on its own.
        var markedNegative: Bool?
        let trailingLetters = String(string.reversed().prefix(while: \.isLetter).reversed())
        if let marker = signMarkers[trailingLetters.lowercased()] {
            markedNegative = marker
            string = String(string.dropLast(trailingLetters.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var negative = false
        let minus: Set<Character> = ["-", "−", "–"]
        if string.hasPrefix("("), string.hasSuffix(")") {
            negative = true
            string = String(string.dropFirst().dropLast())
        }
        // Letters only as ISO currency codes (`EUR`, `usd`); anything else is not an amount.
        var letterRun = 0
        for character in string + " " {
            if character.isLetter {
                guard character.isASCII else { return nil }
                letterRun += 1
            } else {
                guard letterRun == 0 || letterRun == 3 else { return nil }
                letterRun = 0
            }
        }
        // Currency codes or symbols and spaces (incl. non-breaking) around the number.
        string = string.filter { !$0.isLetter && !currencySymbols.contains($0) && !$0.isWhitespace && $0 != "\u{00A0}" && $0 != "'" }
        if let first = string.first, minus.contains(first) || first == "+" {
            if minus.contains(first) { negative.toggle() }
            string.removeFirst()
        }
        if let last = string.last, minus.contains(last) {
            negative.toggle()
            string.removeLast()
        }
        guard !string.isEmpty, string.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }

        let separator: Character
        let grouping: Character
        switch decimal {
        case .comma?:
            separator = ","; grouping = "."
        case .point?:
            separator = "."; grouping = ","
        case nil:
            if string.contains(",") {
                separator = ","; grouping = "."
            } else if let dot = string.lastIndex(of: "."), string.filter({ $0 == "." }).count == 1,
                      (1...2).contains(string.distance(from: dot, to: string.endIndex) - 1) {
                separator = "."; grouping = ","
            } else {
                separator = ","; grouping = "."
            }
        }

        let integerPart: Substring
        let fractionPart: Substring
        if let mark = string.lastIndex(of: separator) {
            integerPart = string[..<mark]
            fractionPart = string[string.index(after: mark)...]
            guard !integerPart.contains(separator), !fractionPart.contains(grouping), !fractionPart.isEmpty else { return nil }
        } else {
            integerPart = Substring(string)
            fractionPart = ""
        }
        guard fractionPart.count <= 2 else { return nil }
        // Grouping marks must separate groups of three digits.
        let groups = integerPart.split(separator: grouping, omittingEmptySubsequences: false)
        if groups.count > 1 {
            guard let head = groups.first, (1...3).contains(head.count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let digits = integerPart.filter { $0 != grouping }
        guard let units = digits.isEmpty ? (fractionPart.isEmpty ? nil : 0) : Int(digits) else { return nil }
        let fraction = fractionPart.padding(toLength: 2, withPad: "0", startingAt: 0)
        guard let hundredths = Int(fraction) else { return nil }
        let (scaled, overflow1) = units.multipliedReportingOverflow(by: 100)
        let (total, overflow2) = scaled.addingReportingOverflow(hundredths)
        guard !overflow1, !overflow2, total <= maximumAbsoluteCents else { return nil }
        if let markedNegative { return markedNegative ? -total : total }
        return negative ? -total : total
    }

    /// `dd.MM.yyyy`, `dd.MM.yy` (20xx), `d.M.yyyy`, `dd/MM/yyyy` or `yyyy-MM-dd`, optionally
    /// followed by a time.
    public static func day(_ text: String) -> BankDay? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let datePart = trimmed.split(whereSeparator: { $0 == " " || $0 == "T" }).first.map(String.init) ?? ""
        if datePart.contains("-") { return BankDay(iso: datePart) }
        let separator: Character = datePart.contains("/") ? "/" : "."
        let parts = datePart.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isASCII) }),
              let d = Int(parts[0]), let m = Int(parts[1]), var y = Int(parts[2]) else { return nil }
        if parts[2].count == 2 { y += 2000 } else if parts[2].count != 4 { return nil }
        return BankDay(year: y, month: m, day: d)
    }

    /// The separator most amount cells use: a `,` or `.` followed by one or two digits at the end.
    /// Ties (e.g. only whole numbers) prefer `.comma`.
    public static func detectDecimalSeparator<S: Sequence>(_ samples: S) -> CSVDecimalSeparator where S.Element == String {
        var comma = 0
        var point = 0
        for sample in samples {
            let digitsAndMarks = sample.filter { $0.isNumber || $0 == "," || $0 == "." }
            guard let mark = digitsAndMarks.lastIndex(where: { $0 == "," || $0 == "." }) else { continue }
            let tail = digitsAndMarks.distance(from: mark, to: digitsAndMarks.endIndex) - 1
            guard (1...2).contains(tail) else { continue }
            if digitsAndMarks[mark] == "," { comma += 1 } else { point += 1 }
        }
        return point > comma ? .point : .comma
    }

    /// Three-letter currency code in `text` (`EUR`, `€`, `usd`), else `nil`.
    public static func currencyCode(_ text: String) -> String? {
        if text.contains("€") { return "EUR" }
        let letters = text.filter(\.isLetter).uppercased()
        return letters.count == 3 && letters.allSatisfy(\.isASCII) ? letters : nil
    }
}
