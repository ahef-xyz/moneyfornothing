import Foundation
import MFNCore

/// The labeled history as vectors, searched by brute force (a few thousand bookings at most).
struct NeighbourIndex: Sendable {
    struct Entry: Sendable {
        let transaction: Transaction
        let category: CategoryID
        let vector: [Float]
    }

    struct Neighbour: Sendable {
        let entry: Entry
        let distance: Double
    }

    let entries: [Entry]
    /// Query vectors by transaction.
    let queryVectors: [TransactionID: [Float]]

    /// Distance added when income meets expense (refund vs purchase at the same merchant).
    static let signPenalty = 0.3

    /// `nil` if the embedding has no model.
    static func build(labeled: [Transaction], queries: [Transaction], embedding: any TextEmbedding) async -> NeighbourIndex? {
        let usable = labeled.filter { $0.categoryID != nil && $0.status != .cancelled }
        let usableTexts = usable.map(TransactionText.init)
        let queryTexts = queries.map(TransactionText.init)
        guard let vectors = await embedding.vectors(for: Array(Set(usableTexts + queryTexts))) else { return nil }
        let entries = zip(usable, usableTexts).compactMap { t, text -> Entry? in
            guard let category = t.categoryID, let v = vectors[text] else { return nil }
            return Entry(transaction: t, category: category, vector: v)
        }
        var queryVectors: [TransactionID: [Float]] = [:]
        for (t, text) in zip(queries, queryTexts) { queryVectors[t.id] = vectors[text] }
        return NeighbourIndex(entries: entries, queryVectors: queryVectors)
    }

    /// The `k` nearest, nearest first; ties keep history order. Partial selection (a sorted
    /// buffer of `k`) instead of sorting every entry: `k` is small, the history is not.
    func neighbours(of query: Transaction, k: Int) -> [Neighbour] {
        guard k > 0, let v = queryVectors[query.id] else { return [] }
        let queryIncome = query.amountCents > 0
        var nearest: [Neighbour] = []
        nearest.reserveCapacity(k + 1)
        for entry in entries where entry.transaction.id != query.id {
            var d = VectorMath.distance(v, entry.vector)
            if (entry.transaction.amountCents > 0) != queryIncome { d += Self.signPenalty }
            if nearest.count == k, let last = nearest.last, d >= last.distance { continue }
            // After all equal distances, so earlier entries win ties.
            let position = nearest.firstIndex { $0.distance > d } ?? nearest.endIndex
            nearest.insert(Neighbour(entry: entry, distance: d), at: position)
            if nearest.count > k { nearest.removeLast() }
        }
        return nearest
    }
}

/// Second stage (CLAUDE.md §8): nearest neighbours among the user's own labeled bookings
/// (`context.labeled`, manual + rule). Distance below `directDistance` → take over directly with
/// confidence ≥ 0.9; otherwise a distance-weighted vote of the `k` nearest gives a graded confidence.
public struct KNNStage: CategorizationStage {
    public struct Parameters: Sendable {
        /// Below this cosine distance the nearest neighbour's category is taken over (≥ 0.9).
        public var directDistance: Double
        public var k: Int
        /// Neighbours farther than this do not vote.
        public var maxDistance: Double
        /// A graded (non-direct) suggestion never exceeds this.
        public var gradedCap: Double

        public init(directDistance: Double = 0.15, k: Int = 7, maxDistance: Double = 0.6, gradedCap: Double = 0.89) {
            self.directDistance = directDistance
            self.k = k
            self.maxDistance = maxDistance
            self.gradedCap = gradedCap
        }
    }

    public let source: CategorySource = .knn
    public let embedding: any TextEmbedding
    public var parameters: Parameters

    public init(embedding: any TextEmbedding = HybridEmbedding(), parameters: Parameters = Parameters()) {
        self.embedding = embedding
        self.parameters = parameters
    }

    public func suggest(_ transactions: [Transaction], context: CategorizationContext) async -> [TransactionID: CategorySuggestion] {
        guard !transactions.isEmpty, !context.labeled.isEmpty,
              let index = await NeighbourIndex.build(labeled: context.labeled, queries: transactions, embedding: embedding)
        else { return [:] }
        var result: [TransactionID: CategorySuggestion] = [:]
        for transaction in transactions {
            let neighbours = index.neighbours(of: transaction, k: parameters.k)
            if let suggestion = Self.vote(neighbours, parameters: parameters, query: TransactionText(transaction), queryIncome: transaction.amountCents > 0) {
                result[transaction.id] = suggestion
            }
        }
        return result
    }

    static func vote(_ neighbours: [NeighbourIndex.Neighbour], parameters: Parameters, query: TransactionText? = nil, queryIncome: Bool? = nil) -> CategorySuggestion? {
        let voting = neighbours.filter { $0.distance < parameters.maxDistance }
        guard let nearest = voting.first else { return nil }

        // Direct: the close ones (< directDistance) carry a clear majority.
        let close = voting.filter { $0.distance < parameters.directDistance }
        if !close.isEmpty, let (category, share) = majority(close.map(\.entry.category)), share > 0.5 {
            let best = close.first { $0.entry.category == category }?.distance ?? nearest.distance
            return CategorySuggestion(categoryID: category, source: .knn, confidence: min(0.99, max(0.9, 1 - best)))
        }

        // Direct: same merchant, same direction of money, and every such booking agrees (a learned rule).
        if let query, !query.merchant.isEmpty, let queryIncome {
            let folded = fold(query.merchant)
            let same = voting.filter {
                ($0.entry.transaction.amountCents > 0) == queryIncome && fold(TransactionText($0.entry.transaction).merchant) == folded
            }
            if !same.isEmpty, let (category, share) = majority(same.map(\.entry.category)), share == 1 {
                return CategorySuggestion(categoryID: category, source: .knn, confidence: same.count >= 2 ? 0.9 : 0.86)
            }
        }

        // Graded: weight (1 − d)², share of the winner, falling with the winner's distance.
        var weights: [CategoryID: Double] = [:]
        var closest: [CategoryID: Double] = [:]
        for n in voting {
            let w = pow(max(0, 1 - n.distance), 2)
            weights[n.entry.category, default: 0] += w
            closest[n.entry.category] = min(closest[n.entry.category] ?? .infinity, n.distance)
        }
        let total = weights.values.reduce(0, +)
        guard total > 0, let (category, weight) = weights.max(by: { $0.value < $1.value }) else { return nil }
        let share = weight / total
        let distance = closest[category] ?? 1
        let confidence = min(parameters.gradedCap, share * (0.95 - (distance - parameters.directDistance)))
        return CategorySuggestion(categoryID: category, source: .knn, confidence: max(0, confidence))
    }

    private static func majority(_ categories: [CategoryID]) -> (CategoryID, Double)? {
        guard !categories.isEmpty else { return nil }
        let counts = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
        guard let (category, count) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (category, Double(count) / Double(categories.count))
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
    }
}
