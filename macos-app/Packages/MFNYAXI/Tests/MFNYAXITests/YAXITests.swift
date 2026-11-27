import CryptoKit
import Foundation
import MFNConformance
import MFNCore
import RoutexModels
import Testing
@testable import MFNYAXI

// MARK: - Conformance

private func subject() -> ConformanceSubject {
    ConformanceSubject(
        name: "YAXIConnector (synthetic YAXI)",
        makeConnector: { Harness().connector },
        pending: .scenario(
            before: {
                Harness(backend: FakeBackend(transactions: [
                    TestValues.giroIBAN: [FakeBackend.transaction("-23.50", daysAgo: 1, status: .pending, name: "Tankstelle", purpose: "Kartenzahlung")],
                ])).connector
            },
            after: {
                Harness(backend: FakeBackend(transactions: [
                    TestValues.giroIBAN: [FakeBackend.transaction("-23.50", daysAgo: 0, status: .booked, name: "Tankstelle", purpose: "Kartenzahlung")],
                ])).connector
            }
        ),
        failures: [
            .init("Keine Freigabe, kein Presenter", expected: .authRequired(.pushConfirm(message: ""))) {
                Harness(consent: nil, presenter: nil).connector
            },
            .init("Freigabe abgebrochen", expected: .cancelled) {
                Harness(consent: nil, presenter: ScriptedPresenter(.cancel)).connector
            },
            .init("Falsche Zugangsdaten", expected: .authFailed) {
                Harness(backend: FakeBackend(fault: .invalidCredentials), consent: nil).connector
            },
            .init("Freigabe läuft während des Syncs ab", expected: .sessionExpired) {
                Harness(backend: FakeBackend(fault: .consentExpiredOnTransactions)).connector
            },
            .init("Bank begrenzt Abrufe", expected: .rateLimited(retryAfter: 0)) {
                Harness(backend: FakeBackend(fault: .accessExceeded)).connector
            },
            .init("Bank nicht erreichbar", expected: .bankUnavailable) {
                Harness(backend: FakeBackend(fault: .providerDown)).connector
            },
        ],
        secrets: TestValues.secrets
    )
}

@Suite(.serialized) struct YAXIConformanceTests {
    @Test func passesConformance() async {
        let report = await ConnectorConformance.run(subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed)
        #expect(report.outcome(of: "since respektiert") == .passed)
    }
}

// MARK: - Connector

@Suite struct YAXIConnectorTests {
    @Test func syncWithStoredConsentNeedsNoUser() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts()
        #expect(accounts.map(\.type) == [.giro, .tagesgeld]) // the depot is skipped
        #expect(accounts.allSatisfy { $0.id.rawValue.hasPrefix("yaxi-") && $0.connectionID == TestValues.connection })
        #expect(accounts.first?.name == "Girokonto")
        #expect(harness.presenter?.challenges.isEmpty == true)
        // YAXI rotated the consent: the newest one is stored.
        #expect(harness.states.current?.consent == TestValues.consentB)
    }

    @Test func oneBalancesCallPerSync() async throws {
        let harness = Harness()
        let accounts = try await harness.connector.accounts()
        for account in accounts {
            let balance = try await harness.connector.balance(for: account)
            #expect(balance.bookedCents == 123_456)
            #expect(balance.availableCents == 120_000)
        }
        #expect(harness.backend.calls.filter { $0 == "balances" }.count == 1)
    }

    @Test func accountListIsReusedForADay() async throws {
        let harness = Harness()
        _ = try await harness.connector.accounts()
        _ = try await harness.connector.accounts()
        #expect(harness.backend.calls.filter { $0 == "accounts" }.count == 1)
    }

    @Test func userInSessionFollowsTheTrigger() async throws {
        let harness = Harness()
        try await AuthInteraction.$isAllowed.withValue(false) {
            _ = try await harness.connector.accounts()
        }
        let manual = Harness()
        _ = try await manual.connector.accounts()
        #expect(harness.backend.userInSession == [false])
        #expect(manual.backend.userInSession == [true])
    }

    @Test func automaticSyncNeverStartsAConsent() async throws {
        let harness = Harness(consent: nil)
        await #expect(throws: ConnectorError.self) {
            try await AuthInteraction.$isAllowed.withValue(false) {
                _ = try await harness.connector.accounts()
            }
        }
        #expect(harness.backend.calls.isEmpty)
        #expect(harness.presenter?.challenges.isEmpty == true)
    }

    @Test func newConsentPollsTheDecoupledApproval() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .decoupled(pending: 3)), consent: nil)
        let accounts = try await harness.connector.accounts()
        #expect(accounts.count == 2)
        #expect(harness.backend.calls.filter { $0 == "confirm" }.count == 4)
        #expect(harness.backend.receivedLogin == YAXILogin(userID: TestValues.userID, password: TestValues.password))
        guard case let .decoupled(message, interval)? = harness.presenter?.challenges.first else {
            Issue.record("no decoupled challenge"); return
        }
        #expect(message == YAXIConnector.defaultApprovalMessage)
        #expect(interval >= YAXIConnector.minimumPollInterval)
        #expect(harness.states.current?.consent == TestValues.consentA)
    }

    @Test func expiredConsentAsksAgainWhenTheUserIsThere() async throws {
        let backend = FakeBackend(fault: .consentExpiredOnAccounts)
        let harness = Harness(backend: backend)
        let accounts = try await harness.connector.accounts()
        #expect(accounts.count == 2)
        #expect(backend.calls.prefix(2) == ["accounts", "consent"])
    }

    @Test func expiredConsentMidSyncIsDroppedForTheNextSync() async throws {
        let harness = Harness(backend: FakeBackend(fault: .consentExpiredOnTransactions))
        let accounts = try await harness.connector.accounts()
        await #expect(throws: ConnectorError.sessionExpired) {
            _ = try await harness.connector.transactions(for: accounts[0], since: nil)
        }
        #expect(harness.states.current?.consent == nil)
    }

    @Test func tanEntry() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .tan), consent: nil)
        _ = try await harness.connector.accounts()
        #expect(harness.backend.receivedAnswers == [.text(TestValues.tan)])
        guard case let .code(prompt, length)? = harness.presenter?.challenges.first else { Issue.record("no code challenge"); return }
        #expect(prompt == "Bitte TAN eingeben")
        #expect(length == 6)
    }

    @Test func redirectUsesTheWebLogin() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .redirect), consent: nil)
        _ = try await harness.connector.accounts()
        guard case let .webLogin(request)? = harness.presenter?.challenges.first else { Issue.record("no web login"); return }
        #expect(request.url.host() == "bank.example")
        #expect(request.completion == .urlPrefix(RoutexBackend.redirectURI))
    }

    @Test func choiceOfTANMethod() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .choice), consent: nil)
        _ = try await harness.connector.accounts()
        guard case let .choice(prompt, options)? = harness.presenter?.challenges.first else { Issue.record("no choice"); return }
        #expect(prompt == "Verfahren wählen")
        #expect(options.map(\.key) == ["a", "b"])
        #expect(harness.backend.receivedAnswers == [.text("b")])
    }

    @Test func pinAskedInADialogIsMasked() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .pin), consent: nil)
        _ = try await harness.connector.accounts()
        guard case let .secret(prompt, _)? = harness.presenter?.challenges.first else { Issue.record("no secret field"); return }
        #expect(prompt == "PIN eingeben")
    }

    @Test func approvalComesBackWhenConfirmedTooEarly() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .earlyConfirm), consent: nil, presenter: ScriptedPresenter(.confirmAtOnce))
        _ = try await harness.connector.accounts()
        let shown = harness.presenter?.challenges.filter { if case .decoupled = $0 { true } else { false } }.count ?? 0
        #expect(shown >= 2, "the sheet is shown again while the bank still waits")
    }

    @Test func photoTAN() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .photoTAN), consent: nil)
        _ = try await harness.connector.accounts()
        guard case let .imageCode(_, length, image)? = harness.presenter?.challenges.first else { Issue.record("no image code"); return }
        #expect(length == 0)
        #expect(image.mimeType == "image/png")
        #expect(image.physicalWidthMM == nil)
        #expect(harness.backend.receivedAnswers == [.text(TestValues.tan)])
    }

    @Test func chipTANOpticIsShownAtTheGeneratorsWidth() async throws {
        let harness = Harness(backend: FakeBackend(consentScript: .flicker), consent: nil)
        _ = try await harness.connector.accounts()
        guard case let .imageCode(_, _, image)? = harness.presenter?.challenges.first else { Issue.record("no image code"); return }
        #expect(image.physicalWidthMM == 62.5)
    }

    @Test func firstImportFallsBackWhenTheBankRefusesTheLongPeriod() async throws {
        let harness = Harness(backend: FakeBackend(fault: .periodOutOfBoundsBeyond(days: 90)))
        let accounts = try await harness.connector.accounts()
        let transactions = try await harness.connector.transactions(for: accounts[0], since: nil)
        #expect(transactions.count == 4)
        #expect(harness.backend.calls.filter { $0 == "transactions" }.count == 2)
    }

    @Test func automaticSyncsPauseNearTheFreeLimit() async throws {
        let harness = Harness(usedCalls: 900)
        await #expect(throws: ConnectorError.self) {
            try await AuthInteraction.$isAllowed.withValue(false) { _ = try await harness.connector.accounts() }
        }
        #expect(harness.backend.calls.isEmpty)
        // The user may still sync.
        _ = try await harness.connector.accounts()
        #expect(harness.backend.calls == ["accounts"])
    }

    @Test func usageCountsPerMonth() {
        final class Box: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_795_000_000) } // 2026-11
        let box = Box()
        let usage = YAXIUsage(defaults: UserDefaults(suiteName: "yaxi-usage-\(UUID().uuidString)") ?? .standard, now: { box.date })
        usage.record(3)
        #expect(usage.thisMonth == 3)
        #expect(!usage.pausesAutomaticSyncs)
        usage.record(897)
        #expect(usage.pausesAutomaticSyncs)
        #expect(usage.untilNextMonth > 0)
        box.date += 40 * 24 * 60 * 60
        #expect(usage.thisMonth == 0)
    }

    @Test func missingKeyAsksForSettings() async throws {
        struct NoKey: YAXIKeyStore {
            func key() throws -> YAXIAPIKey? { nil }
            func set(_ key: YAXIAPIKey) throws {}
            func delete() throws {}
        }
        let states = MemoryStateStore(YAXIConnectionState(bank: TestValues.bank, bankName: "Testbank", consent: TestValues.consentA))
        let connector = YAXIConnector(connectionID: TestValues.connection, presenter: nil, keyStore: NoKey(), states: states, login: { nil })
        await #expect(throws: ConnectorError.self) { _ = try await connector.accounts() }
    }
}

// MARK: - Mapping

@Suite struct YAXIMapperTests {
    @Test func accountTypes() {
        let mapped = FakeBackend.accounts.compactMap { YAXIMapper.account($0, connection: TestValues.connection) }
        #expect(mapped.map(\.account.type) == [.giro, .tagesgeld])
        let card = YAXIMapper.account(RXAccount(maskedPan: "4111 XXXX XXXX 4321", currency: "eur", name: "Visa", type: .card), connection: TestValues.connection)
        #expect(card?.account.type == .card)
        #expect(card?.account.cardLast4 == "4321")
        #expect(card?.account.currency == "EUR")
        #expect(card?.reference == "maskedPan:4111 XXXX XXXX 4321")
    }

    /// An account without type and IBAN, only a number.
    @Test func accountWithoutTypeIsGiro() {
        let space = YAXIMapper.account(RXAccount(iban: nil, number: "space-1", currency: "EUR", name: "Urlaub", type: nil), connection: TestValues.connection)
        #expect(space?.account.type == .giro)
        #expect(space?.account.name == "Urlaub")
        #expect(space?.account.iban == nil)
        #expect(space?.reference == "number:space-1")
    }

    @Test func accountIDIsStableAndOpaque() {
        let a = YAXIMapper.accountID(connection: TestValues.connection, reference: "iban:" + TestValues.giroIBAN)
        let b = YAXIMapper.accountID(connection: TestValues.connection, reference: "iban:" + TestValues.giroIBAN)
        #expect(a == b)
        #expect(!a.rawValue.contains(TestValues.giroIBAN))
    }

    @Test func outgoingTransaction() throws {
        let account = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection)).account
        let source = RXTransaction(
            bookingDate: try ISODate("2026-11-20"), valueDate: try ISODate("2026-11-19"), status: .paid,
            endToEndID: "NOTPROVIDED", mandateID: "M-1", creditorID: "DE98ZZZ09999999999",
            amount: Amount(amount: Decimal(string: "-1234.5") ?? 0, currency: "eur"),
            creditor: RoutexModels.Party(name: "Stadtwerke", iban: "de00 9876 5432 0000 0000 03"), debtor: RoutexModels.Party(name: "Ich"),
            remittanceInformation: ["Abschlag ", "November"]
        )
        let mapped = try YAXIMapper.transaction(source, account: account)
        #expect(mapped.status == .booked)
        #expect(mapped.amountCents == -123_450)
        #expect(mapped.currency == "EUR")
        #expect(mapped.counterpartName == "Stadtwerke")
        #expect(mapped.counterpartIBAN == TestValues.counterpartIBAN)
        #expect(mapped.purpose == "Abschlag November")
        #expect(mapped.eref == nil)
        #expect(mapped.mref == "M-1")
        #expect(mapped.bookingDate == BankDay(iso: "2026-11-20"))
        #expect(mapped.valueDate == BankDay(iso: "2026-11-19"))
        #expect(mapped.externalID == nil) // M0: DKB sends no IDs, the fingerprint decides
    }

    @Test func reversalPointsToTheOriginalCounterpart() throws {
        let account = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection)).account
        // A returned direct debit: money comes back, the parties are those of the original debit.
        let source = RXTransaction(bookingDate: try ISODate("2026-11-20"), status: .booked, amount: Amount(amount: 30, currency: "EUR"),
                                   reversal: true, creditor: RoutexModels.Party(name: "Fitnessstudio"), debtor: RoutexModels.Party(name: "Ich"))
        #expect(try YAXIMapper.transaction(source, account: account).counterpartName == "Fitnessstudio")
    }

    @Test func pendingAndCancelled() throws {
        let account = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection)).account
        let pending = try YAXIMapper.transaction(FakeBackend.transaction("-5.00", daysAgo: 0, status: .pending), account: account)
        #expect(pending.status == .pending)
        #expect(pending.bookingDate == nil)
        let cancelled = try YAXIMapper.transaction(FakeBackend.transaction("-5.00", daysAgo: 0, status: .canceled), account: account)
        #expect(cancelled.status == .cancelled)
    }

    @Test func foreignCurrency() throws {
        let account = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection)).account
        let source = RXTransaction(valueDate: try ISODate("2026-11-20"), status: .booked,
                                   amount: Amount(amount: Decimal(string: "-9.37") ?? 0, currency: "EUR"),
                                   originalAmount: Amount(amount: Decimal(string: "-10.00") ?? 0, currency: "USD"))
        let mapped = try YAXIMapper.transaction(source, account: account)
        #expect(mapped.originalAmountCents == -1_000)
        #expect(mapped.originalCurrency == "USD")
        #expect(mapped.bookingDate == BankDay(iso: "2026-11-20"))
    }

    @Test func balanceWithOnlyAvailableAmounts() throws {
        // C24 over YAXI: two `Available` readings, no `Booked`.
        let known = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection))
        let reference = try #require(YAXIMapper.accountReference(known))
        let balances = RXBalances(balances: [AccountBalances(account: reference, balances: [
            RoutexModels.Balance(amount: Decimal(string: "1500.00")!, currency: "EUR", balanceType: .available, creditLimitIncluded: true),
            RoutexModels.Balance(amount: Decimal(string: "500.00")!, currency: "EUR", balanceType: .available, creditLimitIncluded: false),
        ])])
        let balance = try YAXIMapper.balance(balances, for: known, asOf: Date())
        #expect(balance.bookedCents == 50_000)
        #expect(balance.availableCents == 150_000)

        let plain = RXBalances(balances: [AccountBalances(account: reference, balances: [
            RoutexModels.Balance(amount: Decimal(string: "42.10")!, currency: "EUR", balanceType: .available),
            RoutexModels.Balance(amount: Decimal(string: "42.10")!, currency: "EUR", balanceType: .available),
        ])])
        #expect(try YAXIMapper.balance(plain, for: known, asOf: Date()).bookedCents == 4_210)
    }

    @Test func centsAreExact() throws {
        #expect(try YAXIMapper.cents(Decimal(string: "0.1")!, context: "t") == 10)
        #expect(try YAXIMapper.cents(Decimal(string: "-1234.50")!, context: "t") == -123_450)
        #expect(try YAXIMapper.cents(Decimal(string: "12.3400")!, context: "t") == 1_234)
        #expect(throws: ConnectorError.self) { try YAXIMapper.cents(Decimal(string: "1.005")!, context: "t") }
    }

    @Test func undatedTransactionIsAFormatChange() throws {
        let account = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection)).account
        let source = RXTransaction(status: .booked, amount: Amount(amount: 1, currency: "EUR"))
        #expect(throws: ConnectorError.self) { try YAXIMapper.transaction(source, account: account) }
    }

    /// C24: pending transactions come without any date.
    @Test func undatedPendingTransactionIsToday() throws {
        let account = try #require(YAXIMapper.account(FakeBackend.accounts[0], connection: TestValues.connection)).account
        let today = try #require(BankDay(iso: "2026-11-26"))
        let source = RXTransaction(status: .pending, amount: Amount(amount: -12, currency: "EUR"))
        let mapped = try YAXIMapper.transaction(source, account: account, today: today)
        #expect(mapped.valueDate == today)
        #expect(mapped.bookingDate == nil)
        #expect(mapped.status == .pending)
    }

    @Test func logoURLsStayOnTheLogoService() {
        #expect(YAXILogos.url(for: "revolut")?.absoluteString == "https://logos.yaxi.tech/banks/revolut-64.png")
        for bad in ["", "../x", "a/b", "_default", ".hidden", "a b", "ü", String(repeating: "a", count: 81), "x?y=1"] {
            #expect(YAXILogos.url(for: bad) == nil, "\(bad)")
        }
        #expect(YAXILogos.isPNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])))
        #expect(!YAXILogos.isPNG(Data("<svg>".utf8)))
    }

    @Test func bankTextIsCleaned() {
        #expect(YAXIConnector.displayText("Bitte\u{202E} bestätigen\n") == "Bitte bestätigen")
    }
}

// MARK: - Tickets, keys, results

@Suite struct YAXISecurityTests {
    static let secret = Data((0..<64).map { UInt8($0) })

    static func jwt(alg: String = "HS256", ticket: UUID, secret: Data = secret) -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = b64(Data(#"{"alg":"\#(alg)","typ":"JWT"}"#.utf8))
        let payload = b64(Data(#"{"data":{"data":[],"ticketId":"\#(ticket.uuidString.lowercased())","timestamp":"2026-11-25T10:00:00Z"}}"#.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(header).\(payload)".utf8), using: SymmetricKey(data: secret))
        return "\(header).\(payload).\(b64(Data(mac)))"
    }

    @Test func verifiesSignatureAndTicket() throws {
        let ticket = UUID()
        let payload = try YAXIResultVerifier.verifiedPayload(Self.jwt(ticket: ticket), secret: Self.secret, ticketID: ticket)
        let result = try JSONDecoder().decode(AccountsResult.self, from: payload)
        #expect(result.ticketID == ticket)
        #expect(result.data.isEmpty)
    }

    @Test func rejectsForgedOrForeignResults() {
        let ticket = UUID()
        #expect(throws: YAXIResultVerifier.Failure.signature) {
            try YAXIResultVerifier.verifiedPayload(Self.jwt(ticket: ticket, secret: Data(repeating: 7, count: 64)), secret: Self.secret, ticketID: ticket)
        }
        #expect(throws: YAXIResultVerifier.Failure.ticket) {
            try YAXIResultVerifier.verifiedPayload(Self.jwt(ticket: ticket), secret: Self.secret, ticketID: UUID())
        }
        #expect(throws: YAXIResultVerifier.Failure.algorithm) {
            try YAXIResultVerifier.verifiedPayload(Self.jwt(alg: "none", ticket: ticket), secret: Self.secret, ticketID: ticket)
        }
        #expect(throws: YAXIResultVerifier.Failure.malformed) {
            try YAXIResultVerifier.verifiedPayload("abc", secret: Self.secret, ticketID: ticket)
        }
    }

    @Test func apiKeyFormatAndRedaction() throws {
        let secret = Self.secret.base64EncodedString()
        let key = try YAXIAPIKey(keyID: " api-key-00000000-test ", base64Secret: secret, environment: .integration)
        #expect(key.keyID == "api-key-00000000-test")
        #expect(key.secret == Self.secret)
        #expect(!key.description.contains(secret) && !"\(key)".contains("api-key"))
        #expect(throws: YAXIAPIKey.Problem.keyIDFormat) { try YAXIAPIKey(keyID: "client-123", base64Secret: secret, environment: .production) }
        #expect(throws: YAXIAPIKey.Problem.secretFormat) { try YAXIAPIKey(keyID: "api-key-1", base64Secret: "not base64!", environment: .production) }
    }

    @Test func ticketsAreIssuedLocally() throws {
        let key = try YAXIAPIKey(keyID: "api-key-00000000-test", base64Secret: Self.secret.base64EncodedString(), environment: .integration)
        let tickets = try YAXITickets(key: key)
        let ticket = try tickets.transactions(account: AccountReference(id: .iban(TestValues.giroIBAN)), from: try ISODate("2026-01-01"))
        #expect(ticket.raw.split(separator: ".").count == 3)
    }

    @Test func errorMapping() {
        #expect(YAXIErrors.map(RoutexError.interruptError) == .consentNeeded)
        #expect(YAXIErrors.map(RoutexError.periodOutOfBounds(userMessage: nil)) == .periodOutOfBounds)
        #expect(YAXIErrors.map(RoutexError.invalidCredentials(userMessage: "x")) == .connector(.authFailed))
        #expect(YAXIErrors.map(RoutexError.accessExceeded(userMessage: nil)) == .connector(.rateLimited(retryAfter: YAXIErrors.accessExceededRetry)))
        #expect(YAXIErrors.map(RoutexError.canceled) == .connector(.cancelled))
        #expect(YAXIErrors.map(RoutexError.unrecognizedResponse(status: 502, text: "")) == .connector(.bankUnavailable))
        #expect(YAXIErrors.map(URLError(.notConnectedToInternet)) == .connector(.bankUnavailable))
        #expect(YAXIErrors.map(CancellationError()) == .connector(.cancelled))
    }
}

/// MFN never moves money: no code in the package may even name a service that does.
@Suite struct ReadOnlyGuardTests {
    @Test func noPaymentServiceInSources() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/MFNYAXI")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let forbidden = ["transfer(", "Transfer", "collectPayment", "CollectPayment", "standingOrders", "StandingOrders"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                #expect(!text.contains(word), "\(file.lastPathComponent) names \(word)")
            }
        }
    }
}
