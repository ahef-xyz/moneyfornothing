import Foundation
import Testing
@testable import MFNCore

private func tx(_ name: String, purpose: String = "", creditor: String? = nil, iban: String? = nil, category: CategoryID? = nil, source: CategorySource? = nil) -> Transaction {
    let day = BankDay(year: 2026, month: 11, day: 3)!
    // The fingerprint (and so the ID) ignores the name: a distinct purpose keeps IDs apart.
    return Transaction(accountID: "a1", bookingDate: day, valueDate: day, amountCents: -1_000, counterpartName: name, counterpartIBAN: iban, purpose: purpose.isEmpty ? "Zahlung \(name)" : purpose, creditorID: creditor, status: .booked, categoryID: category, categorySource: source)
}

private struct FixedStage: CategorizationStage {
    let source: CategorySource
    let answers: [String: (CategoryID, Double)]
    let seen: Recorder
    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await seen.record(transactions.map(\.counterpartName))
        var result: [TransactionID: CategorySuggestion] = [:]
        for t in transactions {
            if let (id, c) = answers[t.counterpartName] { result[t.id] = CategorySuggestion(categoryID: id, source: source, confidence: c) }
        }
        return result
    }
}

private actor Recorder {
    var calls: [[String]] = []
    func record(_ names: [String]) { calls.append(names) }
}

@Suite struct CategorizationContractTests {
    @Test func catalogIDsAreUniqueAndKnown() {
        let ids = CategoryCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CategoryCatalog.title("lebensmittel") == "Lebensmittel")
        #expect(CategoryCatalog.title("unbekannt") == "unbekannt")
    }

    @Test func cascadeStopsWhenSureAndKeepsTheBest() async {
        let first = Recorder(), second = Recorder()
        let rewe = tx("REWE"), shop = tx("Shop"), none = tx("Unbekannt")
        let categorizer = Categorizer(stages: [
            FixedStage(source: .rule, answers: ["REWE": ("lebensmittel", 1)], seen: first),
            FixedStage(source: .knn, answers: ["Shop": ("online_shopping", 0.6), "REWE": ("restaurant", 0.99)], seen: second),
        ])
        let result = await categorizer.categorize([rewe, shop, none], context: CategorizationContext())
        #expect(result[rewe.id]?.categoryID == "lebensmittel", "rule settled it, the second stage never saw it")
        #expect(await second.calls.first?.contains("REWE") == false)
        #expect(result[shop.id]?.source == .knn)
        #expect(result[none.id] == nil)
    }

    @Test func rulesMatch() {
        let t = tx("Stadtwerke Köln GmbH", purpose: "Abschlag Strom", creditor: "DE12ZZZ00000012345", iban: "DE89 3704 0044 0532 0130 00")
        #expect(CategoryRule(match: .creditorID("de12zzz00000012345"), categoryID: "nebenkosten").matches(t))
        #expect(CategoryRule(match: .counterpartIBAN("DE89370400440532013000"), categoryID: "nebenkosten").matches(t))
        #expect(CategoryRule(match: .counterpart("stadtwerke koln"), categoryID: "nebenkosten").matches(t))
        #expect(CategoryRule(match: .purpose("strom"), categoryID: "nebenkosten").matches(t))
        #expect(!CategoryRule(match: .purpose(""), categoryID: "nebenkosten").matches(t))
    }

    @Test func batchNeverOverwritesManual() {
        var snapshot = LedgerSnapshot()
        let manual = tx("A", category: "kinder", source: .manual)
        let open = tx("B")
        snapshot.transactions = [manual, open]
        let changed = snapshot.setCategories([
            manual.id: CategorySuggestion(categoryID: "sonstiges", source: .llm, confidence: 0.9),
            open.id: CategorySuggestion(categoryID: "sonstiges", source: .llm, confidence: 0.5),
        ])
        #expect(changed.map(\.id) == [open.id])
        #expect(snapshot.transactions[0].categoryID == "kinder")
        #expect(snapshot.transactions[1].confidence == 0.5)
    }

    @Test func contextUsesTrustedLabels() {
        var snapshot = LedgerSnapshot()
        snapshot.transactions = [tx("A", category: "kinder", source: .manual), tx("B", category: "sonstiges", source: .llm), tx("C")]
        #expect(CategorizationContext(snapshot: snapshot).labeled.map(\.counterpartName) == ["A"])
    }
}

@Suite struct CategorizationServiceTests {
    @Test func rulesCategorizeAndManualWins() async throws {
        let store = InMemoryLedgerStore()
        try await store.upsert(connection: Connection(id: "c1", connectorID: .mock, displayName: "T"))
        try await store.replaceAccounts([Account(id: "a1", connectionID: "c1", type: .giro, name: "Giro")], of: "c1")
        let rewe = tx("REWE Markt"), kita = tx("Kita Sonnenschein")
        try await store.apply(TransactionMerger.Result(upserts: [rewe, kita], deletions: [], resolved: [:]))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage()]))

        #expect(try await service.apply(rule: CategoryRule(match: .counterpart("rewe"), categoryID: "lebensmittel")) == 1)
        try await service.setManual("kinder", for: [kita.id])
        try await service.apply(rule: CategoryRule(match: .counterpart("kita"), categoryID: "sonstiges"))
        let snapshot = await store.snapshot()
        #expect(snapshot.transactions.first { $0.id == rewe.id }?.categoryID == "lebensmittel")
        #expect(snapshot.transactions.first { $0.id == kita.id }?.categoryID == "kinder", "manual stays")
        #expect(try await service.categorizeUncategorized().categorized == 0)
    }
}

@Suite struct SetupPlanContractTests {
    @Test func basicPlanGroupsOpenTransactionsByCounterpart() async throws {
        let store = InMemoryLedgerStore()
        try await store.upsert(connection: Connection(id: "c1", connectorID: .mock, displayName: "T"))
        try await store.replaceAccounts([Account(id: "a1", connectionID: "c1", type: .giro, name: "Giro")], of: "c1")
        let day = BankDay(year: 2026, month: 11, day: 3)!
        var transactions: [Transaction] = []
        for i in 0..<5 {
            transactions.append(Transaction(accountID: "a1", bookingDate: day.adding(days: -i), valueDate: day.adding(days: -i), amountCents: -2_000 - i, counterpartName: "REWE Markt", purpose: "Einkauf \(i)", status: .booked))
        }
        transactions.append(Transaction(accountID: "a1", bookingDate: day, valueDate: day, amountCents: -500, counterpartName: "Kiosk", purpose: "Zeitung", status: .booked))
        try await store.apply(TransactionMerger.Result(upserts: transactions, deletions: [], resolved: [:]))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage(), TransferStage(), KnownMerchantStage()]))

        let plan = await service.setupPlan()
        #expect(plan.totalTransactions == 6)
        #expect(plan.categorizedTransactions == 0)
        #expect(plan.candidates.first?.title == "REWE Markt")
        #expect(plan.candidates.first?.transactionIDs.count == 5)
        #expect(plan.projectedCoverage == 1)
        #expect(!plan.suggestsSetup, "fewer than 20 transactions")
    }
}
