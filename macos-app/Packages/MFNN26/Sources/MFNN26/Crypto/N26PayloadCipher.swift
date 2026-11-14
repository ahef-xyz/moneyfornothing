import CommonCrypto
import CryptoKit
import Foundation
import MFNCore

/// Encrypts GraphQL variables exactly like the N26 web app (chunk `1917` of `app.n26.com`):
///
/// ```js
/// sjcl.encrypt(new sjcl.ecc.elGamal.publicKey(sjcl.ecc.curves.c384, sjcl.codec.base64.toBits(window.__PEK__)),
///              JSON.stringify(variables), { ts: 128, ks: 256, adata: Date.now().toString() })
/// ```
///
/// - KEM (`sjcl.ecc.elGamal.publicKey.kem`): ephemeral scalar d, `kemtag` = d·G (x‖y),
///   key = SHA-256(x‖y of d·PEK). CryptoKit only exposes x of d·PEK, `N26KEM` recovers y.
/// - AES-256-CCM (RFC 3610), 16-byte random IV of which CCM uses the first 15 − L bytes, 128-bit tag,
///   associated data = the millisecond timestamp as UTF-8 text.
/// - Output: SJCL's JSON string with keys in SJCL order (iv, v, iter, ks, ts, mode, adata, cipher, kemtag, ct).
///
/// The payload only hides the variables (account IDs, pagination keys) in transit; it carries no credentials
/// (the login runs in the web view).
///
/// UNVERIFIED: interoperability with the real SJCL/server is derived from the bundle source and tested against NIST
/// CCM vectors and CryptoKit, not against an SJCL-produced payload. If the bank rejects every payload, look here first.
struct N26PayloadCipher: Sendable {
    let publicKey: P384.KeyAgreement.PublicKey

    /// - Parameter pek: `window.__PEK__` (base64 of x‖y, 96 bytes).
    init(pek: String) throws(ConnectorError) {
        guard let raw = Data(base64Encoded: pek.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 96, P384Arithmetic.isOnCurve(raw),
              let key = try? P384.KeyAgreement.PublicKey(rawRepresentation: raw)
        else {
            throw .formatChanged(detail: "N26: Verschlüsselungsschlüssel (__PEK__) unlesbar")
        }
        publicKey = key
    }

    /// SJCL JSON for `plaintext`. `ephemeral` and `iv` are injectable for tests only.
    func encrypt(_ plaintext: Data, timestampMillis: Int64, ephemeral: P384.KeyAgreement.PrivateKey? = nil, iv: [UInt8]? = nil) throws(ConnectorError) -> String {
        let (key, tag) = try encapsulate(ephemeral)
        let iv = iv ?? Self.randomBytes(16)
        let adata = Data(String(timestampMillis).utf8)
        let ct = try AESCCM.seal(Array(plaintext), key: key, iv: iv, adata: Array(adata), tagLength: 16)
        // Key order as SJCL emits it; all values are base64 or fixed tokens, nothing needs escaping.
        return #"{"iv":"\#(Data(iv).base64EncodedString())","v":1,"iter":10000,"ks":256,"ts":128,"mode":"ccm","#
            + #""adata":"\#(adata.base64EncodedString())","cipher":"aes","kemtag":"\#(tag.base64EncodedString())","ct":"\#(Data(ct).base64EncodedString())"}"#
    }

    private func encapsulate(_ fixed: P384.KeyAgreement.PrivateKey?) throws(ConnectorError) -> (key: [UInt8], tag: Data) {
        // d + 1 must stay below the group order; a fresh scalar fixes the (≈ 2^-384) exception.
        for _ in 0..<4 {
            let ephemeral = fixed ?? P384.KeyAgreement.PrivateKey()
            if let point = try? N26KEM.sharedPoint(privateKey: ephemeral, publicKey: publicKey) {
                return (Array(SHA256.hash(data: point)), ephemeral.publicKey.rawRepresentation)
            }
            if fixed != nil { break }
        }
        throw .formatChanged(detail: "N26: Schlüsselaustausch fehlgeschlagen")
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// SJCL ElGamal KEM on P-384 with CryptoKit.
enum N26KEM {
    struct Failure: Error {}

    /// Full shared point d·Q as x‖y (96 bytes) – what `sjcl.ecc.elGamal` hashes.
    ///
    /// CryptoKit's ECDH yields x(d·Q). Decompressing x gives the candidate with even y; the other candidate is
    /// its negation. ECDH with d + 1 yields x(d·Q + Q), which only the right candidate reproduces when Q is added.
    static func sharedPoint(privateKey: P384.KeyAgreement.PrivateKey, publicKey: P384.KeyAgreement.PublicKey) throws -> Data {
        let x = try sharedX(privateKey, publicKey)
        let candidate = try P384.KeyAgreement.PublicKey(compressedRepresentation: [0x02] + x).rawRepresentation
        guard let next = increment(Array(privateKey.rawRepresentation)) else { throw Failure() }
        let shifted = try P384.KeyAgreement.PrivateKey(rawRepresentation: next)
        let expected = try sharedX(shifted, publicKey)
        guard let sum = P384Arithmetic.sumX(candidate, publicKey.rawRepresentation) else { throw Failure() }
        if sum == expected { return candidate }
        return Data(x + P384Arithmetic.negateY(candidate.suffix(48)))
    }

    private static func sharedX(_ privateKey: P384.KeyAgreement.PrivateKey, _ publicKey: P384.KeyAgreement.PublicKey) throws -> [UInt8] {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Array($0) }
    }

    /// Big-endian + 1; `nil` on overflow (never for a valid scalar < n).
    static func increment(_ bytes: [UInt8]) -> [UInt8]? {
        var result = bytes
        for index in result.indices.reversed() {
            if result[index] == 0xFF {
                result[index] = 0
            } else {
                result[index] += 1
                return result
            }
        }
        return nil
    }
}

/// AES-CCM (RFC 3610 / NIST SP 800-38C) over CommonCrypto's AES block cipher, SJCL parameter rules:
/// L = max(2, bytes needed for the message length), nonce = first 15 − L bytes of the IV.
enum AESCCM {
    struct Failure: Error {}

    static func seal(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8], adata: [UInt8], tagLength: Int) throws(ConnectorError) -> [UInt8] {
        do {
            let cipher = try BlockCipher(key: key)
            let (nonce, lengthSize) = try parameters(iv: iv, messageLength: plaintext.count)
            let mac = try cbcMAC(cipher, nonce: nonce, lengthSize: lengthSize, adata: adata, message: plaintext, tagLength: tagLength)
            let stream = try keystream(cipher, nonce: nonce, lengthSize: lengthSize, count: plaintext.count + 16)
            let ciphertext = zip(plaintext, stream.dropFirst(16)).map { $0 ^ $1 }
            let tag = zip(mac, stream.prefix(tagLength)).map { $0 ^ $1 }
            return ciphertext + tag
        } catch {
            throw .formatChanged(detail: "N26: Verschlüsselung fehlgeschlagen")
        }
    }

    /// Inverse of `seal`; throws if the tag does not match. Used by tests (fake bank) and for SJCL vectors.
    static func open(_ sealed: [UInt8], key: [UInt8], iv: [UInt8], adata: [UInt8], tagLength: Int) throws -> [UInt8] {
        guard sealed.count >= tagLength else { throw Failure() }
        let cipher = try BlockCipher(key: key)
        let messageLength = sealed.count - tagLength
        let (nonce, lengthSize) = try parameters(iv: iv, messageLength: messageLength)
        let stream = try keystream(cipher, nonce: nonce, lengthSize: lengthSize, count: messageLength + 16)
        let plaintext = zip(sealed.prefix(messageLength), stream.dropFirst(16)).map { $0 ^ $1 }
        let mac = try cbcMAC(cipher, nonce: nonce, lengthSize: lengthSize, adata: adata, message: plaintext, tagLength: tagLength)
        let tag = zip(mac, stream.prefix(tagLength)).map { $0 ^ $1 }
        guard tag == Array(sealed.suffix(tagLength)) else { throw Failure() }
        return plaintext
    }

    private static func parameters(iv: [UInt8], messageLength: Int) throws -> (nonce: [UInt8], lengthSize: Int) {
        guard iv.count >= 7 else { throw Failure() }
        var lengthSize = 2
        while lengthSize < 4, messageLength >> (8 * lengthSize) != 0 { lengthSize += 1 }
        lengthSize = max(lengthSize, 15 - iv.count)
        return (Array(iv.prefix(15 - lengthSize)), lengthSize)
    }

    private static func cbcMAC(_ cipher: BlockCipher, nonce: [UInt8], lengthSize: Int, adata: [UInt8], message: [UInt8], tagLength: Int) throws -> [UInt8] {
        var b0 = [UInt8((adata.isEmpty ? 0 : 0x40) | ((tagLength - 2) / 2) << 3 | (lengthSize - 1))] + nonce
        b0 += bigEndian(message.count, size: lengthSize)

        var input = b0
        if !adata.isEmpty {
            var encoded: [UInt8]
            if adata.count < 0xFF00 {
                encoded = bigEndian(adata.count, size: 2)
            } else {
                encoded = [0xFF, 0xFE] + bigEndian(adata.count, size: 4)
            }
            encoded += adata
            input += padded(encoded)
        }
        input += padded(message)

        var state = [UInt8](repeating: 0, count: 16)
        for offset in stride(from: 0, to: input.count, by: 16) {
            state = try cipher.encrypt(zip(state, input[offset..<offset + 16]).map { $0 ^ $1 })
        }
        return Array(state.prefix(tagLength))
    }

    /// E(A0) ‖ E(A1) ‖ … with A_i = flags(L − 1) ‖ nonce ‖ i.
    private static func keystream(_ cipher: BlockCipher, nonce: [UInt8], lengthSize: Int, count: Int) throws -> [UInt8] {
        var stream: [UInt8] = []
        var counter = 0
        while stream.count < count {
            stream += try cipher.encrypt([UInt8(lengthSize - 1)] + nonce + bigEndian(counter, size: lengthSize))
            counter += 1
        }
        return Array(stream.prefix(count))
    }

    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        let remainder = bytes.count % 16
        return remainder == 0 ? bytes : bytes + [UInt8](repeating: 0, count: 16 - remainder)
    }

    private static func bigEndian(_ value: Int, size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * (size - 1 - $0))) }
    }

    /// One AES block in ECB mode (the CCM building block).
    private struct BlockCipher {
        let key: [UInt8]

        init(key: [UInt8]) throws {
            guard [16, 24, 32].contains(key.count) else { throw Failure() }
            self.key = key
        }

        func encrypt(_ block: [UInt8]) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: 16)
            var moved = 0
            let status = CCCrypt(
                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                key, key.count, nil, block, block.count, &output, output.count, &moved
            )
            guard status == kCCSuccess, moved == 16 else { throw Failure() }
            return output
        }
    }
}
