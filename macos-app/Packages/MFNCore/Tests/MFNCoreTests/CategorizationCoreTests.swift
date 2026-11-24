import Foundation
import Testing
@testable import MFNCore

// Synthetic data only: names, IBANs and creditor IDs are made up.

private func tx(
    _ name: String,
    purpose: String? = nil,
    account: AccountID = "a1",
    amount: Int = -1_000,
    day: Int = 3,
    creditor: String? = nil,
    mref: String? = nil,
    iban: String? = nil,
    status: TransactionStatus = .booked,
    category: CategoryID? = nil,
    source: CategorySource? = nil
) -> Transaction {
    let date = BankDay(year: 2026, month: 10, day: day) ?? .today
    return Transaction(
        accountID: account, bookingDate: date, valueDate: date, amountCents: amount,
        counterpartName: name, counterpartIBAN: iban, purpose: purpose ?? "Zahlung \(name) \(day)",
        mref: mref, creditorID: creditor, status: status,
        categoryID: category, categorySource: source, confidence: category == nil ? nil : 1
    )
}

private func manual(_ t: Transaction, _ category: CategoryID) -> Transaction {
    var copy = t
    copy.categoryID = category
    copy.categorySource = .manual
    copy.confidence = 1
    return copy
}

/// Answers from a table keyed by counterpart name; counts how often and with what it is asked.
private struct TableStage: CategorizationStage {
    let source: CategorySource
    let answers: [String: (CategoryID, Double)]
    var log: CallLog = CallLog()
    var delay: Duration = .zero

    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await log.record(transactions.map(\.counterpartName))
        if delay > .zero { try? await Task.sleep(for: delay) }
        var result: [TransactionID: CategorySuggestion] = [:]
        for t in transactions {
            if let (id, c) = answers[t.counterpartName] { result[t.id] = CategorySuggestion(categoryID: id, source: source, confidence: c) }
        }
        return result
    }
}

private actor CallLog {
    var calls: [[String]] = []
    func record(_ names: [String]) { calls.append(names) }
}

private func makeStore(_ transactions: [Transaction], rules: [CategoryRule] = []) async throws -> InMemoryLedgerStore {
    var snapshot = LedgerSnapshot()
    snapshot.connections = [Connection(id: "c1", connectorID: .mock, displayName: "Test")]
    snapshot.accounts = [Account(id: "a1", connectionID: "c1", type: .giro, name: "Giro")]
    snapshot.transactions = transactions
    snapshot.categoryRules = rules
    return InMemoryLedgerStore(snapshot)
}

private func category(_ store: InMemoryLedgerStore, _ id: TransactionID) async -> (CategoryID?, CategorySource?) {
    let t = await store.snapshot().transactions.first { $0.id == id }
    return (t?.categoryID, t?.categorySource)
}

// MARK: - Rule stage

@Suite struct LearnedRuleTests {
    @Test func learnsFromManualIdentifiers() async {
        let history = [
            manual(tx("Stadtwerke", day: 1, creditor: "DE11ZZZ00000000001"), "nebenkosten"),
            manual(tx("Fitness X", day: 1, mref: "M-77"), "sport"),
            manual(tx("Vermieter", day: 1, iban: "DE00 1111 2222 3333 4444 55"), "miete"),
        ]
        let open = [
            tx("Stadtwerke AG", day: 2, creditor: "de11zzz00000000001"),
            tx("Fitness X", day: 2, mref: "M-77"),
            tx("Herr Vermieter", day: 2, iban: "DE00111122223333444455"),
            tx("Unbekannt", day: 2),
        ]
        let result = await RuleStage().suggest(open, context: CategorizationContext(labeled: history))
        #expect(result[open[0].id] == CategorySuggestion(categoryID: "nebenkosten", source: .rule, confidence: RuleStage.learnedConfidence))
        #expect(result[open[1].id]?.categoryID == "sport")
        #expect(result[open[2].id]?.categoryID == "miete")
        #expect(result[open[3].id] == nil)
    }

    @Test func contradictoryHistoryGivesNothingButAMoreSpecificKeyStillDecides() async {
        let paypal = "DE22ZZZ00000000002"
        let history = [
            manual(tx("PayPal", day: 1, creditor: paypal, mref: "PP-A"), "abos"),
            manual(tx("PayPal", day: 2, creditor: paypal, mref: "PP-B"), "kleidung"),
        ]
        let sameMandate = tx("PayPal", day: 5, creditor: paypal, mref: "PP-A")
        let newMandate = tx("PayPal", day: 6, creditor: paypal, mref: "PP-C")
        let result = await RuleStage().suggest([sameMandate, newMandate], context: CategorizationContext(labeled: history))
        #expect(result[sameMandate.id]?.categoryID == "abos", "the mandate is unambiguous")
        #expect(result[newMandate.id] == nil, "the creditor alone is contradictory")
    }

    @Test func explicitRulesComeFirstAndOnlyManualLabelsAreLearned() async {
        let history = [
            manual(tx("Shop", day: 1, mref: "S-1"), "kleidung"),
            tx("Kiosk", day: 1, mref: "K-1", category: "lebensmittel", source: .rule),
            tx("Bar", day: 1, mref: "B-1", category: "restaurant", source: .llm),
        ]
        let shop = tx("Shop", day: 2, mref: "S-1"), kiosk = tx("Kiosk", day: 2, mref: "K-1"), bar = tx("Bar", day: 2, mref: "B-1")
        let rule = CategoryRule(match: .counterpart("shop"), categoryID: "online_shopping")
        let result = await RuleStage().suggest([shop, kiosk, bar], context: CategorizationContext(labeled: history, rules: [rule]))
        #expect(result[shop.id] == CategorySuggestion(categoryID: "online_shopping", source: .rule, confidence: 1))
        #expect(result[kiosk.id] == nil, "rule labels are not learned from")
        #expect(result[bar.id] == nil)
    }

    @Test func neverLearnsFromItself() async {
        let own = manual(tx("Allein", mref: "X-1"), "sonstiges")
        let result = await RuleStage().suggest([own], context: CategorizationContext(labeled: [own]))
        #expect(result.isEmpty)
    }
}

@Suite struct SuggestedRuleTests {
    @Test func picksTheMostSpecificIdentifier() {
        let full = tx("Stadtwerke", creditor: "de11 zzz0 0000 0000 01", mref: "M-1", iban: "DE00 1111")
        #expect(CategoryRule.Match.suggested(for: full) == .creditorID("DE11ZZZ00000000001"))
        #expect(CategoryRule.Match.suggested(for: tx("Fitness", mref: " M-2 ", iban: "DE00")) == .mandateReference("M-2"))
        #expect(CategoryRule.Match.suggested(for: tx("Vermieter", iban: "de00 1111")) == .counterpartIBAN("DE001111"))
        #expect(CategoryRule.Match.suggested(for: tx("REWE  Markt 4711 Koeln")) == .counterpart("REWE Markt"))
        #expect(CategoryRule.Match.suggested(for: tx("4711")) == .counterpart("4711"))
        #expect(CategoryRule.Match.suggested(for: tx("", purpose: "Abschlag  Strom")) == .purpose("Abschlag Strom"))
        #expect(CategoryRule.Match.suggested(for: tx("", purpose: " ")) == nil)
    }

    @Test func suggestedRuleMatchesItsTransaction() {
        for t in [tx("REWE Markt 4711 Koeln"), tx("X", creditor: "DE11ZZZ1"), tx("Y", iban: "DE00 1111")] {
            let match = try? #require(CategoryRule.Match.suggested(for: t))
            #expect(match.map { CategoryRule(match: $0, categoryID: "sonstiges").matches(t) } == true)
        }
    }
}

// MARK: - Service

@Suite struct CategorizationServiceCoreTests {
    @Test func onlyUncategorizedAreLookedAt() async throws {
        let done = tx("Done", day: 1, category: "kinder", source: .llm)
        let open = tx("Open", day: 2)
        let store = try await makeStore([done, open])
        let log = CallLog()
        let stage = TableStage(source: .knn, answers: ["Open": ("lebensmittel", 0.9), "Done": ("sonstiges", 0.9)], log: log)
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [stage]))

        let report = try await service.categorizeUncategorized()
        #expect(report.categorized == 1)
        #expect(report.bySource == [.knn: 1])
        #expect(await log.calls == [["Open"]])
        #expect(await category(store, done.id) == ("kinder", .llm))
        #expect(try await service.categorizeUncategorized().categorized == 0)
        #expect(await log.calls.count == 1, "nothing open, no stage call")
    }

    @Test func parallelCallsShareTheRun() async throws {
        let store = try await makeStore((1...20).map { tx("Open", day: $0) })
        let log = CallLog()
        let stage = TableStage(source: .llm, answers: ["Open": ("sonstiges", 0.5)], log: log, delay: .milliseconds(50))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [stage]))

        async let a = service.categorizeUncategorized()
        async let b = service.categorizeUncategorized()
        async let c = service.categorizeUncategorized()
        let reports = try await [a, b, c]
        #expect(await log.calls.count == 1)
        #expect(reports.allSatisfy { $0.categorized == 20 && $0.needsReview == 20 })
    }

    @Test func editingARuleReevaluatesWhatItMatchedBefore() async throws {
        let rewe = tx("REWE", day: 1), aldi = tx("ALDI", day: 2), kept = tx("Kiosk", day: 3)
        let store = try await makeStore([rewe, aldi, kept])
        let fallback = TableStage(source: .knn, answers: ["Kiosk": ("lebensmittel", 0.8)])
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage(), fallback]))
        try await service.categorizeUncategorized()

        var rule = CategoryRule(match: .counterpart("rewe"), categoryID: "lebensmittel")
        #expect(try await service.apply(rule: rule) == 1)
        #expect(await category(store, rewe.id) == ("lebensmittel", .rule))

        rule.match = .counterpart("aldi")
        #expect(try await service.apply(rule: rule) == 1)
        #expect(await category(store, aldi.id) == ("lebensmittel", .rule))
        #expect(await category(store, rewe.id) == (nil, nil), "no longer covered, rule category removed")
        #expect(await category(store, kept.id) == ("lebensmittel", .knn), "untouched")
    }

    @Test func removingARuleFallsBackToTheCascade() async throws {
        let a = tx("Bäcker", day: 1), b = tx("Bäcker", day: 2), m = tx("Bäcker", day: 3, category: "restaurant", source: .manual)
        let store = try await makeStore([a, b, m])
        let knn = TableStage(source: .knn, answers: ["Bäcker": ("lebensmittel", 0.75)])
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage(), knn]))
        let rule = CategoryRule(match: .counterpart("bäcker"), categoryID: "restaurant")
        #expect(try await service.apply(rule: rule) == 2)

        let report = try await service.removeRule(rule.id)
        #expect(report.reevaluated == 2)
        #expect(await category(store, a.id) == ("lebensmittel", .knn))
        #expect(await category(store, m.id) == ("restaurant", .manual))
        #expect(await store.snapshot().categoryRules.isEmpty)
    }

    @Test func removingARuleWithoutFallbackClears() async throws {
        let a = tx("Bäcker", day: 1)
        let store = try await makeStore([a])
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage()]))
        let rule = CategoryRule(match: .counterpart("bäcker"), categoryID: "restaurant")
        try await service.apply(rule: rule)
        #expect(try await service.removeRule(rule.id).cleared == 1)
        #expect(await category(store, a.id) == (nil, nil))
    }

    @Test func correctionPropagatesToSiblings() async throws {
        let corrected = tx("Verein", day: 1, mref: "V-9")
        let sibling = tx("Verein", day: 2, mref: "V-9")
        let stranger = tx("Verein", day: 3, mref: "V-1")
        let store = try await makeStore([corrected, sibling, stranger])
        let llm = TableStage(source: .llm, answers: ["Verein": ("sonstiges", 0.6)])
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage(), llm]))
        try await service.categorizeUncategorized()
        #expect(await category(store, sibling.id) == ("sonstiges", .llm))

        let report = try await service.setManual("sport", for: [corrected.id])
        #expect(report.reevaluated == 1)
        #expect(await category(store, corrected.id) == ("sport", .manual))
        #expect(await category(store, sibling.id) == ("sport", .rule), "learned from the correction")
        #expect(await category(store, stranger.id) == ("sonstiges", .llm), "other mandate untouched")

        // Undoing the correction takes the learned category away again.
        try await service.setManual(nil, for: [corrected.id])
        #expect(await category(store, sibling.id) == ("sonstiges", .llm))
    }

    @Test func fifteenHundredTransactionsAreQuick() async throws {
        let merchants = (0..<60).map { "Händler \($0)" }
        let categories = CategoryCatalog.all.map(\.id)
        var transactions: [Transaction] = []
        for i in 0..<1_500 {
            let m = i % merchants.count
            transactions.append(tx(
                merchants[m], purpose: "Umsatz \(i)", amount: -(100 + i), day: 1 + i % 28,
                creditor: m % 3 == 0 ? "DE\(m)ZZZ000000" : nil, mref: m % 3 == 1 ? "MREF-\(m)" : nil
            ))
        }
        // Every seventh was corrected by the user (reaches every merchant), plus explicit rules.
        for i in stride(from: 0, to: 1_500, by: 7) {
            transactions[i] = manual(transactions[i], categories[(i % merchants.count) % categories.count])
        }
        let rules = (0..<20).map { CategoryRule(match: .counterpart("Händler \($0 * 3 + 2)"), categoryID: categories[$0 % categories.count]) }
        let store = try await makeStore(transactions, rules: rules)
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage()]))

        let clock = ContinuousClock()
        let start = clock.now
        let report = try await service.categorizeUncategorized()
        let elapsed = clock.now - start
        #expect(report.categorized > 1_000)
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }
}

// MARK: - Sync hook

private struct OneAccountConnector: BankConnector {
    let id: ConnectorID = .mock
    var fail = false
    func accounts() async throws -> [Account] {
        if fail { throw ConnectorError.bankUnavailable }
        return [Account(id: "a1", connectionID: "c1", type: .giro, name: "Giro")]
    }
    func balance(for account: Account) async throws -> Balance { Balance(bookedCents: 0, asOf: Date(timeIntervalSince1970: 0)) }
    func transactions(for account: Account, since: Date?) async throws -> [Transaction] { [tx("Neu", day: 9)] }
    func cardStatements(for account: Account) async throws -> [CardStatement] { [] }
    func securities(for account: Account) async throws -> [SecurityPosition] { [] }
}

@Suite struct SyncCategorizationHookTests {
    @Test func categorizesAfterSuccessfulSyncOnly() async throws {
        let store = InMemoryLedgerStore()
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [
            TableStage(source: .knn, answers: ["Neu": ("lebensmittel", 0.9)]),
        ]))
        let log = CallLog()
        let engine = SyncEngine(store: store, afterSync: { id in
            await log.record([id.rawValue])
            _ = try? await service.categorizeUncategorized()
        })
        try await engine.register(Connection(id: "c1", connectorID: .mock, displayName: "T"), connector: OneAccountConnector())
        await engine.sync("c1", trigger: .manual)
        #expect(await log.calls == [["c1"]])
        #expect(await store.snapshot().transactions.first?.categoryID == "lebensmittel")

        try await engine.register(Connection(id: "c1", connectorID: .mock, displayName: "T"), connector: OneAccountConnector(fail: true))
        await engine.sync("c1", trigger: .manual)
        #expect(await log.calls.count == 1, "no hook after a failed sync")
    }
}

// MARK: - Evaluation

@Suite struct CategorizationEvaluationTests {
    private func examples() -> [LabeledExample] {
        [
            LabeledExample(transaction: tx("REWE", day: 1), expected: "lebensmittel"),
            LabeledExample(transaction: tx("REWE", day: 2), expected: "lebensmittel"),
            LabeledExample(transaction: tx("Kino", day: 3), expected: "freizeit"),
            LabeledExample(transaction: tx("Bar", day: 4), expected: "restaurant"),
            LabeledExample(transaction: tx("Shop", day: 5), expected: "kleidung"),
            LabeledExample(transaction: tx("Nichts", day: 6), expected: "sonstiges"),
        ]
    }

    @Test func scoresAccuracyStagesLLMShareAndConfusions() async {
        let categorizer = Categorizer(stages: [
            RuleStage(),
            TableStage(source: .knn, answers: ["Kino": ("freizeit", 0.9), "Bar": ("restaurant", 0.5)]),
            TableStage(source: .llm, answers: ["Bar": ("restaurant", 0.8), "Shop": ("online_shopping", 0.6)]),
        ])
        let rule = CategoryRule(match: .counterpart("rewe"), categoryID: "lebensmittel")
        let result = await CategorizationEvaluation.run(examples(), categorizer: categorizer, context: CategorizationContext(rules: [rule]))

        #expect(result.total == 6)
        #expect(result.correct == 4)
        #expect(result.uncovered == 1)
        #expect(result.needsReview == 1, "Shop at 0.6")
        #expect(result.confident == 4)
        #expect(result.confidentAccuracy == 1)
        #expect(result.stages.map(\.seen) == [6, 4, 3])
        #expect(result.stages.map(\.decided) == [2, 1, 2])
        #expect(result.stages.map(\.correct) == [2, 1, 1])
        #expect(result.reachedLLM == 3)
        #expect(result.llmShare == 0.5)
        #expect(result.perCategory["lebensmittel"] == .init(total: 2, correct: 2, predicted: 2))
        #expect(result.perCategory["online_shopping"]?.predicted == 1)
        #expect(result.perCategory["kleidung"]?.recall == 0)
        #expect(Set(result.confusions.map { "\($0.expected.rawValue)>\($0.predicted?.rawValue ?? "-")" }) == ["kleidung>online_shopping", "sonstiges>-"])
        #expect(result.summary.contains("Genauigkeit: 66.7 %"))
    }

    @Test func withoutLLMStageCountsWhatWouldGoThere() async {
        let categorizer = Categorizer(stages: [TableStage(source: .knn, answers: ["Kino": ("freizeit", 0.9), "Bar": ("restaurant", 0.5)])])
        let result = await CategorizationEvaluation.run(examples(), categorizer: categorizer)
        #expect(result.reachedLLM == 5)
    }

    @Test func crossValidationUsesOtherFoldsAsHistory() async {
        let set = (1...10).map { LabeledExample(transaction: tx("Verein", day: $0, mref: "V-1"), expected: "sport") }
            + (11...20).map { LabeledExample(transaction: tx("Strom", day: $0, creditor: "DE33ZZZ3"), expected: "nebenkosten") }
        let result = await CategorizationEvaluation.crossValidate(set, categorizer: Categorizer(stages: [RuleStage()]), folds: 5)
        #expect(result.total == 20)
        #expect(result.accuracy == 1)
        #expect(result.stages.first?.seen == 20)
        #expect(result.reachedLLM == 0)
    }
}

// MARK: - Slow model (docs/v0.6.0.md section 10)

/// A slow stage like the language model on an 8 GB Mac: answers after `delay`, or never.
private struct SlowStage: CategorizationStage {
    let answers: [String: (CategoryID, Double)]
    var delay: Duration
    var hangs = false
    var log: CallLog = CallLog()
    var source: CategorySource { .llm }
    var isSlow: Bool { true }

    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await log.record(transactions.map(\.counterpartName))
        if hangs {
            // Ignores cancellation, like a stuck model call.
            while true { try? await Task.sleep(for: .seconds(3600)) }
        }
        try? await Task.sleep(for: delay)
        var result: [TransactionID: CategorySuggestion] = [:]
        for t in transactions {
            if let (id, c) = answers[t.counterpartName] { result[t.id] = CategorySuggestion(categoryID: id, source: .llm, confidence: c) }
        }
        return result
    }
}

private final class ProgressLog: Sendable {
    private let entries = Mutex<[CategorizationProgress?]>([])
    func record(_ entry: CategorizationProgress?) { entries.withLock { $0.append(entry) } }
    var all: [CategorizationProgress?] { entries.withLock { $0 } }
}

import Synchronization

@Suite struct SlowModelTests {
    @Test func manualCategoryLandsWhileTheModelHangs() async throws {
        let open = tx("Bäcker"), other = tx("Kiosk", day: 4)
        let store = try await makeStore([open, other])
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [SlowStage(answers: [:], delay: .zero, hangs: true)]))
        let run = Task { try await service.categorizeUncategorized() }
        try await Task.sleep(for: .milliseconds(50))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await service.setManual("lebensmittel", for: [open.id]) }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                Issue.record("setManual waited for the background run")
            }
            try await group.next()
            group.cancelAll()
        }
        #expect(await category(store, open.id) == ("lebensmittel", .manual))
        await service.cancel()
        run.cancel()
    }

    @Test func lateModelAnswerDoesNotOverwriteARuleSavedMeanwhile() async throws {
        let open = tx("Tankstelle Nord")
        let store = try await makeStore([open])
        let slow = SlowStage(answers: ["Tankstelle Nord": ("restaurant", 0.8)], delay: .milliseconds(300))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [RuleStage(), slow]))
        let run = Task { try await service.categorizeUncategorized() }
        try await Task.sleep(for: .milliseconds(80))
        try await service.apply(rule: CategoryRule(match: .counterpart("tankstelle"), categoryID: "tanken"))
        #expect(await category(store, open.id) == ("tanken", .rule))
        _ = try await run.value
        #expect(await category(store, open.id) == ("tanken", .rule), "the run's stale answer is dropped")
    }

    @Test func storeRefusesAStaleMachineWrite() async throws {
        let row = tx("Shop")
        let store = try await makeStore([row])
        let seen = CategoryStamp(row)
        try await store.setCategory("kleidung", source: .rule, confidence: 1, for: [row.id] as Set)
        try await store.setCategories([row.id: CategorySuggestion(categoryID: "abos", source: .llm, confidence: 0.9)], expecting: [row.id: seen])
        #expect(await category(store, row.id) == ("kleidung", .rule))
        try await store.clearCategories([row.id], expecting: [row.id: seen])
        #expect(await category(store, row.id) == ("kleidung", .rule))
    }

    @Test func savesAfterEveryChunkAndReportsProgress() async throws {
        let names = (1 ... 5).map { "Händler \($0)" }
        let rows = names.enumerated().map { tx($1, day: $0 + 1) }
        let store = try await makeStore(rows)
        let answers = Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("freizeit"), 0.8)) })
        let slow = SlowStage(answers: answers, delay: .milliseconds(150))
        let progress = ProgressLog()
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [slow]), slowChunkSize: 2, saveInterval: .zero) { progress.record($0) }
        let run = Task { try await service.categorizeUncategorized() }
        // Some rows are saved before the last chunk is done.
        try await waitUntil { await store.snapshot().transactions.count { $0.categoryID != nil } >= 1 }
        let early = await store.snapshot().transactions.count { $0.categoryID != nil }
        #expect(early >= 1 && early < 5)
        _ = try await run.value
        #expect(await store.snapshot().transactions.allSatisfy { $0.categoryID == "freizeit" })
        let steps = progress.all.compactMap { $0 }
        #expect(steps.first == CategorizationProgress(done: 0, total: 5))
        #expect(steps.last == CategorizationProgress(done: 5, total: 5))
        #expect(steps.map(\.done) == [0, 2, 4, 5])
        #expect(progress.all.last == .some(nil), "ends with nil")
    }

    @Test func aStoppedRunLeavesUnreachedBookingsOpen() async throws {
        let names = (1 ... 6).map { "Laden \($0)" }
        let rows = names.enumerated().map { tx($1, day: $0 + 1) }
        let store = try await makeStore(rows)
        // A weak fast guess for all, the model only gets so far.
        let weak = TableStage(source: .knn, answers: Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("sonstiges"), 0.5)) }))
        let slow = SlowStage(answers: Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("haushalt"), 0.8)) }), delay: .milliseconds(150))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [weak, slow]), slowChunkSize: 2, saveInterval: .zero)
        let run = Task { try await service.categorizeUncategorized() }
        try await Task.sleep(for: .milliseconds(220))
        await service.cancel()
        _ = try? await run.value
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await store.snapshot()
        let done = snapshot.transactions.filter { $0.categoryID != nil }
        #expect(done.allSatisfy { $0.categoryID == "haushalt" }, "no weak guess frozen in place")
        #expect(snapshot.transactions.count { $0.categoryID == nil } >= 2, "the rest waits for the next run")
    }

    @Test func cancelKeepsWhatIsSavedAndStopsBeforeTheNextChunk() async throws {
        let names = (1 ... 6).map { "Laden \($0)" }
        let rows = names.enumerated().map { tx($1, day: $0 + 1) }
        let store = try await makeStore(rows)
        let answers = Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("haushalt"), 0.8)) })
        let slow = SlowStage(answers: answers, delay: .milliseconds(150))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [slow]), slowChunkSize: 2, saveInterval: .zero)
        let run = Task { try await service.categorizeUncategorized() }
        // Cancel as soon as the first chunk is saved (not after a fixed time: CI is slower).
        try await waitUntil { await store.snapshot().transactions.count { $0.categoryID != nil } >= 2 }
        await service.cancel()
        _ = try? await run.value
        try await Task.sleep(for: .milliseconds(400))
        let saved = await store.snapshot().transactions.count { $0.categoryID != nil }
        #expect(saved >= 2 && saved < 6)
        #expect(await slow.log.calls.count <= 2)
        #expect(await service.isRunning == false)
    }
}

/// A slow stage whose model gives up after its first chunk (busy or hung).
private struct GivingUpStage: CategorizationStage {
    let answers: [String: (CategoryID, Double)]
    let calls = CallLog()
    var source: CategorySource { .llm }
    var isSlow: Bool { true }

    func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        await suggestOrStop(transactions, context: context).suggestions
    }

    func suggestOrStop(_ transactions: [Transaction], context: CategorizationContext) async -> (suggestions: [TransactionID: CategorySuggestion], stopped: Bool) {
        await calls.record(transactions.map(\.counterpartName))
        // Answers the first booking of the first chunk, then gives up.
        guard await calls.calls.count == 1, let first = transactions.first, let (id, c) = answers[first.counterpartName] else { return ([:], true) }
        return ([first.id: CategorySuggestion(categoryID: id, source: .llm, confidence: c)], true)
    }
}

@Suite struct SlowModelSavingTests {
    @Test func aModelThatGivesUpLeavesTheRestOpen() async throws {
        let names = (1 ... 6).map { "Shop \($0)" }
        let rows = names.enumerated().map { tx($1, day: $0 + 1) }
        let store = try await makeStore(rows)
        let weak = TableStage(source: .knn, answers: Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("sonstiges"), 0.5)) }))
        let model = GivingUpStage(answers: Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("haushalt"), 0.8)) }))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [weak, model]), slowChunkSize: 2, saveInterval: .zero)
        try await service.categorizeUncategorized()
        let snapshot = await store.snapshot()
        #expect(snapshot.transactions.count { $0.categoryID == "haushalt" } == 1, "what the model answered is kept")
        #expect(snapshot.transactions.count { $0.categoryID == nil } == 5, "no weak guess saved for the rest")
        #expect(await model.calls.calls.count == 1, "no further chunks after giving up")
    }

    @Test func backgroundResultsAreWrittenTogether() async throws {
        let names = (1 ... 8).map { "Markt \($0)" }
        let rows = names.enumerated().map { tx($1, day: $0 + 1) }
        let store = try await makeStore(rows)
        let slow = SlowStage(answers: Dictionary(uniqueKeysWithValues: names.map { ($0, (CategoryID("lebensmittel"), 0.8)) }), delay: .milliseconds(30))
        let service = CategorizationService(store: store, categorizer: Categorizer(stages: [slow]), slowChunkSize: 2, saveInterval: .seconds(30))
        let before = await store.publishCount
        try await service.categorizeUncategorized()
        #expect(await store.snapshot().transactions.allSatisfy { $0.categoryID == "lebensmittel" })
        // Four chunks, but one write at the first step and one at the end.
        #expect(await store.publishCount - before <= 2)
    }
}

/// Polls `condition` every 10 ms for up to `timeout`; fails the test if it never holds.
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < end else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
