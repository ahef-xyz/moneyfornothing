import Foundation
import MFNCore

/// Parse error for SWIFT MT940/MT942 and MT535. The detail names the field, never its content
/// (statements contain IBANs and names).
public struct MT940Error: Error, Equatable, Sendable, CustomStringConvertible {
    public let detail: String

    public init(_ detail: String) {
        self.detail = detail
    }

    public var description: String { "MT940: \(detail)" }

    public var connectorError: ConnectorError { .formatChanged(detail: description) }
}

/// One account statement (`:20:` … `:62F:`). MT942 (pending) uses the same structure
/// without opening/closing balance.
public struct MT940Statement: Sendable, Equatable {
    public var transactionReference: String?
    /// `:25:` account identification (BLZ/account or IBAN). Sensitive – never log.
    public var accountIdentification: String?
    public var statementNumber: String?
    public var openingBalance: MT940Balance?
    public var closingBalance: MT940Balance?
    public var availableBalance: MT940Balance?
    public var entries: [MT940Entry]
    /// Currency of the statement (from the balances), `nil` if no balance line is present.
    public var currency: String? { openingBalance?.currency ?? closingBalance?.currency ?? availableBalance?.currency }
}

public struct MT940Balance: Sendable, Equatable {
    public var date: BankDay
    public var currency: String
    /// Signed: debit balances are negative.
    public var amountCents: Int
}

/// One `:61:` line with its `:86:` details.
public struct MT940Entry: Sendable, Equatable {
    public var valueDate: BankDay
    /// Entry (booking) date; `:61:` carries only month/day, the year is inferred from the value date.
    public var entryDate: BankDay?
    /// Signed: debits (and reversals of credits) are negative.
    public var amountCents: Int
    /// `RC` / `RD` (reversal / Storno).
    public var isReversal: Bool
    /// Third letter of the currency code (funds code), rarely used.
    public var fundsCode: String?
    /// Transaction type identification, e.g. `NMSC`, `NTRF`.
    public var transactionType: String
    public var customerReference: String
    public var bankReference: String?
    public var supplementaryDetails: String?
    public var details: MT940Details?
    /// Raw field contents for `Transaction.rawJSON`.
    public var raw61: String
    public var raw86: String?
}

/// Structured `:86:` field (German "Mehrzweckfeld"): `GVC?00…?10…?20…?29?30…?34?60…?63`.
public struct MT940Details: Sendable, Equatable {
    /// Geschäftsvorfallcode (3 digits), e.g. `105` direct debit, `166` credit transfer.
    public var transactionCode: String?
    /// `?00` Buchungstext, e.g. "Lastschrift".
    public var postingText: String?
    /// `?10` Primanota.
    public var primanota: String?
    /// `?20`–`?29` and `?60`–`?63`, in order.
    public var purposeLines: [String]
    /// `?30` BIC / BLZ of the counterpart.
    public var counterpartBIC: String?
    /// `?31` IBAN / account number of the counterpart.
    public var counterpartAccount: String?
    /// `?32` + `?33`.
    public var counterpartName: String?
    /// `?34` Textschlüsselergänzung.
    public var textKeyExtension: String?
    /// SEPA tags in the purpose (`EREF`, `MREF`, `CRED`, `SVWZ`, `ABWA` …).
    public var sepa: [String: String]
    /// Free text when the `:86:` field is unstructured.
    public var unstructured: String?

    /// The joined purpose lines. MT940 wraps after 27 characters, also mid-word, so lines are
    /// concatenated without separator.
    public var rawPurpose: String {
        unstructured ?? purposeLines.joined()
    }

    /// The remittance information: `SVWZ+` if tagged, otherwise the whole purpose.
    public var purpose: String {
        if let svwz = sepa["SVWZ"] { return svwz }
        return rawPurpose.trimmingCharacters(in: .whitespaces)
    }

    public var endToEndReference: String? { Self.meaningful(sepa["EREF"]) }
    public var mandateReference: String? { Self.meaningful(sepa["MREF"]) }
    public var creditorID: String? { Self.meaningful(sepa["CRED"]) }

    static func meaningful(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.uppercased() != "NOTPROVIDED" else { return nil }
        return value
    }
}

/// SWIFT MT940 (booked) / MT942 (pending) parser as delivered by FinTS `HIKAZ`.
public enum MT940Parser {
    /// Parses raw bytes from `HIKAZ` (ISO-8859-1; UTF-8 is detected and accepted).
    public static func parse(_ data: Data) throws(MT940Error) -> [MT940Statement] {
        try parse(MT940Text.decode(data))
    }

    public static func parse(_ text: String) throws(MT940Error) -> [MT940Statement] {
        var statements: [MT940Statement] = []
        var current: MT940Statement?
        var pendingEntry: MT940Entry?

        func flushEntry() {
            if let entry = pendingEntry { current?.entries.append(entry) }
            pendingEntry = nil
        }
        func flushStatement() {
            flushEntry()
            if let statement = current { statements.append(statement) }
            current = nil
        }

        for field in MT940Text.fields(text) {
            if field.tag == "-" {
                flushStatement()
                continue
            }
            if field.tag == "20" || current == nil {
                flushStatement()
                current = MT940Statement(entries: [])
            }
            switch field.tag {
            case "20":
                current?.transactionReference = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "21":
                break
            case "25":
                current?.accountIdentification = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "28C", "28":
                current?.statementNumber = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "60F", "60M":
                current?.openingBalance = try balance(field.value, tag: field.tag)
            case "62F", "62M":
                current?.closingBalance = try balance(field.value, tag: field.tag)
            case "64":
                current?.availableBalance = try balance(field.value, tag: field.tag)
            case "61":
                flushEntry()
                pendingEntry = try entry(field.value)
            case "86":
                guard pendingEntry != nil else { break }
                let raw = MT940Text.unwrap(field.value)
                pendingEntry?.raw86 = raw
                pendingEntry?.details = details(raw)
            default:
                // :13D: (MT942 creation time), :34F: (floor limit), :65:, :90D:/:90C: (MT942 sums) …
                break
            }
        }
        flushStatement()
        return statements.filter { $0.transactionReference != nil || !$0.entries.isEmpty || $0.closingBalance != nil }
    }

    // MARK: - Fields

    /// `:60F:` etc.: `C` / `D`, `YYMMDD`, currency, amount.
    static func balance(_ value: String, tag: String) throws(MT940Error) -> MT940Balance {
        var scanner = MT940Scanner(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let mark = scanner.take(1), mark == "C" || mark == "D",
              let dateText = scanner.take(6), let date = MT940Text.day(yymmdd: dateText),
              let currency = scanner.take(3),
              let cents = MT940Text.cents(scanner.rest)
        else { throw MT940Error("Saldo :\(tag): nicht lesbar") }
        return MT940Balance(date: date, currency: currency, amountCents: mark == "D" ? -cents : cents)
    }

    /// `:61:` `YYMMDD[MMDD](C|D|RC|RD)[funds]amount(N|F|S)xxx customerRef[//bankRef][\nsupplementary]`.
    static func entry(_ value: String) throws(MT940Error) -> MT940Entry {
        let lines = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let first = String(lines.first ?? "")
        let supplementary = lines.dropFirst().joined().trimmingCharacters(in: .whitespaces)
        var scanner = MT940Scanner(first)

        guard let valueText = scanner.take(6), let valueDate = MT940Text.day(yymmdd: valueText) else {
            throw MT940Error("Valuta in :61: nicht lesbar")
        }
        var entryDate: BankDay?
        if let mmdd = scanner.peek(4), mmdd.allSatisfy(\.isNumber) {
            scanner.advance(4)
            entryDate = MT940Text.day(mmdd: mmdd, near: valueDate)
        }
        var isReversal = false
        if scanner.peek(1) == "R" {
            isReversal = true
            scanner.advance(1)
        }
        guard let mark = scanner.take(1), mark == "C" || mark == "D" else {
            throw MT940Error("Soll/Haben-Kennung in :61: fehlt")
        }
        var fundsCode: String?
        if let next = scanner.peek(1), next.first?.isLetter == true {
            fundsCode = next
            scanner.advance(1)
        }
        let amountText = scanner.take(while: { $0.isNumber || $0 == "," })
        guard let cents = MT940Text.cents(amountText) else { throw MT940Error("Betrag in :61: nicht lesbar") }
        guard let type = scanner.take(4) else { throw MT940Error("Buchungsschlüssel in :61: fehlt") }

        let references = scanner.rest
        let customerReference: String
        let bankReference: String?
        if let range = references.range(of: "//") {
            customerReference = String(references[..<range.lowerBound])
            bankReference = String(references[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            customerReference = references
            bankReference = nil
        }

        // C = credit (+), D = debit (−); RC = reversal of a credit (−), RD = reversal of a debit (+).
        let positive = (mark == "C") != isReversal
        return MT940Entry(
            valueDate: valueDate,
            entryDate: entryDate,
            amountCents: positive ? cents : -cents,
            isReversal: isReversal,
            fundsCode: fundsCode,
            transactionType: type,
            customerReference: customerReference.trimmingCharacters(in: .whitespaces),
            bankReference: bankReference.flatMap { $0.isEmpty ? nil : $0 },
            supplementaryDetails: supplementary.isEmpty ? nil : supplementary,
            details: nil,
            raw61: value,
            raw86: nil
        )
    }

    /// `:86:` with `?xx` subfields. The separator is the first non-alphanumeric character after
    /// the 3-digit code (practically always `?`).
    static func details(_ raw: String) -> MT940Details {
        var result = MT940Details(purposeLines: [], sepa: [:])
        let characters = Array(raw)
        guard characters.count >= 4,
              characters[0...2].allSatisfy(\.isNumber),
              characters[3] == "?"
        else {
            result.unstructured = raw
            result.sepa = sepaTags(raw)
            return result
        }
        result.transactionCode = String(characters[0...2])

        var subfields: [(key: Int, value: String)] = []
        var index = 3
        while index < characters.count {
            guard characters[index] == "?", index + 2 < characters.count,
                  let tens = characters[index + 1].wholeNumberValue,
                  let ones = characters[index + 2].wholeNumberValue
            else {
                // Lone "?" inside a value: keep it as text of the previous subfield.
                if !subfields.isEmpty { subfields[subfields.count - 1].value.append(characters[index]) }
                index += 1
                continue
            }
            var end = index + 3
            while end < characters.count {
                if characters[end] == "?", end + 2 < characters.count,
                   characters[end + 1].isNumber, characters[end + 2].isNumber { break }
                end += 1
            }
            subfields.append((tens * 10 + ones, String(characters[(index + 3)..<end])))
            index = end
        }

        var name: [String] = []
        for (key, value) in subfields {
            switch key {
            case 0: result.postingText = value.trimmingCharacters(in: .whitespaces)
            case 10: result.primanota = value.trimmingCharacters(in: .whitespaces)
            case 20...29, 60...63: result.purposeLines.append(value)
            case 30: result.counterpartBIC = nonEmpty(value)
            case 31: result.counterpartAccount = nonEmpty(value)
            case 32, 33: name.append(value)
            case 34: result.textKeyExtension = nonEmpty(value)
            default: break
            }
        }
        result.counterpartName = nonEmpty(name.joined())
        result.sepa = sepaTags(result.rawPurpose)
        return result
    }

    static let sepaKeys = ["EREF", "KREF", "MREF", "CRED", "DEBT", "COAM", "OAMT", "SVWZ", "ABWA", "ABWE", "IBAN", "BIC"]

    /// Splits `EREF+…MREF+…SVWZ+…` into tags. Text before the first tag is ignored if any tag exists.
    static func sepaTags(_ text: String) -> [String: String] {
        let pattern = sepaKeys.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(\(pattern))\\+") else { return [:] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [String: String] = [:]
        for (offset, match) in matches.enumerated() {
            let key = ns.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            let end = offset + 1 < matches.count ? matches[offset + 1].range.location : ns.length
            let value = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            if result[key] == nil { result[key] = value }
        }
        return result
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Shared helpers (MT940 and MT535)

enum MT940Text {
    /// ISO-8859-1 is the FinTS charset. Some servers send UTF-8: a non-ASCII byte sequence that
    /// is valid UTF-8 is practically never Latin-1 text, so prefer UTF-8 then.
    static func decode(_ data: Data) -> String {
        if data.contains(where: { $0 >= 0x80 }), let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return String(decoding: data.map { UInt16($0) }, as: UTF16.self)
    }

    struct Field: Equatable {
        var tag: String
        var value: String
    }

    /// Splits into `:tag:value` fields; continuation lines are kept with `\n`. A line `-` ends a
    /// statement and is returned as tag `-`. Some banks use `@@` as line separator.
    static func fields(_ text: String) -> [Field] {
        var normalized = text
        if !normalized.contains(where: \.isNewline), normalized.contains("@@") {
            normalized = normalized.replacingOccurrences(of: "@@", with: "\n")
        }
        var fields: [Field] = []
        for rawLine in normalized.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces) == "-" {
                fields.append(Field(tag: "-", value: ""))
                continue
            }
            if let (tag, value) = tagged(line) {
                fields.append(Field(tag: tag, value: value))
            } else if !fields.isEmpty, fields[fields.count - 1].tag != "-" {
                fields[fields.count - 1].value += "\n" + line
            }
        }
        return fields
    }

    /// `:61:…`, `:28C:…`, `:16R:…` → (tag, rest).
    private static func tagged(_ line: String) -> (String, String)? {
        guard line.first == ":" else { return nil }
        let body = line.dropFirst()
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let tag = body[..<colon]
        guard (2...3).contains(tag.count), tag.prefix(2).allSatisfy(\.isNumber),
              tag.dropFirst(2).allSatisfy({ $0.isUppercase && $0.isASCII }) else { return nil }
        return (String(tag), String(body[body.index(after: colon)...]))
    }

    /// Joins continuation lines of a field that wraps without meaning (`:86:`).
    static func unwrap(_ value: String) -> String {
        value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined()
    }

    /// `YYMMDD`. Years 00–79 → 20xx, 80–99 → 19xx.
    static func day(yymmdd text: String) -> BankDay? {
        guard text.count == 6, text.allSatisfy(\.isNumber),
              let yy = Int(text.prefix(2)), let mm = Int(text.dropFirst(2).prefix(2)), let dd = Int(text.suffix(2)) else { return nil }
        return BankDay(year: yy < 80 ? 2000 + yy : 1900 + yy, month: mm, day: dd)
    }

    /// `YYYYMMDD`.
    static func day(yyyymmdd text: String) -> BankDay? {
        guard text.count == 8, text.allSatisfy(\.isNumber),
              let y = Int(text.prefix(4)), let m = Int(text.dropFirst(4).prefix(2)), let d = Int(text.suffix(2)) else { return nil }
        return BankDay(year: y, month: m, day: d)
    }

    /// `MMDD` without year: the candidate year closest to `reference` (Dec/Jan turn of the year).
    static func day(mmdd text: String, near reference: BankDay) -> BankDay? {
        guard let mm = Int(text.prefix(2)), let dd = Int(text.suffix(2)) else { return nil }
        let candidates = [reference.year - 1, reference.year, reference.year + 1].compactMap { BankDay(year: $0, month: mm, day: dd) }
        return candidates.min { abs($0.days(to: reference)) < abs($1.days(to: reference)) }
    }

    /// `1234,56` / `1234,5` / `1234,` / `1234` → cents (unsigned). Never via floating point.
    static func cents(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let integer = parts.first, !integer.isEmpty,
              integer.allSatisfy(\.isNumber), let whole = Int(integer) else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.allSatisfy(\.isNumber) else { return nil }
        // More than two decimals (rare): round half-even on the third digit onwards.
        let extra = fraction.count > 2 ? String(fraction.dropFirst(2)) : ""
        fraction = String((fraction + "00").prefix(2))
        guard let cents = Int(fraction) else { return nil }
        var result = whole * 100 + cents
        if let firstExtra = extra.first?.wholeNumberValue {
            let rest = extra.dropFirst().contains { $0 != "0" }
            if firstExtra > 5 || (firstExtra == 5 && (rest || result % 2 == 1)) { result += 1 }
        }
        return result
    }

    /// `1234,56` → `Decimal` (quantities, prices).
    static func decimal(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "," || $0 == "-" }) else { return nil }
        var normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        if normalized.hasSuffix(".") { normalized.removeLast() }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Minimal cursor over a single line.
struct MT940Scanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    func peek(_ count: Int) -> String? {
        guard index + count <= characters.count else { return nil }
        return String(characters[index..<(index + count)])
    }

    mutating func advance(_ count: Int) {
        index = min(characters.count, index + count)
    }

    mutating func take(_ count: Int) -> String? {
        guard let value = peek(count) else { return nil }
        index += count
        return value
    }

    mutating func take(while predicate: (Character) -> Bool) -> String {
        let start = index
        while index < characters.count, predicate(characters[index]) { index += 1 }
        return String(characters[start..<index])
    }

    var rest: String {
        index < characters.count ? String(characters[index...]) : ""
    }
}
