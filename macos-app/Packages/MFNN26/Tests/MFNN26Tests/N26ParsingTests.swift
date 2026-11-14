import Foundation
import MFNCore
import Testing
@testable import MFNN26

private let account = Account(id: "n26-test-main", connectionID: TestValues.connection, type: .giro, name: "Hauptkonto")

private func page(_ name: String) throws -> N26TimelinePage {
    let data = try N26JSON.data(try N26Fixtures.data(name), operation: "test")
    if let feed = data["feed"] as? [String: Any] { return try N26TimelinePage.fromFeed(feed) }
    return try N26TimelinePage(timelineContainer: data["timeline"] as? [String: Any], context: "test")
}

@Suite struct N26QueryTests {
    /// The connector sends the queries exactly as the web app does (Fixtures/N26/*.graphql from the HAR).
    @Test func queriesMatchTheRecordedOnes() throws {
        let feed = String(decoding: try N26Fixtures.data("getTransactionsList.graphql"), as: UTF8.self)
        let timeline = String(decoding: try N26Fixtures.data("getTimeline.graphql"), as: UTF8.self)
        #expect(N26Queries.transactionsList == feed.trimmingCharacters(in: .newlines))
        #expect(N26Queries.timeline == timeline.trimmingCharacters(in: .newlines))
    }
}

@Suite struct N26ParsingTests {
    @Test func accountSwitcherOfTheOverview() throws {
        let data = try N26JSON.data(try N26Fixtures.data("feed-all.json"), operation: "test")
        let feed = try N26JSON.decode(N26Feed.self, from: try #require(data["feed"]), context: "test")
        let values = try #require(feed.activities?.values)
        #expect(values.map(\.kind) == [.all, .main, .space, .space])
        #expect(values.map(\.accountId) == [nil, TestValues.mainID, TestValues.space1ID, TestValues.space2ID])
        #expect(values.map(\.title) == ["Alle Aktivitäten", "Hauptkonto", "Space 01", "Space 02"])
    }

    @Test func balancesInCents() throws {
        for (name, expected) in [("feed-space-2.json", 62547)] {
            let data = try N26JSON.data(try N26Fixtures.data(name), operation: "test")
            let feed = try N26JSON.decode(N26Feed.self, from: try #require(data["feed"]), context: "test")
            #expect(try feed.balance?.money?.cents(context: "test") == expected)
        }
    }

    @Test func firstPageSkipsHeadingsAndKeepsTheKey() throws {
        let first = try page("feed-main.json")
        #expect(first.items.count == 15)
        #expect(first.paginationKey == (try FixtureBank.paginationKey(of: "feed-main.json")))
        let second = try page("timeline-main-page2.json")
        #expect(second.items.count == 20)
        #expect(second.paginationKey != nil)
        #expect(try page("feed-space-2.json").paginationKey == nil)
    }

    @Test func mapsTransactions() throws {
        let items = try page("feed-main.json").items
        let transactions = try items.map { try N26Mapper.transaction($0.value, raw: $0.raw, account: account) }
        #expect(transactions.allSatisfy { $0.status == .booked && $0.currency == "EUR" && $0.bookingDate == $0.valueDate })
        #expect(transactions.allSatisfy { $0.externalID != nil && $0.id.rawValue.hasPrefix("ext:") })
        #expect(transactions.allSatisfy { !$0.counterpartName.isEmpty })
        // Income is positive, spending negative; the fixture has both.
        #expect(transactions.contains { $0.amountCents > 0 } && transactions.contains { $0.amountCents < 0 })
        // Raw JSON is the item itself.
        let raw = try #require(try JSONSerialization.jsonObject(with: transactions[0].rawJSON) as? [String: Any])
        #expect(raw["__typename"] as? String == "FeedTimelineTransaction")
        #expect(raw["externalId"] as? String == transactions[0].externalID)
        // Amounts exactly as unscaledAmount (minor units).
        for (item, transaction) in zip(items, transactions) {
            #expect(item.value.styledAmount?.money?.unscaledAmount?.value == transaction.amountCents)
        }
    }

    @Test func dayIsTheBerlinCalendarDayOfTheTimestamp() throws {
        var item = try #require(try page("feed-main.json").items.first).value
        item.timestamp = 1_793_487_599_000 // 2026-10-31 23:59:59 CET = 22:59:59 UTC
        let transaction = try N26Mapper.transaction(item, raw: Data("{}".utf8), account: account)
        #expect(transaction.valueDate == BankDay(iso: "2026-10-31"))
        item.timestamp = 1_793_487_600_000 // 2026-11-01 00:00 CET
        #expect(try N26Mapper.transaction(item, raw: Data("{}".utf8), account: account).valueDate == BankDay(iso: "2026-11-01"))
    }

    @Test func purposeFromSubtitle() throws {
        let items = try page("feed-main.json").items
        let online = try #require(items.first { $0.value.tintedSubtitle?.text == "Online" })
        #expect(try N26Mapper.transaction(online.value, raw: online.raw, account: account).purpose == "Online")
    }

    @Test func pendingMarkers() throws {
        var item = try #require(try page("feed-main.json").items.first).value
        #expect(!N26Mapper.isPending(item))
        item.icon = .init(type: "MERCHANT", statusIcon: .init(lightUrl: "https://cdn.number26.de/feed/status/light/pending.png"))
        #expect(N26Mapper.isPending(item))
        let pending = try N26Mapper.transaction(item, raw: Data("{}".utf8), account: account)
        #expect(pending.status == .pending && pending.bookingDate == nil)

        item.icon = .init(type: "MERCHANT", statusIcon: .init(lightUrl: "https://cdn.number26.de/feed/status/light/installment_eligible.png"))
        #expect(!N26Mapper.isPending(item))
        item.tintedSubtitle = .init(elements: [.init(value: "Ausstehend")])
        #expect(N26Mapper.isPending(item))
        // Free text that merely contains the word does not count.
        item.tintedSubtitle = .init(elements: [.init(value: "Rechnung ausstehend Mai")])
        #expect(!N26Mapper.isPending(item))
    }

    @Test func centsAreExact() throws {
        func money(_ amount: String, decimals: Int) throws -> N26Money {
            try JSONDecoder().decode(N26Money.self, from: Data(#"{"unscaledAmount":"\#(amount)","currency":{"code":"EUR","decimals":\#(decimals)}}"#.utf8))
        }
        #expect(try money("-1299", decimals: 2).cents(context: "t") == -1299)
        #expect(try money("12", decimals: 0).cents(context: "t") == 1200)
        #expect(try money("12340", decimals: 3).cents(context: "t") == 1234)
        #expect(throws: ConnectorError.self) { try money("12345", decimals: 3).cents(context: "t") }
        #expect(throws: ConnectorError.self) { try money("abc", decimals: 2).cents(context: "t") }
    }

    @Test func graphQLErrors() throws {
        #expect(throws: ConnectorError.sessionExpired) {
            try N26JSON.data(Data(#"{"errors":[{"message":"401 Unauthorized"}],"data":null}"#.utf8), operation: "t")
        }
        #expect(throws: ConnectorError.formatChanged(detail: "N26 t: GraphQL-Fehler")) {
            try N26JSON.data(Data(#"{"errors":[{"message":"secret detail"}],"data":null}"#.utf8), operation: "t")
        }
        #expect(throws: ConnectorError.formatChanged(detail: "N26 t: kein gültiges JSON")) {
            try N26JSON.data(Data("<html>".utf8), operation: "t")
        }
    }

    @Test func bootstrapFromHTML() throws {
        let values = try #require(N26Bootstrap.parse(TestValues.html))
        #expect(values.csrfToken == TestValues.csrfToken)
        #expect(values.pek == TestValues.pek)
        // Attribute order reversed, double quotes around the key.
        let other = #"<meta content="abc" name="csrf-token"><script>window.__PEK__="QUJD"</script>"#
        #expect(N26Bootstrap.parse(other)?.csrfToken == "abc")
        #expect(N26Bootstrap.parse(other)?.pek == "QUJD")
        #expect(N26Bootstrap.parse("<html></html>") == nil)
    }
}

@Suite struct N26ExpiredSessionTests {
    private func answer(_ json: String) -> Result<[String: Any], ConnectorError> {
        do { return .success(try N26JSON.data(Data(json.utf8), operation: "getTransactionsList")) } catch { return .failure(error) }
    }

    private func isExpired(_ json: String) -> Bool {
        if case .failure(.sessionExpired) = answer(json) { true } else { false }
    }

    /// Live 2026-11-10: 20 minutes after the login the bank answered with `feed: null`.
    @Test func nullFieldWithErrorIsExpired() {
        #expect(isExpired(#"{"data":{"feed":null},"errors":[{"message":"Something went wrong","path":["feed"]}]}"#))
    }

    @Test func errorCodesMarkExpiry() {
        #expect(isExpired(#"{"data":null,"errors":[{"message":"x","extensions":{"code":"UNAUTHENTICATED"}}]}"#))
        #expect(isExpired(#"{"data":null,"errors":[{"message":"x","extensions":{"code":"FORBIDDEN"}}]}"#))
        #expect(isExpired(#"{"data":null,"errors":[{"message":"Request failed with status 403"}]}"#))
    }

    @Test func otherErrorsStayFormatChanged() {
        #expect(!isExpired(#"{"data":null,"errors":[{"message":"Cannot query field","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}"#))
        // Partial data: one field null, another present → not an expiry.
        #expect(!isExpired(#"{"data":{"feed":null,"other":{"a":1}},"errors":[{"message":"x"}]}"#))
    }

    @Test func errorCodesAreSanitised() {
        let codes = N26JSON.errorCodes([
            ["extensions": ["code": "UNAUTHENTICATED"]],
            ["extensions": ["code": "user alice@example.com"]],
            ["extensions": ["status": 401]],
            ["message": "no extensions"],
        ])
        #expect(codes == ["UNAUTHENTICATED", "401"])
    }
}
