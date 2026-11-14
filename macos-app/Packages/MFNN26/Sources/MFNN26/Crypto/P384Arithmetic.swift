import Foundation

/// Modular arithmetic for one odd 384-bit modulus (Montgomery form, 6 × 64-bit limbs, little endian).
///
/// Only what the SJCL-compatible key encapsulation needs (`N26KEM`): CryptoKit's ECDH hands out the
/// x-coordinate of the shared point, SJCL hashes x‖y. To pick the right y we add one point in affine
/// coordinates – a handful of field operations, no scalar multiplication. Not constant time; it only
/// touches the ephemeral shared point of a single request, never a long-lived secret.
struct Modulus384: Sendable {
    typealias Limbs = [UInt64]

    let m: Limbs
    private let m0inv: UInt64
    private let r2: Limbs

    /// - Parameter hex: big-endian hex digits of an odd modulus < 2^384 with the top bit set.
    init(hex: String) {
        let limbs = Self.limbs(hex: hex)
        m = limbs
        var inverse: UInt64 = 1
        for _ in 0..<7 { inverse = inverse &* (2 &- limbs[0] &* inverse) } // Newton: limbs[0]^-1 mod 2^64
        m0inv = 0 &- inverse
        var value: Limbs = [1, 0, 0, 0, 0, 0]
        for _ in 0..<768 { value = Self.addMod(value, value, limbs) } // 2^768 mod m = R² mod m
        r2 = value
    }

    // MARK: Conversion

    static func limbs(_ bigEndian: some Collection<UInt8>) -> Limbs {
        precondition(bigEndian.count == 48, "programming error: 384-bit values are 48 bytes")
        let bytes = Array(bigEndian)
        var limbs = Limbs(repeating: 0, count: 6)
        for index in 0..<48 {
            limbs[(47 - index) / 8] |= UInt64(bytes[index]) << (8 * UInt64((47 - index) % 8))
        }
        return limbs
    }

    static func bytes(_ limbs: Limbs) -> [UInt8] {
        (0..<48).map { index in UInt8(truncatingIfNeeded: limbs[(47 - index) / 8] >> (8 * UInt64((47 - index) % 8))) }
    }

    static func limbs(hex: String) -> Limbs {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return limbs(bytes)
    }

    // MARK: Plain arithmetic (inputs reduced, i.e. < m)

    func isReduced(_ a: Limbs) -> Bool { !Self.greaterOrEqual(a, m) }

    func add(_ a: Limbs, _ b: Limbs) -> Limbs { Self.addMod(a, b, m) }

    func subtract(_ a: Limbs, _ b: Limbs) -> Limbs {
        let (difference, borrow) = Self.sub(a, b)
        return borrow ? Self.addIgnoringCarry(difference, m) : difference
    }

    func multiply(_ a: Limbs, _ b: Limbs) -> Limbs {
        fromMontgomery(montgomeryMultiply(toMontgomery(a), toMontgomery(b)))
    }

    /// a^(m-2) – the inverse for a prime modulus; 0 stays 0.
    func inverse(_ a: Limbs) -> Limbs {
        var exponent = m
        exponent[0] &-= 2 // m is odd and > 2: no borrow
        let base = toMontgomery(a)
        var result = toMontgomery([1, 0, 0, 0, 0, 0])
        for limb in exponent.reversed() {
            for bit in (0..<64).reversed() {
                result = montgomeryMultiply(result, result)
                if (limb >> UInt64(bit)) & 1 == 1 { result = montgomeryMultiply(result, base) }
            }
        }
        return fromMontgomery(result)
    }

    // MARK: Montgomery

    private func toMontgomery(_ a: Limbs) -> Limbs { montgomeryMultiply(a, r2) }
    private func fromMontgomery(_ a: Limbs) -> Limbs { montgomeryMultiply(a, [1, 0, 0, 0, 0, 0]) }

    /// CIOS: a · b · R⁻¹ mod m.
    private func montgomeryMultiply(_ a: Limbs, _ b: Limbs) -> Limbs {
        var t = [UInt64](repeating: 0, count: 8)
        for i in 0..<6 {
            var carry: UInt64 = 0
            for j in 0..<6 {
                let (high, low) = a[j].multipliedFullWidth(by: b[i])
                let (sum1, overflow1) = t[j].addingReportingOverflow(low)
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                t[j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0) // full sum < 2^128
            }
            let (top, topOverflow) = t[6].addingReportingOverflow(carry)
            t[6] = top
            t[7] = topOverflow ? 1 : 0

            let factor = t[0] &* m0inv
            let (high0, low0) = factor.multipliedFullWidth(by: m[0])
            let (_, overflow0) = t[0].addingReportingOverflow(low0)
            carry = high0 &+ (overflow0 ? 1 : 0)
            for j in 1..<6 {
                let (high, low) = factor.multipliedFullWidth(by: m[j])
                let (sum1, overflow1) = t[j].addingReportingOverflow(low)
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                t[j - 1] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            let (sum6, overflow6) = t[6].addingReportingOverflow(carry)
            t[5] = sum6
            t[6] = t[7] &+ (overflow6 ? 1 : 0)
            t[7] = 0
        }
        let result = Array(t[0..<6])
        return t[6] != 0 || Self.greaterOrEqual(result, m) ? Self.sub(result, m).difference : result
    }

    // MARK: Limb helpers

    private static func addMod(_ a: Limbs, _ b: Limbs, _ m: Limbs) -> Limbs {
        var sum = Limbs(repeating: 0, count: 6)
        var carry = false
        for index in 0..<6 {
            let (partial, overflow1) = a[index].addingReportingOverflow(b[index])
            let (total, overflow2) = partial.addingReportingOverflow(carry ? 1 : 0)
            sum[index] = total
            carry = overflow1 || overflow2
        }
        return carry || greaterOrEqual(sum, m) ? sub(sum, m).difference : sum
    }

    private static func addIgnoringCarry(_ a: Limbs, _ b: Limbs) -> Limbs {
        var sum = Limbs(repeating: 0, count: 6)
        var carry = false
        for index in 0..<6 {
            let (partial, overflow1) = a[index].addingReportingOverflow(b[index])
            let (total, overflow2) = partial.addingReportingOverflow(carry ? 1 : 0)
            sum[index] = total
            carry = overflow1 || overflow2
        }
        return sum
    }

    private static func sub(_ a: Limbs, _ b: Limbs) -> (difference: Limbs, borrow: Bool) {
        var difference = Limbs(repeating: 0, count: 6)
        var borrow = false
        for index in 0..<6 {
            let (partial, overflow1) = a[index].subtractingReportingOverflow(b[index])
            let (total, overflow2) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            difference[index] = total
            borrow = overflow1 || overflow2
        }
        return (difference, borrow)
    }

    private static func greaterOrEqual(_ a: Limbs, _ b: Limbs) -> Bool {
        for index in (0..<6).reversed() where a[index] != b[index] {
            return a[index] > b[index]
        }
        return true
    }
}

/// NIST P-384 (secp384r1) constants and the one point operation `N26KEM` needs.
enum P384Arithmetic {
    /// Field prime p = 2^384 − 2^128 − 2^96 + 2^32 − 1.
    static let field = Modulus384(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff")
    /// Group order n (same constant as `sjcl.ecc.curves.c384`).
    static let order = Modulus384(hex: "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973")

    /// x-coordinate (48 bytes, big endian) of P + Q for two affine points given as x‖y (96 bytes each).
    /// `nil` if xP == xQ (P = ±Q: doubling or infinity, never needed here) or a coordinate is not reduced.
    static func sumX(_ p: some Collection<UInt8>, _ q: some Collection<UInt8>) -> [UInt8]? {
        let (pBytes, qBytes) = (Array(p), Array(q))
        guard pBytes.count == 96, qBytes.count == 96 else { return nil }
        let px = Modulus384.limbs(pBytes[0..<48]), py = Modulus384.limbs(pBytes[48..<96])
        let qx = Modulus384.limbs(qBytes[0..<48]), qy = Modulus384.limbs(qBytes[48..<96])
        guard [px, py, qx, qy].allSatisfy(field.isReduced), px != qx else { return nil }
        let slope = field.multiply(field.subtract(qy, py), field.inverse(field.subtract(qx, px)))
        let x = field.subtract(field.subtract(field.multiply(slope, slope), px), qx)
        return Modulus384.bytes(x)
    }

    /// Curve coefficient b (y² = x³ − 3x + b).
    static let b = Modulus384.limbs(hex: "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef")

    /// The point x‖y (96 bytes) satisfies the curve equation. CryptoKit's `rawRepresentation` initialiser does not
    /// check this for every input (an all-zero key is accepted).
    static func isOnCurve(_ point: some Collection<UInt8>) -> Bool {
        let bytes = Array(point)
        guard bytes.count == 96 else { return false }
        let x = Modulus384.limbs(bytes[0..<48]), y = Modulus384.limbs(bytes[48..<96])
        guard field.isReduced(x), field.isReduced(y) else { return false }
        let x3 = field.multiply(field.multiply(x, x), x)
        let threeX = field.add(field.add(x, x), x)
        return field.multiply(y, y) == field.add(field.subtract(x3, threeX), b)
    }

    /// p − y (the y-coordinate of the negated point).
    static func negateY(_ y: some Collection<UInt8>) -> [UInt8] {
        let limbs = Modulus384.limbs(y)
        return Modulus384.bytes(field.subtract([0, 0, 0, 0, 0, 0], limbs))
    }
}
