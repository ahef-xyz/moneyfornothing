import Foundation
import MFNCore
@testable import MFNIntelligence

/// The synthetic eval set (`Tests/Fixtures/categories.json`; generator `Tests/Eval/generate.py`).
struct EvalSet {
    struct Item: Decodable {
        let id: String
        let merchant: String
        let purpose: String
        let amountCents: Int
        let accountType: AccountType
        let bookingDate: String
        let category: String
        let creditorID: String?
        let mref: String?
    }

    private struct File: Decodable {
        let version: Int
        let transactions: [Item]
    }

    let items: [Item]

    static func load() throws -> EvalSet {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["Fixtures/categories.json", "Eval/categories.json"].map { tests.appendingPathComponent($0) }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return EvalSet(items: file.transactions)
    }

    static func accountID(_ type: AccountType) -> AccountID { AccountID("eval-\(type.rawValue)") }

    var accountTypes: [AccountID: AccountType] {
        Dictionary(uniqueKeysWithValues: AccountType.allCases.map { (Self.accountID($0), $0) })
    }

    /// Unlabeled transactions (what the categorizer gets) and the expected categories.
    var transactions: [Transaction] { items.map { Self.transaction($0, labeled: false) } }
    var labeled: [Transaction] { items.map { Self.transaction($0, labeled: true) } }
    var expected: [TransactionID: CategoryID] {
        Dictionary(uniqueKeysWithValues: items.map { (TransactionID($0.id), CategoryID($0.category)) })
    }

    static func transaction(_ item: Item, labeled: Bool) -> Transaction {
        let day = BankDay(iso: item.bookingDate) ?? BankDay(Date(timeIntervalSince1970: 0))
        return Transaction(
            id: TransactionID(item.id),
            accountID: accountID(item.accountType),
            bookingDate: day,
            valueDate: day,
            amountCents: item.amountCents,
            counterpartName: item.merchant,
            purpose: item.purpose,
            mref: item.mref,
            creditorID: item.creditorID,
            status: .booked,
            categoryID: labeled ? CategoryID(item.category) : nil,
            categorySource: labeled ? .manual : nil,
            confidence: labeled ? 1 : nil
        )
    }

    /// What a learned-rule stage would know from the history: a creditor ID always booked to one
    /// category becomes a rule (simulates the core agent's learned rules; explicit rules are empty).
    static func creditorRules(from labeled: [Transaction]) -> [CategoryRule] {
        var byCreditor: [String: Set<CategoryID>] = [:]
        for t in labeled {
            guard let creditor = t.creditorID, let category = t.categoryID else { continue }
            byCreditor[creditor, default: []].insert(category)
        }
        return byCreditor.compactMap { creditor, categories in
            guard categories.count == 1, let category = categories.first else { return nil }
            return CategoryRule(match: .creditorID(creditor), categoryID: category, createdAt: Date(timeIntervalSince1970: 0))
        }
    }
}
