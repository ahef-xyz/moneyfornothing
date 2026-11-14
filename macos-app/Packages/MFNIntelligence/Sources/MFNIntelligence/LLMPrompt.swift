import Foundation
import MFNCore

/// Builds what the model sees (CLAUDE.md §8): short instructions, and per booking only
/// merchant, purpose (≤ 120 characters, SEPA tags removed), amount, weekday and account type.
enum LLMPrompt {
    /// < 300 tokens (checked by a test). The schema with the category IDs is added by the framework.
    static let instructions = """
        Ordne jede deutsche Bankbuchung genau einer Kategorie zu. Negativer Betrag = Ausgabe, positiver = Eingang. \
        Hinweise: Überweisung zwischen eigenen Konten = umbuchung; Sparplan, Depot, Wertpapierkauf = sparen_anlegen; \
        Kreditkartenabrechnung, Ratenkredit = kredit; Strom, Gas, Wasser, Fernwärme = nebenkosten; \
        Bahn, Bus, Deutschlandticket = oepnv; Arzt, Apotheke = gesundheit; Streaming, Abos = abos; \
        Geldautomat = bargeld; Finanzamt, Rundfunkbeitrag, Kfz-Steuer = steuern. \
        Sicherheit 0 bis 100: ehrlich, niedrig wenn unklar. Antworte für jede Nummer genau einmal.
        """

    struct Item {
        let number: Int
        let transaction: Transaction
        let accountType: AccountType?
    }

    struct Example {
        let transaction: Transaction
        let category: CategoryID
    }

    static func prompt(items: [Item], examples: [Example]) -> String {
        var lines: [String] = []
        if !examples.isEmpty {
            lines.append("Beispiele aus der eigenen Historie:")
            for example in examples {
                lines.append("- \(describe(example.transaction, accountType: nil)) → \(example.category.rawValue)")
            }
            lines.append("")
        }
        lines.append("Buchungen:")
        for item in items {
            lines.append("\(item.number). \(describe(item.transaction, accountType: item.accountType))")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ transaction: Transaction, accountType: AccountType?) -> String {
        let text = TransactionText(transaction)
        var parts = [
            "Händler: \(text.merchant.isEmpty ? "–" : text.merchant)",
            "Zweck: \(text.purpose.isEmpty ? "–" : text.purpose)",
            "Betrag: \(amount(transaction.amountCents, currency: transaction.currency))",
            "Tag: \(weekday(transaction.bookingDate ?? transaction.valueDate))",
        ]
        if let accountType { parts.append("Konto: \(accountTypeName(accountType))") }
        return parts.joined(separator: "; ")
    }

    static func amount(_ cents: Int, currency: String) -> String {
        let sign = cents < 0 ? "-" : "+"
        let value = abs(cents)
        let symbol = currency == "EUR" ? "€" : currency
        return "\(sign)\(value / 100),\(String(format: "%02d", value % 100)) \(symbol)"
    }

    static func weekday(_ day: BankDay) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BankDay.bankTimeZone
        let names = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
        let index = calendar.component(.weekday, from: day.startDate) - 1
        return names.indices.contains(index) ? names[index] : "–"
    }

    static func accountTypeName(_ type: AccountType) -> String {
        switch type {
        case .giro: "Girokonto"
        case .tagesgeld: "Tagesgeld"
        case .depot: "Depot"
        case .card: "Kreditkarte"
        }
    }
}
