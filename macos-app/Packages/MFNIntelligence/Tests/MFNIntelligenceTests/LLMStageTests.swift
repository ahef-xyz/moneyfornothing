import Foundation
import MFNCore
import Testing
@testable import MFNIntelligence

/// Scripted model: answers every booking with `lebensmittel`, fails as told.
private final class FakeModel: CategoryLanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    let maxBatch: Int
    let forbidden: String?
    let busyAfter: Int?

    init(maxBatch: Int = 12, forbidden: String? = nil, busyAfter: Int? = nil) {
        self.maxBatch = maxBatch
        self.forbidden = forbidden
        self.busyAfter = busyAfter
    }

    var prompts: [String] { lock.withLock { _prompts } }
    var isAvailable: Bool { true }
    func prewarm(instructions: String) {}

    func answer(prompt: String, instructions: String) async throws -> LLMBatchAnswer {
        let calls = lock.withLock { _prompts.append(prompt); return _prompts.count }
        if let busyAfter, calls > busyAfter { throw LLMFailure.busy }
        let numbers = prompt.split(separator: "\n").compactMap { line -> Int? in
            guard let dot = line.firstIndex(of: "."), line.contains("Händler:") else { return nil }
            return Int(line[..<dot])
        }
        if numbers.count > maxBatch { throw LLMFailure.contextExceeded }
        if let forbidden, prompt.split(separator: "Buchungen:").last?.contains(forbidden) == true { throw LLMFailure.guardrail }
        return LLMBatchAnswer(zuordnungen: numbers.map { LLMAssignment(nummer: $0, kategorie: .lebensmittel, sicherheit: 80) })
    }
}

private func bookings(_ count: Int) -> [Transaction] {
    (0 ..< count).map { i in
        let day = BankDay(year: 2026, month: 11, day: 2)!
        return Transaction(id: TransactionID("t\(i)"), accountID: "a1", bookingDate: day, valueDate: day, amountCents: -(100 + i),
                           counterpartName: "Laden \(i)", purpose: "Einkauf \(i == 5 ? "Wettbuero" : "Ware")", status: .booked)
    }
}

@Suite struct LLMStageTests {
    @Test func batchesOfTenWithAFreshCallEach() async {
        let model = FakeModel()
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false))
        let result = await stage.suggest(bookings(25), context: CategorizationContext())
        #expect(result.count == 25)
        #expect(model.prompts.count == 3)
        #expect(result.values.allSatisfy { $0.source == .llm && $0.confidence == 0.8 })
    }

    @Test func contextOverflowHalvesTheBatch() async {
        let model = FakeModel(maxBatch: 3)
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false))
        let result = await stage.suggest(bookings(10), context: CategorizationContext())
        #expect(result.count == 10)
        // 10 → 5 + 5 → (2 + 3) + (2 + 3): 1 + 2 + 4 calls.
        #expect(model.prompts.count == 7)
    }

    @Test func guardrailSkipsOnlyTheOffendingBooking() async {
        let model = FakeModel(forbidden: "Wettbuero")
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false))
        let result = await stage.suggest(bookings(10), context: CategorizationContext())
        #expect(result.count == 9)
        #expect(result["t5"] == nil)
    }

    @Test func busyModelStopsTheRunButKeepsEarlierBatches() async {
        let model = FakeModel(busyAfter: 1)
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false))
        let result = await stage.suggest(bookings(30), context: CategorizationContext())
        #expect(result.count == 10)
        #expect(model.prompts.count == 2)
    }

    @Test func fewShotsComeFromSimilarLabeledBookings() async {
        let model = FakeModel()
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false))
        let day = BankDay(year: 2026, month: 10, day: 1)!
        let history = [
            Transaction(id: "h1", accountID: "a1", bookingDate: day, valueDate: day, amountCents: -900, counterpartName: "Laden 1",
                        purpose: "Einkauf Ware", status: .booked, categoryID: "lebensmittel", categorySource: .manual),
        ]
        _ = await stage.suggest(Array(bookings(2)), context: CategorizationContext(labeled: history))
        let prompt = model.prompts.first ?? ""
        #expect(prompt.contains("Beispiele"))
        #expect(prompt.contains("→ lebensmittel"))
    }
}
