import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNC24

@Suite struct C24ParsingTests {
    @Test(arguments: [
        ("-1222.01", -122_201), ("2170.00", 217_000), ("0", 0), ("0.00", 0), ("7,09 €", 709),
        ("1.234,56 €", 123_456), ("1,234.56", 123_456), ("−0,99", -99), ("150000", 15_000_000),
        // Dot followed by exactly three digits and no comma: thousands separator.
        ("1.234 €", 123_400), ("-1.234", -123_400), ("1.234.567", 123_456_700), ("12.5", 1_250), ("1.2345", 123),
    ])
    func amountText(_ text: String, _ cents: Int) {
        #expect(C24Amount.cents(fromText: text) == cents)
    }

    @Test func amountJSON() throws {
        func decode(_ json: String) throws -> Int { try JSONDecoder().decode(C24Amount.self, from: Data(json.utf8)).cents }
        #expect(try decode(#""-34.95""#) == -3_495)
        #expect(try decode("-19.99") == -1_999)
        #expect(try decode("0.07") == 7)
        #expect(throws: (any Error).self) { try decode(#""abc""#) }
    }

    @Test(arguments: [
        ("2026-11-09T09:13:47+01:00", "2026-11-09"),
        ("2026-09-30T00:00:00+02:00", "2026-09-30"),
        ("2026-11-02T23:30:00Z", "2026-11-03"), // 00:30 in Berlin
        ("09.11.2026", "2026-11-09"),
        ("02.11.2026 05:36 Uhr", "2026-11-02"),
        ("2026-11-22", "2026-11-22"),
    ])
    func dates(_ text: String, _ expected: String) {
        #expect(C24Day.parse(text) == BankDay(iso: expected))
    }

    @Test func invalidDates() {
        #expect(C24Day.parse("2026-02-30") == nil)
        #expect(C24Day.parse("gestern") == nil)
    }

    @Test func accountKinds() {
        #expect(C24AccountKind(accountType: "CURRENT_ACCOUNT") == .giro)
        #expect(C24AccountKind(productType: "pocket_plus") == .pocketPlus)
        #expect(C24AccountKind(productType: "joint_pocket") == .pocket)
        #expect(C24AccountKind(productType: "fixed_deposit") == .unknown("fixed_deposit"))
    }

    @Test func formatChangeReportsPathNotValues() {
        let data = Data(#"{"pagination":{"more":false},"transactions":[{"id":"geheim-42","amount":true,"date":"2026-11-01T10:00:00+01:00"}]}"#.utf8)
        do {
            _ = try C24SearchPage(data: data)
            Issue.record("expected formatChanged")
        } catch {
            guard case let .formatChanged(detail) = error else { Issue.record("wrong error"); return }
            #expect(detail.contains("transactions.[0]"))
            #expect(!detail.contains("geheim"))
            #expect(!detail.contains("true"))
        }
    }

    @Test func searchRequestMatchesRecordedBody() throws {
        let request = C24SearchRequest(criteria: .init(accountNumbers: ["3238114929"]), pagination: .init(limit: 30, offset: 30))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect((json["criteria"] as? [String: Any])?["account_numbers"] as? [String] == ["3238114929"])
        #expect(json["pagination"] as? [String: Int] == ["limit": 30, "offset": 30])
    }
}

@Suite struct C24SessionStoreTests {
    private func token(_ raw: String) -> String? { C24SessionStore.accessToken(in: raw, field: "accessToken") }

    @Test func extractsTokenAndIgnoresOtherFields() {
        #expect(token(TestValues.storeValue(token: "abc")) == "abc")
        #expect(token(#"  {"accessToken":" abc ","nested":{"accessToken":"other"}}  "#) == "abc")
    }

    @Test func toleratesEncodings() {
        let json = #"{"accessToken":"abc"}"#
        #expect(token(json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") == "abc")
        let doubleEncoded = String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
        #expect(token(doubleEncoded) == "abc")
    }

    @Test(arguments: ["", "kein-json", "{kaputt", "[]", "42", #"{"refreshToken":"x"}"#, #"{"accessToken":""}"#, #"{"accessToken":123}"#, #"{"accessToken":null}"#])
    func rejectsUnusableValues(_ raw: String) {
        #expect(token(raw) == nil)
    }
}

/// Every recorded fixture decodes completely with the production models.
@Suite struct C24FixtureTests {
    @Test func accountsFixture() throws {
        let response = try C24JSON.decode(C24AccountsResponse.self, from: Fixtures.data(.c24, "accounts.json"), context: "Fixture")
        #expect(response.accounts.count == 2)
        #expect(response.accounts.allSatisfy { C24AccountKind(accountType: $0.accountType) == .giro })
        let pockets = try #require(response.pockets)
        #expect(pockets.count == 5)
        #expect(pockets.allSatisfy { if case .unknown = C24AccountKind(productType: $0.productType) { false } else { true } })
    }

    @Test func pocketsFixtureMatchesAccountList() throws {
        let pockets = try C24JSON.decode(C24PocketsResponse.self, from: Fixtures.data(.c24, "pockets.json"), context: "Fixture").pockets
        let embedded = try C24JSON.decode(C24AccountsResponse.self, from: Fixtures.data(.c24, "accounts.json"), context: "Fixture").pockets ?? []
        #expect(Set(pockets.map(\.pocketNumber)) == Set(embedded.map(\.pocketNumber)))
    }

    @Test(arguments: ["transactions-page1.json", "transactions-page2.json", "transactions-other-pocket-page1.json"])
    func transactionFixture(_ name: String) throws {
        let page = try C24SearchPage(data: Fixtures.data(.c24, name))
        #expect(page.items.count == 30)
        #expect(page.pagination?.more == true)
        let account = Account(id: "fixture", connectionID: "fixture", type: .tagesgeld, name: "Fixture")
        for item in page.items {
            let transaction = try C24Mapper.transaction(item.value, raw: item.raw, account: account)
            #expect(transaction.status == .booked)
            #expect(transaction.bookingDate != nil)
            #expect(item.value.detail("Buchungsdatum") != nil)
        }
        // Paging relies on this order (newest first by sort_date).
        let sortDays = page.items.compactMap { $0.value.sortDate.flatMap(C24Day.parse) }
        #expect(sortDays == sortDays.sorted(by: >))
    }

    @Test func upcomingFixture() throws {
        let data = try Fixtures.data(.c24, "upcoming-transactions.json")
        #expect(try C24JSON.items(C24StandingOrder.self, in: data, key: "standing_orders", context: "Fixture").count == 5)
        #expect(try C24JSON.items(C24DirectDebit.self, in: data, key: "direct_debits", context: "Fixture").count == 2)
    }

    /// Becomes relevant once the human records an expired session (gap in endpoints.md).
    @Test(.enabled(if: Fixtures.exists(.c24, "session-expired.json"))) func sessionExpiredFixtureExists() throws {
        #expect(!(try Fixtures.data(.c24, "session-expired.json")).isEmpty)
    }
}
