import CryptoKit
import Foundation
import MFNCore

/// Demo stand-in for the kNN/Foundation Models stages (`MFN_DEMO=1`), behaving like MFN on a
/// Mac without Apple Intelligence: it learns from the user's decisions, not from the start.
///
/// - A counterpart the user already categorized (a labeled transaction in the context with the
///   same `CategoryRule.Match.suggested(for:)`) gets that category, confidently ("ähnlich"/"KI");
///   about one in eight stays unsure so "Zu prüfen" has something to show.
/// - Of the other counterparts, about one in five gets an unsure guess (< `Categorizer.reviewThreshold`,
///   sometimes a wrong neighbour category), the rest nothing. So a fresh demo ledger is mostly
///   open and the "Kategorien einrichten" assistant is well filled. Stable per transaction.
/// Never used live.
public struct MockCategorizationStage: CategorizationStage {
    public let source: CategorySource = .llm

    public init() {}

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        var learned: [String: CategoryID] = [:]
        for labeled in context.labeled {
            guard let category = labeled.categoryID, let key = Self.key(labeled) else { continue }
            learned[key] = category
        }
        var result: [TransactionID: CategorySuggestion] = [:]
        for transaction in transactions {
            let roll = Self.roll(transaction.fingerprint.isEmpty ? transaction.id.rawValue : transaction.fingerprint)
            let source: CategorySource = roll < 0.5 ? .knn : .llm
            if let key = Self.key(transaction), let category = learned[key] {
                let unsure = roll < 0.125
                let confidence = unsure ? 0.42 + roll * 2 : 0.72 + (roll - 0.125) / 0.875 * 0.27
                result[transaction.id] = CategorySuggestion(categoryID: category, source: source, confidence: confidence)
                continue
            }
            guard let category = Self.category(for: transaction),
                  Self.roll("guess|" + (Self.key(transaction) ?? transaction.counterpartName)) < Self.guessShare else { continue }
            let chosen = roll < 0.3 ? (Self.alternatives[category] ?? category) : category
            result[transaction.id] = CategorySuggestion(categoryID: chosen, source: source, confidence: 0.45 + roll * 0.23)
        }
        return result
    }

    /// Share of not yet learned counterparts that get an (unsure) guess; the rest stays open.
    static let guessShare = 0.2

    /// The counterpart as the assistant groups it.
    static func key(_ transaction: Transaction) -> String? {
        CategoryRule.Match.suggested(for: transaction).map { String(describing: $0) }
    }

    /// Demo rules for the mock data (Gläubiger-IDs of the generator), added once to an empty demo ledger.
    public static let demoRules: [CategoryRule] = [
        CategoryRule(match: .creditorID("DE00ZZZ00000000002"), categoryID: "nebenkosten", createdAt: Date(timeIntervalSince1970: 1_767_225_600)),
        CategoryRule(match: .creditorID("DE00ZZZ00000000003"), categoryID: "internet_telefon", createdAt: Date(timeIntervalSince1970: 1_767_225_600)),
        CategoryRule(match: .counterpart("Hausverwaltung Sommer"), categoryID: "miete", createdAt: Date(timeIntervalSince1970: 1_767_225_600)),
    ]

    /// 0..<1, stable per transaction.
    static func roll(_ key: String) -> Double {
        let digest = SHA256.hash(data: Data(key.utf8))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Double(value) / (Double(UInt32.max) + 1)
    }

    private static let alternatives: [CategoryID: CategoryID] = [
        "lebensmittel": "drogerie", "drogerie": "lebensmittel", "restaurant": "lebensmittel",
        "tanken": "auto", "oepnv": "reisen", "online_shopping": "elektronik", "elektronik": "online_shopping",
        "abos": "elektronik", "reisen": "freizeit", "freizeit": "restaurant", "kleidung": "online_shopping",
        "taxi_sharing": "oepnv", "haushalt": "online_shopping", "gesundheit": "drogerie", "bargeld": "sonstiges",
    ]

    /// First match wins: (text in counterpart or purpose, category).
    private static let keywords: [(String, CategoryID)] = [
        ("lohn/gehalt", "gehalt"), ("erstattung", "erstattung"), ("zinsen", "zinsen"), ("sparplan", "sparen_anlegen"),
        ("eigenes", "umbuchung"), ("pocket", "umbuchung"), ("einzahlung", "umbuchung"), ("taschengeld", "umbuchung"),
        ("kreditkartenabrechnung", "kredit"), ("abrechnung", "kredit"), ("ausgleich", "kredit"),
        ("rewe", "lebensmittel"), ("edeka", "lebensmittel"), ("lidl", "lebensmittel"), ("aldi", "lebensmittel"), ("bäckerei", "lebensmittel"),
        ("dm-drogerie", "drogerie"), ("apotheke", "gesundheit"), ("aral", "tanken"), ("shell", "tanken"),
        ("db vertrieb", "oepnv"), ("trattoria", "restaurant"), ("sushi", "restaurant"), ("lieferando", "restaurant"),
        ("ikea", "haushalt"), ("mediamarkt", "elektronik"), ("kino", "freizeit"), ("zalando", "kleidung"), ("amazon", "online_shopping"),
        ("apple.com", "abos"), ("netflix", "abos"), ("spotify", "abos"), ("steam", "freizeit"), ("github", "elektronik"),
        ("uber", "taxi_sharing"), ("booking.com", "reisen"), ("airbnb", "reisen"),
        ("stadtwerke", "nebenkosten"), ("telekom", "internet_telefon"), ("vodafone", "internet_telefon"),
        ("rundfunk", "steuern"), ("huk-coburg", "versicherung"), ("urban sports", "sport"), ("hausverwaltung", "miete"),
        ("geldautomat", "bargeld"), ("bargeld", "bargeld"),
    ]

    static func category(for transaction: Transaction) -> CategoryID? {
        let text = (transaction.counterpartName + " " + transaction.purpose).lowercased()
        return keywords.first { text.contains($0.0) }?.1
    }
}
