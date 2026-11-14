import Foundation
import MFNCore
import Observation

/// State of the "Kategorien einrichten" assistant: overview → income → fixed costs → frequent
/// counterparts → transfers → rest → done.
///
/// Every decision is a normal `CategoryRule` (applied right away), so cancelling keeps what was
/// decided. After each decision the plan is computed again; the candidate lists of the steps keep
/// their order (new candidates are appended, covered ones stay visible as done), so nothing jumps.
@MainActor
@Observable
final class CategorySetup: Identifiable {
    enum Step: Int, CaseIterable, Identifiable {
        case overview, income, fixedCost, counterparty, transfer, rest, done
        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Überblick"
            case .income: "Einnahmen"
            case .fixedCost: "Fixkosten"
            case .counterparty: "Häufige Gegenparteien"
            case .transfer: "Umbuchungen"
            case .rest: "Rest"
            case .done: "Fertig"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "chart.pie"
            case .income: "arrow.down.circle"
            case .fixedCost: "calendar"
            case .counterparty: "person.2"
            case .transfer: "arrow.left.arrow.right"
            case .rest: "list.bullet"
            case .done: "checkmark.circle"
            }
        }

        var kind: SetupPlan.Candidate.Kind? {
            switch self {
            case .income: .income
            case .fixedCost: .fixedCost
            case .counterparty: .counterparty
            case .transfer: .transfer
            default: nil
            }
        }

        init?(kind: SetupPlan.Candidate.Kind) {
            switch kind {
            case .income: self = .income
            case .fixedCost: self = .fixedCost
            case .counterparty: self = .counterparty
            case .transfer: self = .transfer
            }
        }
    }

    /// What happened to a candidate in this session.
    enum Outcome: Equatable {
        /// The user chose a category; `ruleID` is the rule it became (re-deciding edits it).
        case decided(CategoryID, ruleID: UUID)
        case skipped
    }

    let id = UUID()
    private(set) var step: Step = .overview
    private(set) var plan: SetupPlan?
    /// Plan when the assistant opened: the overview's "mit n Entscheidungen ~z %".
    private(set) var initialPlan: SetupPlan?
    /// Candidate IDs per step in first-seen order.
    private(set) var order: [Step: [String]] = [:]
    /// Last known data of every candidate seen, also of those no longer in the plan.
    private(set) var known: [String: SetupPlan.Candidate] = [:]
    private(set) var outcomes: [String: Outcome] = [:]
    /// Current candidate per step.
    private(set) var position: [Step: Int] = [:]
    private(set) var isWorking = false
    private(set) var error: String?
    /// Rest step: selected transactions.
    var restSelection: Set<TransactionID> = []
    /// ⌘K picker: for the current candidate (`nil` IDs) or the rest selection.
    var picker: CategoryPickerRequest?

    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Plan

    /// Loads the plan (first time) or recomputes it after a decision.
    func refresh() async {
        guard let plan = await model.setupPlan() else { return }
        merge(plan)
    }

    /// Stable lists: known IDs keep their place, new ones are appended to their step.
    private func merge(_ plan: SetupPlan) {
        self.plan = plan
        if initialPlan == nil { initialPlan = plan }
        for candidate in plan.candidates {
            known[candidate.id] = candidate
            guard let step = Step(kind: candidate.kind) else { continue }
            if !(order.values.contains { $0.contains(candidate.id) }) {
                order[step, default: []].append(candidate.id)
            }
        }
    }

    /// Candidates of a step in their stable order.
    func candidates(of step: Step) -> [SetupPlan.Candidate] {
        (order[step] ?? []).compactMap { known[$0] }
    }

    /// In the current plan: still has open transactions.
    func isOpen(_ candidate: SetupPlan.Candidate) -> Bool {
        plan?.candidates.contains { $0.id == candidate.id } ?? false
    }

    /// Done without a decision here: another rule covered its transactions meanwhile.
    func isCovered(_ candidate: SetupPlan.Candidate) -> Bool {
        outcomes[candidate.id] == nil && !isOpen(candidate)
    }

    var currentIndex: Int { position[step] ?? 0 }

    var current: SetupPlan.Candidate? {
        let list = candidates(of: step)
        return list.indices.contains(currentIndex) ? list[currentIndex] : nil
    }

    /// Number of decisions taken in this session.
    var decisionCount: Int {
        outcomes.values.count { if case .decided = $0 { true } else { false } }
    }

    /// Open candidates of a step (for the step list).
    func openCount(of step: Step) -> Int {
        candidates(of: step).count { isOpen($0) && outcomes[$0.id] == nil }
    }

    // MARK: Navigation

    func go(to step: Step) {
        self.step = step
        error = nil
        if step.kind != nil, position[step] == nil {
            position[step] = firstPending(in: step, from: 0) ?? 0
        }
        if step == .rest { restSelection = [] }
    }

    /// "Weiter": next step; steps without candidates are passed over.
    func nextStep() {
        var next = Step(rawValue: step.rawValue + 1)
        while let candidate = next, candidate.kind != nil, candidates(of: candidate).isEmpty {
            next = Step(rawValue: candidate.rawValue + 1)
        }
        if let next { go(to: next) }
    }

    func previousStep() {
        var previous = Step(rawValue: step.rawValue - 1)
        while let candidate = previous, candidate.kind != nil, candidates(of: candidate).isEmpty {
            previous = Step(rawValue: candidate.rawValue - 1)
        }
        if let previous { go(to: previous) }
    }

    func select(_ candidate: SetupPlan.Candidate) {
        guard let index = candidates(of: step).firstIndex(where: { $0.id == candidate.id }) else { return }
        position[step] = index
    }

    /// ⇥: leaves the candidate open and moves on.
    func skip() {
        guard let current, !isWorking else { return }
        if outcomes[current.id] == nil { outcomes[current.id] = .skipped }
        advance()
    }

    /// ⌫: back to the previous candidate (or the previous step at the first one).
    func back() {
        guard !isWorking else { return }
        if currentIndex > 0 {
            position[step] = currentIndex - 1
        } else {
            previousStep()
        }
    }

    /// Next candidate still waiting after the current one; at the end, the next step.
    private func advance() {
        if let next = firstPending(in: step, from: currentIndex + 1) {
            position[step] = next
        } else {
            nextStep()
        }
    }

    private func firstPending(in step: Step, from start: Int) -> Int? {
        let list = candidates(of: step)
        guard start < list.count else { return nil }
        return list.indices[start...].first { outcomes[list[$0].id] == nil && isOpen(list[$0]) }
    }

    // MARK: Deciding

    /// The categories behind the number keys 1–9: the plan's alternatives (suggestion first),
    /// filled up with typical categories of the step so there is always something to pick.
    func choices(for candidate: SetupPlan.Candidate) -> [CategoryID] {
        var result: [CategoryID] = []
        for id in [candidate.suggestion?.categoryID].compactMap(\.self) + candidate.alternatives + Self.typical(candidate)
        where !result.contains(id) && CategoryCatalog.info(id) != nil {
            result.append(id)
        }
        return Array(result.prefix(9))
    }

    private static func typical(_ candidate: SetupPlan.Candidate) -> [CategoryID] {
        switch candidate.kind {
        case .income: ["gehalt", "erstattung", "zinsen", "einnahmen_sonstige", "umbuchung"]
        case .fixedCost: ["miete", "nebenkosten", "internet_telefon", "versicherung", "abos", "sport", "kredit", "steuern", "sparen_anlegen"]
        case .transfer: ["umbuchung", "sparen_anlegen", "kredit", "bargeld"]
        case .counterparty:
            candidate.totalCents > 0
                ? ["erstattung", "einnahmen_sonstige", "umbuchung", "gehalt"]
                : ["lebensmittel", "restaurant", "online_shopping", "drogerie", "tanken", "freizeit", "haushalt", "kleidung", "sonstiges"]
        }
    }

    /// ⏎: takes the suggestion (or the first choice if MFN has none).
    func acceptSuggestion() {
        guard let current, let category = current.suggestion?.categoryID ?? choices(for: current).first else { return }
        decide(category)
    }

    /// 1–9.
    func choose(number: Int) {
        guard let current else { return }
        let list = choices(for: current)
        guard list.indices.contains(number - 1) else { return }
        decide(list[number - 1])
    }

    /// ⌘K: the full catalog for the current candidate.
    func showPickerForCurrent() {
        guard let current, !isWorking else { return }
        let existing: CategoryID? = if case let .decided(category, _) = outcomes[current.id] { category } else { nil }
        picker = CategoryPickerRequest(transactionIDs: [], title: current.title, current: existing ?? current.suggestion?.categoryID)
    }

    /// The rule for the current candidate. Deciding again on the same candidate edits its rule.
    func decide(_ category: CategoryID) {
        guard let candidate = current, !isWorking else { return }
        let previousRule: UUID? = if case let .decided(_, ruleID) = outcomes[candidate.id] { ruleID } else { nil }
        let rule = CategoryRule(id: previousRule ?? UUID(), match: candidate.match, categoryID: category)
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            if let message = await model.saveRule(rule) {
                error = message
                return
            }
            outcomes[candidate.id] = .decided(category, ruleID: rule.id)
            await refresh()
            advance()
        }
    }

    // MARK: Rest

    /// Open transactions (no trusted category), largest amounts first. Sorted once per snapshot
    /// revision (the rest step reads it several times per render).
    var openTransactions: [MFNCore.Transaction] {
        let revision = model.snapshotRevision
        if let cache = openCache, cache.revision == revision { return cache.transactions }
        let open = model.snapshot.transactions
            .filter { $0.status != .cancelled && !Self.isTrusted($0) }
            .sorted { abs($0.amountCents) > abs($1.amountCents) }
        openCache = (revision, open)
        return open
    }

    @ObservationIgnored private var openCache: (revision: Int, transactions: [MFNCore.Transaction])?

    /// Same notion of "categorized" as `SetupPlan`.
    static func isTrusted(_ transaction: MFNCore.Transaction) -> Bool {
        transaction.categoryID != nil
            && (transaction.categorySource == .manual || (transaction.confidence ?? 0) >= Categorizer.reviewThreshold)
    }

    func showPickerForRest() {
        guard !restSelection.isEmpty, !isWorking else { return }
        let targets = model.transactions(restSelection)
        guard !targets.isEmpty else { return }
        let categories = Set(targets.map(\.categoryID))
        picker = CategoryPickerRequest(
            transactionIDs: targets.map(\.id),
            title: targets.count == 1 ? targets[0].counterpartName : "\(targets.count) Umsätze",
            current: categories.count == 1 ? categories.first ?? nil : nil
        )
    }

    /// Picker result: a rule for the current candidate, or manual categories for the rest.
    func picked(_ category: CategoryID?, request: CategoryPickerRequest) {
        picker = nil
        if request.transactionIDs.isEmpty {
            if let category { decide(category) }
            return
        }
        let ids = request.transactionIDs
        isWorking = true
        Task {
            defer { isWorking = false }
            if let message = await model.setManualCategory(category, for: ids) {
                error = message
                return
            }
            restSelection.subtract(ids)
            await refresh()
        }
    }

    // MARK: Texts

    static func sourceText(_ suggestion: CategorySuggestion) -> String {
        switch suggestion.source {
        case .rule:
            if abs(suggestion.confidence - KnownMerchantStage.confidence) < 0.001 { "bekannter Händler" }
            else if abs(suggestion.confidence - TransferStage.confidence) < 0.001 { "Umbuchung erkannt" }
            else { "Regel" }
        case .knn: "ähnlich"
        case .llm: "KI"
        case .manual: "manuell"
        }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "de_DE")))
    }
}
