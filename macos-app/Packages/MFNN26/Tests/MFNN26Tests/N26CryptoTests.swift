import CryptoKit
import Foundation
import MFNCore
import Testing
@testable import MFNN26

private func hex(_ string: String) -> [UInt8] {
    let digits = Array(string.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16) ?? 0 }
}

@Suite struct AESCCMTests {
    // NIST SP 800-38C, Appendix C (examples 1–3). The IV length fixes the nonce as in SJCL (15 − L bytes).
    @Test(arguments: [
        ("10111213141516", "0001020304050607", "20212223", 4, "7162015b4dac255d"),
        ("1011121314151617", "000102030405060708090a0b0c0d0e0f", "202122232425262728292a2b2c2d2e2f", 6,
         "d2a1f0e051ea5f62081a7792073d593d1fc64fbfaccd"),
        ("101112131415161718191a1b", "000102030405060708090a0b0c0d0e0f10111213",
         "202122232425262728292a2b2c2d2e2f3031323334353637", 8,
         "e3b201a9f5b71a7a9b1ceaeccd97e70b6176aad9a4428aa5484392fbc1b09951"),
    ])
    func matchesNISTVectors(nonce: String, adata: String, plaintext: String, tagLength: Int, expected: String) throws {
        let key = hex("404142434445464748494a4b4c4d4e4f")
        let sealed = try AESCCM.seal(hex(plaintext), key: key, iv: hex(nonce), adata: hex(adata), tagLength: tagLength)
        #expect(sealed == hex(expected))
        #expect(try AESCCM.open(sealed, key: key, iv: hex(nonce), adata: hex(adata), tagLength: tagLength) == hex(plaintext))
    }

    @Test func rejectsManipulatedCiphertext() throws {
        let key = [UInt8](repeating: 7, count: 32)
        let iv = [UInt8](repeating: 1, count: 16)
        var sealed = try AESCCM.seal(Array("hallo".utf8), key: key, iv: iv, adata: Array("1".utf8), tagLength: 16)
        sealed[0] ^= 1
        #expect(throws: (any Error).self) { try AESCCM.open(sealed, key: key, iv: iv, adata: Array("1".utf8), tagLength: 16) }
    }
}

@Suite struct P384Tests {
    /// CryptoKit is the oracle: aG + bG must have the x of (a + b mod n)G.
    @Test func pointAdditionMatchesCryptoKit() throws {
        var checked = 0
        while checked < 6 {
            let a = P384.KeyAgreement.PrivateKey(), b = P384.KeyAgreement.PrivateKey()
            let sum = P384Arithmetic.order.add(Modulus384.limbs(a.rawRepresentation), Modulus384.limbs(b.rawRepresentation))
            guard let combined = try? P384.KeyAgreement.PrivateKey(rawRepresentation: Modulus384.bytes(sum)) else { continue }
            let x = P384Arithmetic.sumX(a.publicKey.rawRepresentation, b.publicKey.rawRepresentation)
            #expect(x == Array(combined.publicKey.rawRepresentation.prefix(48)))
            checked += 1
        }
    }

    /// d·(qG) = (d·q mod n)G – both coordinates, i.e. the y-recovery picks the right sign (run often enough to hit both).
    @Test func sharedPointHasTheRightY() throws {
        var checked = 0
        while checked < 12 {
            let d = P384.KeyAgreement.PrivateKey(), q = P384.KeyAgreement.PrivateKey()
            let product = P384Arithmetic.order.multiply(Modulus384.limbs(d.rawRepresentation), Modulus384.limbs(q.rawRepresentation))
            guard let combined = try? P384.KeyAgreement.PrivateKey(rawRepresentation: Modulus384.bytes(product)) else { continue }
            #expect(try N26KEM.sharedPoint(privateKey: d, publicKey: q.publicKey) == combined.publicKey.rawRepresentation)
            // Symmetric, as SJCL's kem/unkem rely on.
            #expect(try N26KEM.sharedPoint(privateKey: q, publicKey: d.publicKey) == combined.publicKey.rawRepresentation)
            checked += 1
        }
    }

    @Test func fieldInverse() {
        let field = P384Arithmetic.field
        let value = Modulus384.limbs(hex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
        #expect(field.multiply(value, field.inverse(value)) == [1, 0, 0, 0, 0, 0])
    }

    @Test func curveCheck() {
        for _ in 0..<4 {
            var point = Array(P384.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            #expect(P384Arithmetic.isOnCurve(point))
            point[95] ^= 1
            #expect(!P384Arithmetic.isOnCurve(point))
        }
        #expect(!P384Arithmetic.isOnCurve([UInt8](repeating: 0, count: 96)))
    }

    @Test func incrementCarries() {
        #expect(N26KEM.increment([0x00, 0xFF, 0xFF]) == [0x01, 0x00, 0x00])
        #expect(N26KEM.increment([0xFF, 0xFF]) == nil)
    }
}

@Suite struct PayloadCipherTests {
    @Test func producesSJCLEnvelopeTheBankCanOpen() throws {
        let cipher = try N26PayloadCipher(pek: TestValues.pek)
        let plaintext = Data(#"{"accountId":"00000000-0000-4000-8000-000000000001"}"#.utf8)
        let payload = try cipher.encrypt(plaintext, timestampMillis: 1_794_295_656_694)

        // Same keys, same order and parameters as the web app (HAR: v 1, iter 10000, ks 256, ts 128, ccm, aes).
        let keys = try NSRegularExpression(pattern: #""([a-z]+)":"#).matches(in: payload, range: NSRange(payload.startIndex..., in: payload))
            .compactMap { Range($0.range(at: 1), in: payload).map { String(payload[$0]) } }
        #expect(keys == ["iv", "v", "iter", "ks", "ts", "mode", "adata", "cipher", "kemtag", "ct"])
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(envelope["v"] as? Int == 1)
        #expect(envelope["iter"] as? Int == 10000)
        #expect(envelope["ks"] as? Int == 256)
        #expect(envelope["ts"] as? Int == 128)
        #expect(envelope["mode"] as? String == "ccm")
        #expect(envelope["cipher"] as? String == "aes")
        #expect(envelope["adata"] as? String == Data("1794295656694".utf8).base64EncodedString())
        // Field lengths of the recorded getTransactionsList payload (52-byte plaintext).
        #expect((envelope["iv"] as? String)?.count == 24)
        #expect((envelope["kemtag"] as? String)?.count == 128)
        #expect((envelope["ct"] as? String)?.count == 92)

        #expect(try BankCrypto.decrypt(payload) == plaintext)
    }

    @Test func freshKeyAndIVPerRequest() throws {
        let cipher = try N26PayloadCipher(pek: TestValues.pek)
        let first = try cipher.encrypt(Data("{}".utf8), timestampMillis: 1)
        let second = try cipher.encrypt(Data("{}".utf8), timestampMillis: 1)
        #expect(first != second)
    }

    @Test func rejectsUnreadableKey() {
        #expect(throws: ConnectorError.self) { try N26PayloadCipher(pek: "kein-schlüssel") }
        #expect(throws: ConnectorError.self) { try N26PayloadCipher(pek: Data(count: 96).base64EncodedString()) } // not on the curve
    }
}
