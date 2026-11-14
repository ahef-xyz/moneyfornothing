import Foundation

extension CategoryRule.Match {
    /// The match the rule sheet (⇧⌘K) starts with for this transaction: its most specific
    /// identifier. Creditor ID comes before the mandate reference because it is unique across
    /// creditors (mandate references are only unique per creditor) and covers every contract
    /// with that creditor; then counterpart IBAN, then the counterpart name without store numbers
    /// and similar tokens (card payments: "REWE Markt 4711 Koeln" → "REWE Markt"), then the purpose.
    /// `nil` if the transaction offers nothing to match on.
    public static func suggested(for transaction: Transaction) -> CategoryRule.Match? {
        if let creditor = transaction.creditorID.map(LearnedRules.compact), !creditor.isEmpty {
            return .creditorID(creditor)
        }
        if let mandate = transaction.mref?.trimmingCharacters(in: .whitespaces), !mandate.isEmpty {
            return .mandateReference(mandate)
        }
        if let iban = transaction.counterpartIBAN.map(LearnedRules.compact), !iban.isEmpty {
            return .counterpartIBAN(iban)
        }
        if let name = merchantName(transaction.counterpartName) {
            return .counterpart(name)
        }
        let purpose = collapse(transaction.purpose)
        if !purpose.isEmpty {
            return .purpose(String(purpose.prefix(40)))
        }
        return nil
    }

    /// Leading words up to the first one containing a digit (store numbers, dates, card
    /// terminals). Falls back to the whole name if that leaves nothing.
    static func merchantName(_ raw: String) -> String? {
        let words = collapse(raw).split(separator: " ")
        var kept: [Substring] = []
        for word in words {
            if word.contains(where: \.isNumber) { break }
            kept.append(word)
        }
        let name = kept.isEmpty ? collapse(raw) : kept.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
