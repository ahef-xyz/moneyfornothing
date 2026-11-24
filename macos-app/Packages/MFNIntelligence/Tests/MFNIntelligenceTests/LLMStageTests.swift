import Synchronization
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
    /// Answer from this call on (1-based) never comes.
    let hangFrom: Int?
    let delay: Duration
    private var _running = 0
    private var _maxRunning = 0

    init(maxBatch: Int = 12, forbidden: String? = nil, busyAfter: Int? = nil, hangFrom: Int? = nil, delay: Duration = .zero) {
        self.maxBatch = maxBatch
        self.forbidden = forbidden
        self.busyAfter = busyAfter
        self.hangFrom = hangFrom
        self.delay = delay
    }

    var maxRunning: Int { lock.withLock { _maxRunning } }

    var prompts: [String] { lock.withLock { _prompts } }
    var isAvailable: Bool { true }
    func prewarm(instructions: String) {}

    func answer(prompt: String, instructions: String) async throws -> LLMBatchAnswer {
        let calls = lock.withLock {
            _prompts.append(prompt)
            _running += 1
            _maxRunning = max(_maxRunning, _running)
            return _prompts.count
        }
        defer { lock.withLock { _running -= 1 } }
        if let hangFrom, calls >= hangFrom {
            // Ignores cancellation, like a stuck framework call.
            let end = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
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

@Suite struct LLMStageLimitsTests {
    @Test func aHangingCallEndsTheModelStageAfterTheTimeLimit() async {
        let model = FakeModel(hangFrom: 2)
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false),
                             parameters: .init(timeout: .milliseconds(200)), isEnabled: { true }, gate: ModelGate())
        let start = ContinuousClock.now
        let result = await stage.suggest(bookings(30), context: CategorizationContext())
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(result.count == 10, "the first batch stays")
        #expect(model.prompts.count == 2)
    }

    @Test func switchedOffAsksNothing() async {
        let model = FakeModel()
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false), isEnabled: { false })
        let result = await stage.suggest(bookings(10), context: CategorizationContext())
        #expect(result.isEmpty)
        #expect(model.prompts.isEmpty)
    }

    @Test func switchingOffStopsAtTheNextBatch() async {
        let model = FakeModel()
        // Off once the first batch was asked.
        let stage = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false), isEnabled: { model.prompts.isEmpty })
        let result = await stage.suggest(bookings(30), context: CategorizationContext())
        #expect(model.prompts.count == 1)
        #expect(result.count == 10)
    }

    @Test func oneModelCallAtATime() async {
        let model = FakeModel(delay: .milliseconds(60))
        let gate = ModelGate()
        let a = LLMStage(model: model, embedding: HybridEmbedding(useSentenceModel: false), parameters: .init(), isEnabled: { true }, gate: gate)
        async let first = a.suggest(bookings(20), context: CategorizationContext())
        async let second = a.suggest(bookings(20), context: CategorizationContext())
        let (x, y) = await (first, second)
        #expect(x.count == 20 && y.count == 20)
        #expect(model.maxRunning == 1)
    }
}

@Suite struct ModelGateTests {
    @Test func afterAHangingCallTheNextFailsAtOnce() async {
        let gate = ModelGate()
        let start = ContinuousClock.now
        await #expect(throws: LLMFailure.busy) {
            try await gate.run(timeout: .milliseconds(100)) { () async throws -> Int in
                let end = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
                return 1
            }
        }
        await #expect(throws: LLMFailure.busy) {
            try await gate.run(timeout: .seconds(30)) { 2 }
        }
        #expect(ContinuousClock.now - start < .seconds(1), "no waiting for the abandoned call")
    }

    @Test func waitingForTheModelIsBoundedAndCancellable() async throws {
        let gate = ModelGate()
        let long = Task { try await gate.run(timeout: .seconds(10)) { () async throws -> Int in try await Task.sleep(for: .milliseconds(800)); return 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        await #expect(throws: LLMFailure.busy) { try await gate.run(timeout: .milliseconds(100)) { 2 } }
        #expect(ContinuousClock.now - start < .milliseconds(600))
        let waiter = Task { try await gate.run(timeout: .seconds(10)) { 3 } }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try await long.value == 1)
        #expect(try await gate.run(timeout: .seconds(1)) { 4 } == 4)
    }
}
