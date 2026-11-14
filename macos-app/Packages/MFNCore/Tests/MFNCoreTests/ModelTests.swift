import Foundation
import Testing
@testable import MFNCore

@Suite struct BankDayTests {
    @Test func parsesAndFormatsISO() throws {
        let day = try #require(BankDay(iso: "2026-02-28"))
        #expect(day.iso == "2026-02-28")
        #expect(BankDay(iso: "2026-02-30") == nil)
        #expect(BankDay(iso: "garbage") == nil)
    }

    @Test func usesBerlinTimeZone() throws {
        // 2026-03-31 22:30 UTC is already April 1st in Berlin (CEST, UTC+2).
        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-31T22:30:00Z"))
        #expect(BankDay(date).iso == "2026-04-01")
    }

    @Test func arithmeticAcrossMonthEnds() throws {
        let day = try #require(BankDay(iso: "2026-01-31"))
        #expect(day.adding(days: 1).iso == "2026-02-01")
        #expect(day.adding(months: 1).iso == "2026-02-28")
        #expect(day.days(to: day.adding(days: 10)) == 10)
    }

    @Test func codableAsISOString() throws {
        let day = try #require(BankDay(iso: "2025-12-24"))
        let data = try JSONEncoder().encode([day])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2025-12-24\"]")
        #expect(try JSONDecoder().decode([BankDay].self, from: data) == [day])
    }
}

@Suite struct FingerprintTests {
    let day = BankDay(iso: "2026-05-04")

    @Test func stableAndHex() {
        let a = Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -1299, purpose: "Miete Mai", counterpartIBAN: "DE00 1234")
        let b = Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -1299, purpose: "Miete Mai", counterpartIBAN: "DE00 1234")
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func ignoresWrappingCaseAndIBANSpacing() {
        // MT940 wraps purpose lines at 27 characters, sometimes mid-word.
        let wrapped = Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -1299, purpose: "RECHNUNG 4711 STROM ABSCHL\nAG MAI", counterpartIBAN: "de00 1234")
        let plain = Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -1299, purpose: "Rechnung 4711 Strom Abschlag Mai", counterpartIBAN: "DE001234")
        #expect(wrapped == plain)
    }

    @Test func differsOnEveryField() {
        let base = Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -100, purpose: "x", counterpartIBAN: nil)
        #expect(base != Fingerprint.make(accountID: "other", bookingDate: day, amountCents: -100, purpose: "x", counterpartIBAN: nil))
        #expect(base != Fingerprint.make(accountID: "acc", bookingDate: day?.adding(days: 1), amountCents: -100, purpose: "x", counterpartIBAN: nil))
        #expect(base != Fingerprint.make(accountID: "acc", bookingDate: nil, amountCents: -100, purpose: "x", counterpartIBAN: nil))
        #expect(base != Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: 100, purpose: "x", counterpartIBAN: nil))
        #expect(base != Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -100, purpose: "y", counterpartIBAN: nil))
        #expect(base != Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -100, purpose: "x", counterpartIBAN: "DE00"))
    }

    @Test func transactionComputesFingerprintAndID() throws {
        let day = try #require(day)
        let t = Transaction(accountID: "acc", bookingDate: day, valueDate: day, amountCents: -500, counterpartName: "Bäcker", purpose: "Brot", status: .booked)
        #expect(t.fingerprint == Fingerprint.make(accountID: "acc", bookingDate: day, amountCents: -500, purpose: "Brot", counterpartIBAN: nil))
        #expect(t.id.rawValue == "fp:\(t.fingerprint)")
        let withExternal = Transaction(accountID: "acc", bookingDate: day, valueDate: day, amountCents: -500, counterpartName: "Bäcker", purpose: "Brot", status: .booked, externalID: "tr-1")
        #expect(withExternal.id == "ext:tr-1")
    }

    @Test func uniquingIDsKeepsFingerprint() throws {
        let day = try #require(day)
        let coffee = Transaction(accountID: "acc", bookingDate: day, valueDate: day, amountCents: -350, counterpartName: "Café", purpose: "Kaffee", status: .booked)
        let result = Transaction.uniquingIDs([coffee, coffee, coffee])
        #expect(result.map(\.id.rawValue) == [coffee.id.rawValue, coffee.id.rawValue + "#2", coffee.id.rawValue + "#3"])
        #expect(Set(result.map(\.fingerprint)).count == 1)
    }
}

@Suite struct SecurityPositionTests {
    @Test func valueRoundsFractionalShares() {
        let position = SecurityPosition(accountID: "d", isin: "IE00B4L5Y983", name: "ETF", quantity: Decimal(string: "12.3456") ?? 0, priceCents: 10_123, asOf: .now)
        // 12.3456 × 10123 = 124 974.5088 → 124 975
        #expect(position.valueCents == 124_975)
    }

    @Test func gainAgainstPurchasePrice() {
        var position = SecurityPosition(accountID: "d", isin: "IE00B4L5Y983", name: "ETF", quantity: 10, priceCents: 11_000, asOf: .now)
        #expect(position.gainCents == nil && position.gainRatio == nil)
        position.purchasePriceCents = 10_000
        #expect(position.purchaseValueCents == 100_000)
        #expect(position.gainCents == 10_000)
        #expect(position.gainRatio == 0.1)
        position.priceCents = 9_000
        #expect(position.gainCents == -10_000)
    }
}

@Suite struct RedactionTests {
    @Test func secretsNeverInDescriptions() {
        let response = AuthResponse.code("123456")
        #expect(!String(describing: response).contains("123456"))
        #expect(!String(reflecting: response).contains("123456"))
        let cookie = SessionCookie(name: "tr_session", value: "s3cr3t", domain: "example.invalid")
        #expect(!String(describing: cookie).contains("s3cr3t"))
        #expect(!String(describing: AuthResponse.webSession([cookie])).contains("s3cr3t"))
    }
}

@Suite struct WebLoginRequestCodingTests {
    /// Exactly what protocol v1 wrote into the persisted sync state (no `storageKeys`).
    private let v1JSON = Data(#"""
    {"authRequired":{"_0":{"webLogin":{"_0":{"url":"https://banking.example.invalid/login","completion":{"cookiesPresent":{"_0":["SESSION"]}},"cookieDomains":["example.invalid"],"message":"Bitte anmelden"}}}}}
    """#.utf8)

    @Test func decodesV1JSONWithoutStorageKeys() throws {
        let error = try JSONDecoder().decode(ConnectorError.self, from: v1JSON)
        guard case let .authRequired(.webLogin(request)) = error else {
            Issue.record("wrong case \(error)")
            return
        }
        #expect(request.storageKeys.isEmpty)
        #expect(request.completion == .cookiesPresent(["SESSION"]))
        #expect(request.cookieDomains == ["example.invalid"])
        #expect(request.url.absoluteString == "https://banking.example.invalid/login")
        #expect(request.message == "Bitte anmelden")
    }

    @Test func v1InitialiserDefaultsToNoStorageKeys() throws {
        let url = try #require(URL(string: "https://banking.example.invalid/login"))
        let request = WebLoginRequest(url: url, completion: .urlPrefix("https://banking.example.invalid/home"), cookieDomains: ["example.invalid"], message: "m")
        #expect(request.storageKeys.isEmpty)
        // A v1 value equals its decoded v1 JSON counterpart, so persisted challenges stay comparable.
        let decoded = try JSONDecoder().decode(WebLoginRequest.self, from: Data(#"{"url":"https://banking.example.invalid/login","completion":{"urlPrefix":{"_0":"https://banking.example.invalid/home"}},"cookieDomains":["example.invalid"],"message":"m"}"#.utf8))
        #expect(decoded == request)
    }

    @Test func storageKeysRoundTrip() throws {
        let url = try #require(URL(string: "https://banking.example.invalid/login"))
        let request = WebLoginRequest(
            url: url,
            completion: .cookiesPresent(["sessionStore"]),
            cookieDomains: ["example.invalid"],
            message: "m",
            storageKeys: [
                StorageKey(key: "sessionStore", source: .sessionStorage, domain: "banking.example.invalid"),
                StorageKey(key: "device", source: .localStorage, domain: "banking.example.invalid"),
            ]
        )
        let data = try JSONEncoder().encode(AuthChallenge.webLogin(request))
        #expect(try JSONDecoder().decode(AuthChallenge.self, from: data) == .webLogin(request))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""source":"sessionStorage""#))
        #expect(json.contains(#""source":"localStorage""#))
    }
}
