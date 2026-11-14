import Foundation
import MFNCore

/// The text of a booking as kNN and the language model see it (CLAUDE.md §8): merchant plus the
/// purpose without SEPA tags, references and dates, at most `maxPurposeLength` characters.
public struct TransactionText: Hashable, Sendable {
    public static let maxPurposeLength = 120

    public let merchant: String
    /// What the language model sees.
    public let purpose: String
    /// `purpose` without payment-channel boilerplate ("VISA Debitkartenumsatz Karte 1"): what
    /// tells bookings apart. Used for embeddings, so card payments compare by merchant only.
    public let signalPurpose: String

    public init(_ transaction: Transaction) {
        self.init(merchant: transaction.counterpartName, purpose: transaction.purpose)
    }

    public init(merchant: String, purpose: String) {
        self.merchant = Self.cleanMerchant(merchant)
        self.purpose = Self.cleanPurpose(purpose)
        signalPurpose = Self.signal(of: self.purpose)
    }

    /// One line for embeddings: "merchant · purpose" without boilerplate.
    public var embeddingText: String {
        if signalPurpose.isEmpty { return merchant }
        if merchant.isEmpty { return signalPurpose }
        return "\(merchant) · \(signalPurpose)"
    }

    // MARK: Cleaning

    /// SEPA field tags as in MT940 field 86 / camt remittance info.
    static let sepaTags = ["EREF", "KREF", "MREF", "CRED", "DEBT", "SVWZ", "ABWA", "ABWE", "IBAN", "BIC", "COAM", "OAMT", "SQTP", "PURP", "BREF", "RREF"]

    /// Labels banks put in front of references in human-readable purposes.
    static let referenceLabels = [
        "end-to-end-ref.", "end-to-end-ref", "endtoendid", "eref", "mandatsref.", "mandatsref", "mandatsreferenz",
        "mandat", "glaeubiger-id", "gläubiger-id", "glaubiger-id", "gläubiger id", "creditor id", "kundenreferenz",
        "referenz", "ref.", "iban", "bic", "kartenzahlung karte", "folgenr.", "verfalld.", "terminal",
    ]

    static let legalForms: Set<String> = ["gmbh", "ag", "se", "kg", "kgaa", "co", "co.", "ohg", "ug", "e.v.", "ev", "mbh", "gbr", "&", "u.", "und", "inc", "ltd", "sarl", "s.a.", "bv", "b.v.", "eg", "e.k.", "ek"]

    /// Payment-channel words that say how, not what.
    static let boilerplate: Set<String> = [
        "visa", "mastercard", "maestro", "debitkartenumsatz", "kartenumsatz", "kartenzahlung", "girocard", "karte",
        "debitkarte", "kreditkarte", "lastschrift", "basislastschrift", "sepa-lastschrift", "sepa", "ec", "pos",
        "umsatz", "zahlung", "einzug", "gutschrift", "dauerauftrag", "überweisung", "ueberweisung", "online-banking",
        "apple", "pay", "google", "contactless", "kontaktlos", "folgenr", "nr", "nr.",
    ]

    static func signal(of purpose: String) -> String {
        purpose
            .split(whereSeparator: \.isWhitespace)
            .filter { token in
                let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
                return lower.count > 1 && !boilerplate.contains(lower)
            }
            .joined(separator: " ")
    }

    public static func cleanMerchant(_ name: String) -> String {
        var text = name
        // Card acquirers append "//City/Country" or "/Ort".
        if let range = text.range(of: "//") { text = String(text[..<range.lowerBound]) }
        let tokens = text
            .replacingOccurrences(of: "*", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { token in
                let lower = token.lowercased()
                return !legalForms.contains(lower) && !isReference(token)
            }
        return String(tokens.joined(separator: " ").prefix(60))
    }

    public static func cleanPurpose(_ purpose: String) -> String {
        var text = purpose.replacingOccurrences(of: "\n", with: " ")
        text = stripSEPATags(text)
        var kept: [String] = []
        var skipNext = false
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = String(raw)
            let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if skipNext {
                skipNext = false
                // The value after a label: an ID with digits, or a BIC-like upper-case code.
                let isCode = token.count >= 8 && token.allSatisfy { $0.isUppercase || $0.isNumber }
                if isReference(token) || isCode || token.contains(where: \.isNumber) { continue }
            }
            if referenceLabels.contains(lower) || referenceLabels.contains(lower + ".") { skipNext = true; continue }
            if isReference(token) || isDateOrTime(token) { continue }
            kept.append(token)
        }
        let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/,;.-")))
        return String(joined.prefix(maxPurposeLength))
    }

    static let sepaTagRegex = try? NSRegularExpression(pattern: "(" + sepaTags.joined(separator: "|") + ")\\+")
    static let dateRegex = try? NSRegularExpression(
        pattern: #"^(\d{1,2}\.\d{1,2}\.(\d{2}|\d{4})?|\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2}(T[\d:.]+)?|\d{1,2}:\d{2}(:\d{2})?(Uhr)?|\d{1,2}\.\d{2}h?)$"#
    )

    /// Keeps the SVWZ+ (Verwendungszweck) part if tagged; drops every other tagged field.
    static func stripSEPATags(_ text: String) -> String {
        guard let regex = sepaTagRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var parts: [String] = []
        // Text before the first tag (e.g. "Lastschrift").
        let head = ns.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespaces)
        if !head.isEmpty { parts.append(head) }
        for (index, match) in matches.enumerated() {
            let tag = ns.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard tag == "SVWZ" || tag == "ABWA" else { continue }
            parts.append(ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: " ")
    }

    /// Reference-like tokens: long digit runs, IBANs, mixed IDs with many digits.
    static func isReference(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;/()-"))
        guard !core.isEmpty else { return true }
        let digits = core.filter(\.isNumber).count
        if digits >= 6 { return true }
        if core.count >= 8, digits >= 3, Double(digits) / Double(core.count) > 0.3 { return true }
        // IBAN: two letters, two digits, ≥ 12 more.
        if core.count >= 15, core.prefix(2).allSatisfy(\.isLetter), core.dropFirst(2).prefix(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    static func isDateOrTime(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;()"))
        guard core.contains(where: \.isNumber), let regex = dateRegex else { return false }
        return regex.firstMatch(in: core, range: NSRange(location: 0, length: (core as NSString).length)) != nil
    }
}
