import Foundation
import MFNCore
import Testing
@testable import MFNTradeRepublic

// MARK: - WebSocket client

@Suite struct TRWebSocketClientTests {
    private func client(_ server: FakeTRServer, sleeper: NoSleep = NoSleep(), timeout: TimeInterval = 5) -> TRWebSocketClient {
        TRWebSocketClient(
            configuration: .init(url: URL(fileURLWithPath: "/"), connectMessage: #"connect 35 {"locale":"de"}"#, requestTimeout: timeout),
            transport: server,
            sleeper: sleeper,
            sessionProvider: { _ in "tr_session=test" }
        )
    }

    private func server(failOpens: Int = 0, _ sub: @escaping FakeTRServer.SubHandler) -> FakeTRServer {
        FakeTRServer(failOpens: failOpens, http: { _, _, _, _ in (404, [:], "") }, sub: sub)
    }

    @Test func firstAnswerResolvesAndUnsubscribes() async throws {
        // Later deltas on the same subscription are applied to the last full answer (TRDeltaTests);
        // the request itself returns the first answer and closes the subscription.
        let server = server { _, _ in [.answer(#"{"a":1}"#), .delta("=6\t-1\t+2\t=1")] }
        let json = try await client(server).request(.object(["type": .string("x")]))
        #expect(json["a"]?.int == 1)
        #expect(server.unsubs == [1])
    }

    @Test func deltaWithoutFullAnswerIsFormatChange() async {
        let server = server { _, _ in [.delta("=1")] }
        await #expect(throws: ConnectorError.formatChanged(detail: "Trade-Republic-Delta ohne Vollstand")) {
            _ = try await client(server).request(.object(["type": .string("x")]))
        }
    }

    @Test func reconnectsWithBackoff() async throws {
        let sleeper = NoSleep()
        let server = server(failOpens: 2) { _, _ in [.answer("[]")] }
        let json = try await client(server, sleeper: sleeper).request(.object(["type": .string("cash")]))
        #expect(json == .array([]))
        #expect(sleeper.slept.withLock { $0 } == [1, 2])
        #expect(server.opened == 1)
    }

    @Test func gaveUpAfterThreeAttempts() async {
        let server = server(failOpens: 10) { _, _ in [.answer("[]")] }
        await #expect(throws: ConnectorError.bankUnavailable) { _ = try await client(server).request(.object([:])) }
        #expect(server.openCookies.count == 3)
    }

    @Test func droppedConnectionIsReopened() async throws {
        let server = server { _, connection in connection == 1 ? [.drop] : [.answer(#"{"ok":true}"#)] }
        let json = try await client(server).request(.object([:]))
        #expect(json["ok"]?.bool == true)
        #expect(server.opened == 2)
    }

    @Test func silentServerTimesOut() async {
        let server = server { _, _ in [] }
        await #expect(throws: ConnectorError.bankUnavailable) { _ = try await client(server, timeout: 0.05).request(.object([:])) }
    }

    @Test(arguments: [
        (#"{"errors":[{"errorCode":"AUTHENTICATION_ERROR"}]}"#, ConnectorError.sessionExpired),
        (#"{"errors":[{"errorCode":"TOO_MANY_REQUESTS","meta":{"nextAttemptInSeconds":30}}]}"#, ConnectorError.rateLimited(retryAfter: 30)),
        (#"{"errors":[{"errorCode":"BAD_SUBSCRIPTION_TYPE"}]}"#, ConnectorError.formatChanged(detail: "Trade-Republic-Abo abgelehnt (BAD_SUBSCRIPTION_TYPE)")),
    ])
    func errorsAreTyped(payload: String, expected: ConnectorError) async {
        let server = server { _, _ in [.error(payload)] }
        await #expect(throws: expected) { _ = try await client(server).request(.object([:])) }
    }

    /// A cancelled sync ends the waiting request at once: no 30 s timeout, no reconnect.
    @Test func cancelledRequestEndsWithoutReconnect() async throws {
        let server = server { _, _ in [] }
        let client = client(server, timeout: 30)
        let started = ContinuousClock.now
        let task = Task { try await client.request(.object(["type": .string("cash")])) }
        while server.subs.isEmpty, ContinuousClock.now - started < .seconds(5) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(server.subs.count == 1)
        task.cancel()
        await #expect(throws: ConnectorError.cancelled) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(server.opened == 1)
        #expect(server.openCookies.count == 1)
        #expect(server.unsubs == [1])
    }

    @Test func alreadyCancelledRequestSendsNothing() async {
        let server = server { _, _ in [.answer("[]")] }
        let client = client(server)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.request(.object([:]))
        }
        await #expect(throws: ConnectorError.cancelled) { _ = try await task.value }
        #expect(server.subs.isEmpty)
    }

    @Test func completeWithoutAnswer() async {
        let server = server { _, _ in [.complete] }
        await #expect(throws: ConnectorError.self) { _ = try await client(server).request(.object([:])) }
    }
}

// MARK: - Error mapping

@Suite struct TRErrorMappingTests {
    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost, .serverCertificateUntrusted])
    func networkFailuresAreBankUnavailable(code: URLError.Code) {
        #expect(TRSession.connectorError(URLError(code), taskCancelled: false) == .bankUnavailable)
    }

    @Test func urlCancelIsCancelOnlyForACancelledTask() {
        #expect(TRSession.connectorError(URLError(.cancelled), taskCancelled: true) == .cancelled)
        #expect(TRSession.connectorError(URLError(.cancelled), taskCancelled: false) == .bankUnavailable)
        #expect(TRSession.connectorError(CancellationError(), taskCancelled: false) == .cancelled)
    }

    @Test func connectorErrorsPassThrough() {
        #expect(TRSession.connectorError(ConnectorError.authFailed, taskCancelled: false) == .authFailed)
        #expect(TRSession.connectorError(ConnectorError.rateLimited(retryAfter: 5), taskCancelled: false) == .rateLimited(retryAfter: 5))
    }

    @Test func unknownErrorIsFormatChangeWithoutItsText() {
        struct Odd: Error, CustomStringConvertible { var description: String { "secret bank text" } }
        let mapped = TRSession.connectorError(Odd(), taskCancelled: false)
        guard case let .formatChanged(detail) = mapped else {
            Issue.record("expected formatChanged, got \(mapped)")
            return
        }
        #expect(!detail.contains("secret"))
    }

    @Test func pinMismatchIsNotACancel() {
        let mismatch = TRURLSessionTransport.translated(URLError(.cancelled), pinFailed: true, taskCancelled: false)
        #expect(mismatch as? ConnectorError == .formatChanged(detail: TRURLSessionTransport.pinMismatchDetail))
        #expect(TRSession.connectorError(mismatch, taskCancelled: false) != .cancelled)
        // A real cancel stays a cancel, other errors stay untouched.
        let cancelled = TRURLSessionTransport.translated(URLError(.cancelled), pinFailed: true, taskCancelled: true)
        #expect((cancelled as? URLError)?.code == .cancelled)
        let noPinFailure = TRURLSessionTransport.translated(URLError(.cancelled), pinFailed: false, taskCancelled: false)
        #expect((noPinFailure as? URLError)?.code == .cancelled)
    }

    @Test func transportTimeoutDuringRequestIsBankUnavailable() async {
        struct Offline: TRHTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        }
        let session = TRSession(
            baseURL: URL(string: "https://api.traderepublic.com") ?? URL(fileURLWithPath: "/"),
            presenter: nil,
            store: InMemoryTRSessionStore([SessionCookie(name: "tr_session", value: "test-session", domain: ".traderepublic.com")]),
            http: Offline()
        )
        await #expect(throws: ConnectorError.bankUnavailable) { _ = try await session.get("x") }
    }
}

// MARK: - Delta

@Suite struct TRDeltaTests {
    @Test func appliesCopyInsertDelete() throws {
        let previous = #"{"amount":10,"name":"old"}"#
        // keep `{"amount":`, drop `10`, insert `12`, keep `,"name":"`, drop `old`, insert `new value`, keep `"}`
        let delta = "=10\t-2\t+12\t=9\t-3\t+new+value\t=2"
        #expect(try TRDelta.apply(delta, to: previous) == #"{"amount":12,"name":"new value"}"#)
    }

    @Test func decodesPercentEscapes() throws {
        #expect(try TRDelta.apply("+%7B%22a%22%3A%22%C3%A4%22%7D", to: "") == #"{"a":"ä"}"#)
    }

    @Test func countsUnicodeScalars() throws {
        #expect(try TRDelta.apply("=3\t+x\t=1", to: "äöüß") == "äöüxß")
    }

    @Test func rejectsOutOfRange() {
        #expect(throws: ConnectorError.self) { try TRDelta.apply("=5", to: "abc") }
        #expect(throws: ConnectorError.self) { try TRDelta.apply("?3", to: "abc") }
    }
}

// MARK: - Mapping primitives

@Suite struct TRMappingTests {
    @Test(arguments: [
        ("2026-03-14T09:12:33.123+0000", "2026-03-14"),
        ("2026-03-14T23:30:00.000+0000", "2026-03-15"),
        ("2026-07-31T22:00:00Z", "2026-08-01"),
        ("2026-07-31T21:59:59+00:00", "2026-07-31"),
        ("2026-03-14T09:12:33.123+0100", "2026-03-14"),
        ("2026-03-14", "2026-03-14"),
    ])
    func timestamps(raw: String, expected: String) {
        #expect(TRMapping.day(fromTimestamp: raw)?.iso == expected)
    }

    @Test func amountsAreExactCents() {
        let cases: [(String, Int)] = [("0.07", 7), ("19.99", 1999), ("-1234.5", -123_450), ("\"-0.1\"", -10), ("1e2", 10_000)]
        for (value, cents) in cases {
            let json = JSONValue.parse(#"{"value":\#(value),"currency":"EUR"}"#)
            #expect(json.flatMap(TRMapping.money)?.cents == cents, "\(value)")
        }
        // Always cents, whatever `fractionDigits` says.
        #expect(TRMapping.money(JSONValue.parse(#"{"value":1000,"currency":"JPY","fractionDigits":0}"#) ?? .null)?.cents == 100_000)
        #expect(TRMapping.money(JSONValue.parse(#"{"value":12.34,"currency":"EUR","fractionDigits":4}"#) ?? .null)?.cents == 1234)
        #expect(TRMapping.money(JSONValue.parse(#"{"value":1,"currency":"euro"}"#) ?? .null) == nil)
    }

    /// More than two decimals is never rounded into a booking: `formatChanged`.
    @Test func subCentAmountsAreFormatChanged() throws {
        for value in ["-1234.565", "0.001", "1234.575"] {
            #expect(TRMapping.money(JSONValue.parse(#"{"value":\#(value),"currency":"EUR"}"#) ?? .null) == nil, "\(value)")
        }
        let item = try #require(JSONValue.parse(#"{"id":"t-1","timestamp":"2026-03-14T09:12:33.123+0000","amount":{"value":-1.005,"currency":"EUR"},"title":"Test","eventType":"CARD_TRANSACTION","status":"EXECUTED"}"#))
        #expect(throws: ConnectorError.formatChanged(detail: "Timeline-Betrag nicht lesbar")) {
            _ = try TRMapping.transaction(item: item, detail: nil, account: AccountID("acc"))
        }
    }

    @Test func eventTypes() {
        #expect(TREventType("card_successful_transaction") == .cardTransaction)
        #expect(TREventType("BANK_TRANSACTION_INCOMING") == .paymentInbound)
        #expect(TREventType("BANK_TRANSACTION_OUTGOING") == .paymentOutbound)
        #expect(TREventType("TRADING_TRADE_EXECUTED") == .trade)
        #expect(TREventType("SSP_CORPORATE_ACTION_CASH") == .corporateAction)
        #expect(TREventType("INTEREST_PAYOUT") == .interest)
        #expect(TREventType("PAYMENT_INBOUND_SEPA_DIRECT_DEBIT") == .directDebit)
        #expect(TREventType("PAYMENT_INBOUND_GOOGLE_PAY") == .paymentInbound)
        #expect(TREventType("OUTGOING_TRANSFER_DELEGATION") == .paymentOutbound)
        #expect(TREventType("SAVINGS_PLAN_EXECUTED") == .trade)
        #expect(TREventType("brand_new_thing") == .unknown("brand_new_thing"))
        #expect(TREventType(nil) == .unknown(""))
    }

    @Test func itemWithoutIDIsFormatChange() {
        let item = JSONValue.parse(#"{"timestamp":"2026-01-01T00:00:00Z","amount":{"value":1}}"#) ?? .null
        #expect(throws: ConnectorError.self) { try TRMapping.transaction(item: item, detail: nil, account: "a") }
    }

    @Test func portfolioCategoriesVariant() throws {
        let json = try #require(JSONValue.parse(#"{"categories":[{"categoryType":"stocksAndETFs","positions":[{"isin":"US0378331005","size":2}]}]}"#))
        #expect(try TRMapping.positions(json) == [.init(isin: "US0378331005", quantity: 2)])
        #expect(throws: ConnectorError.self) { try TRMapping.positions(.object([:])) }
    }

    @Test func averageBuyInParsedAndBounded() throws {
        let json = try #require(JSONValue.parse(#"{"positions":[{"isin":"US0378331005","netSize":"1","averageBuyIn":42.5},{"isin":"IE00B4L5Y983","netSize":"1","averageBuyIn":"0"},{"isin":"DE0007164600","netSize":"1","averageBuyIn":"1e12"},{"isin":"DE0005140008","netSize":"1","averageBuyIn":"abc"}]}"#))
        #expect(try TRMapping.positions(json).map(\.averageBuyIn) == [Decimal(string: "42.5"), nil, nil, nil])
    }

    @Test func accountSelectionPrefersCardProfile() throws {
        let json = try #require(JSONValue.parse(#"{"accounts":[{"accountId":"a","status":"ACTIVE","bankingInfo":{"iban":"DE00 1001 0000 0000 0000 01"}},{"accountId":"b","status":"ACTIVE","bankingInfo":{"iban":"DE00100100000000000002"}},{"accountId":"c","status":"CLOSED"}]}"#))
        #expect(try TRMapping.cashAccount(json, preferredID: "b").iban == "DE00100100000000000002")
        #expect(try TRMapping.cashAccount(json, preferredID: nil) == .init(accountID: "a", iban: "DE00100100000000000001"))
        #expect(try TRMapping.cashAccount(json, preferredID: "c").accountID == "a", "closed profile is not used")
        #expect(throws: ConnectorError.unsupportedAccount) { try TRMapping.cashAccount(.object(["accounts": .array([])]), preferredID: nil) }
        #expect(throws: ConnectorError.self) { try TRMapping.cashAccount(.object([:]), preferredID: nil) }
    }

    @Test func cardWithoutValidLast4() throws {
        let json = try #require(JSONValue.parse(#"{"data":{"card":{"lastFourPan":"12x4","authAccountId":"a"}}}"#))
        #expect(TRMapping.card(json) == .init(last4: nil, authAccountID: "a"))
    }
}

