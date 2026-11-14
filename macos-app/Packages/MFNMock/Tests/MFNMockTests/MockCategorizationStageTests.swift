import Foundation
import MFNCore
import Testing
@testable import MFNMock

@Suite struct MockCategorizationStageTests {
    static let today = BankDay(iso: "2026-11-09") ?? .today
    let dataset = MockDataset.demo(today: Self.today, now: Self.today.startDate.addingTimeInterval(9 * 3600))

    /// Like MFN without Apple Intelligence: on an unlabeled ledger only unsure guesses, and
    /// for a good part of the counterparts nothing – the setup assistant has work to do.
    @Test func freshLedgerStaysMostlyOpen() async {
        let transactions = dataset.allTransactions.filter { $0.status != .cancelled }
        let suggestions = await MockCategorizationStage().suggest(transactions, context: CategorizationContext())
        // Most stays open (about one counterpart in five gets a guess).
        #expect(suggestions.count > transactions.count / 20 && suggestions.count < transactions.count * 2 / 5, "\(suggestions.count) of \(transactions.count)")
        #expect(suggestions.values.allSatisfy { $0.confidence < Categorizer.reviewThreshold })
        #expect(suggestions.values.allSatisfy { CategoryCatalog.info($0.categoryID) != nil })
        #expect(Set(suggestions.values.map(\.source)) == [.knn, .llm])
    }

    /// Once the user categorized a counterpart, its other transactions follow confidently.
    @Test func learnsFromLabeledCounterparts() async throws {
        let transactions = dataset.allTransactions.filter { $0.status != .cancelled }
        let groups = Dictionary(grouping: transactions) { MockCategorizationStage.key($0) ?? "" }
        let group = try #require(groups.values.filter { $0.count >= 10 }.first)
        var labeled = group[0]
        labeled.categoryID = "geschenke_spenden"
        labeled.categorySource = .manual
        let rest = Array(group.dropFirst())
        let suggestions = await MockCategorizationStage().suggest(rest, context: CategorizationContext(labeled: [labeled]))
        #expect(suggestions.count == rest.count)
        #expect(suggestions.values.allSatisfy { $0.categoryID == "geschenke_spenden" })
        let confident = suggestions.values.filter { $0.confidence >= Categorizer.reviewThreshold }
        #expect(confident.count > rest.count / 2, "\(confident.count) of \(rest.count)")
    }

    @Test func stable() async {
        let transactions = Array(dataset.allTransactions.prefix(50))
        let first = await MockCategorizationStage().suggest(transactions, context: CategorizationContext())
        let second = await MockCategorizationStage().suggest(transactions, context: CategorizationContext())
        #expect(first == second)
    }

    @Test func demoRulesUseCatalogAndMatch() {
        for rule in MockCategorizationStage.demoRules {
            #expect(CategoryCatalog.info(rule.categoryID) != nil)
            #expect(dataset.allTransactions.contains(where: rule.matches))
        }
    }
}
