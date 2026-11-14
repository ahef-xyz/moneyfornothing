/// Deterministic PRNG (SplitMix64). Same seed → same dataset, on every machine and run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func pick<T>(_ items: [T]) -> T {
        // Callers pass non-empty literal arrays.
        items[Int.random(in: 0..<items.count, using: &self)]
    }
}
