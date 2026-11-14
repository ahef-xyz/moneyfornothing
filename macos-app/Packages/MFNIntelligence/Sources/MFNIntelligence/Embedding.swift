import Accelerate
import Foundation
import NaturalLanguage

/// Turns booking texts into unit vectors; cosine distance (`1 − dot`) compares them.
/// Implementations are local only (no network) and cache their results.
public protocol TextEmbedding: Sendable {
    /// `nil` if no embedding model is available; then kNN and few-shot selection are skipped.
    func vectors(for texts: [TransactionText]) async -> [TransactionText: [Float]]?
}

/// Vector helpers (unit vectors throughout).
enum VectorMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        return vDSP.dot(a[..<n], b[..<n])
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = dot(v, v).squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine distance of two unit vectors, 0 (same) … 2 (opposite).
    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        Double(max(0, 1 - dot(a, b)))
    }
}

/// Character trigrams and words, hashed into a fixed number of buckets (FNV-1a, deterministic).
/// Needs no model; robust for merchant names ("REWE Markt", "REWE City") and German compounds.
public struct CharacterNGramEmbedding: Sendable {
    public let dimensions: Int

    public init(dimensions: Int = 1024) {
        self.dimensions = dimensions
    }

    public func vector(for text: String) -> [Float]? {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        let words = String(folded).split(separator: " ").filter { $0.count >= 2 }
        guard !words.isEmpty else { return nil }
        var v = [Float](repeating: 0, count: dimensions)
        for (index, word) in words.enumerated() {
            // Whole word: strong signal for exact merchant tokens; the first word is usually the brand
            // ("MCDONALDS MAINZ", "REWE Markt"), so it counts most.
            v[bucket("w:" + word)] += index == 0 ? 4 : 2
            let chars = Array(" " + word + " ")
            if chars.count >= 3 {
                for i in 0 ... chars.count - 3 { v[bucket(String(chars[i ..< i + 3]))] += 1 }
            }
        }
        return VectorMath.normalized(v)
    }

    private func bucket(_ s: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(dimensions))
    }
}

/// `NLEmbedding.sentenceEmbedding(for: .german)`: semantic similarity ("Stromabschlag" ~ "Abschlag Gas").
/// `NLEmbedding` is not `Sendable`, so it lives in this actor.
public actor SentenceEmbedding {
    private var model: NLEmbedding?
    private var loaded = false

    public init() {}

    public var isAvailable: Bool {
        loadIfNeeded()
        return model != nil
    }

    public func vector(for text: String) -> [Float]? {
        loadIfNeeded()
        guard let model, !text.isEmpty, let v = model.vector(for: text) else { return nil }
        return VectorMath.normalized(v.map(Float.init))
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        model = NLEmbedding.sentenceEmbedding(for: .german)
    }
}

/// The default embedding: merchant trigrams, purpose trigrams and the German sentence embedding,
/// each a unit vector, concatenated with weights whose squares sum to 1 (so the cosine of the
/// whole is the weighted mean of the parts). Missing parts are left out and the rest re-weighted.
///
/// With `requiresSentenceModel` the embedding reports "no model" when `NLEmbedding` has no German
/// sentence model; by default the trigram parts carry on alone.
public actor HybridEmbedding: TextEmbedding {
    public struct Weights: Sendable {
        public var merchant: Double
        public var purpose: Double
        public var sentence: Double

        public init(merchant: Double = 0.6, purpose: Double = 0.25, sentence: Double = 0.15) {
            self.merchant = merchant
            self.purpose = purpose
            self.sentence = sentence
        }
    }

    private let ngrams: CharacterNGramEmbedding
    private let sentence: SentenceEmbedding?
    private let weights: Weights
    private let requiresSentenceModel: Bool
    private var cache: [TransactionText: [Float]] = [:]
    private let cacheLimit: Int

    public init(weights: Weights = Weights(), useSentenceModel: Bool = true, requiresSentenceModel: Bool = false, cacheLimit: Int = 50_000) {
        ngrams = CharacterNGramEmbedding()
        sentence = useSentenceModel ? SentenceEmbedding() : nil
        self.weights = weights
        self.requiresSentenceModel = requiresSentenceModel
        self.cacheLimit = cacheLimit
    }

    public func vectors(for texts: [TransactionText]) async -> [TransactionText: [Float]]? {
        let sentenceAvailable = await sentence?.isAvailable ?? false
        if requiresSentenceModel, !sentenceAvailable { return nil }
        var result: [TransactionText: [Float]] = [:]
        for text in texts {
            if let cached = cache[text] { result[text] = cached; continue }
            let v = await vector(for: text, sentenceAvailable: sentenceAvailable)
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[text] = v
            result[text] = v
        }
        return result
    }

    private func vector(for text: TransactionText, sentenceAvailable: Bool) async -> [Float] {
        let dims = ngrams.dimensions
        let merchant = ngrams.vector(for: text.merchant)
        let purpose = ngrams.vector(for: text.signalPurpose)
        let semantic = sentenceAvailable ? await sentence?.vector(for: text.embeddingText) : nil
        let parts: [([Float]?, Double, Int)] = [
            (merchant, weights.merchant, dims),
            (purpose, weights.purpose, dims),
            (semantic, weights.sentence, semantic?.count ?? 0),
        ]
        // Re-weight over the parts present; absent parts become zeros (dimension stays fixed per part).
        let present = parts.filter { $0.0 != nil }.map(\.1).reduce(0, +)
        var out: [Float] = []
        out.reserveCapacity(dims * 2 + 512)
        for (vector, weight, count) in parts {
            let scale = present > 0 ? Float((weight / present).squareRoot()) : 0
            if let vector { out += vector.map { $0 * scale } } else { out += [Float](repeating: 0, count: count) }
        }
        return out
    }
}
