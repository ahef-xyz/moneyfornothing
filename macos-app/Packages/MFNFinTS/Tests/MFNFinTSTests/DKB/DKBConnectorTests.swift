import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNFinTS

@Suite struct DKBConnectorTests {
    @Test func mapsUPDAccountsIncludingCreditCard() async throws {
        let connector = makeDKBConnector(FakeDKB())
        let accounts = try await connector.accounts()
        #expect(accounts.map(\.type) == [.giro, .tagesgeld, .depot, .card], "loan account is skipped")
        #expect(accounts.allSatisfy { $0.connectionID == "dkb-test" && $0.id.rawValue.hasPrefix("dkb-") })
        let giro = accounts[0]
        #expect(giro.iban == FakeDKB.giroIBAN)
        #expect(giro.name == "Girokonto")
        #expect(giro.creditLimitCents == 250_000)
        let card = accounts[3]
        #expect(card.iban == nil)
        #expect(card.cardLast4 == "4711")
        #expect(card.name == "DKB Visa Kreditkarte")
        #expect(card.creditLimitCents == 250_000)
        #expect(!accounts.contains { $0.id.rawValue.contains("1234567890") || $0.id.rawValue.contains(FakeDKB.cardNumber) })
        // Stable across instances.
        #expect(try await makeDKBConnector(FakeDKB()).accounts().map(\.id) == accounts.map(\.id))
    }

    @Test func balancesForGiroAndCard() async throws {
        let connector = makeDKBConnector(FakeDKB())
        let accounts = try await connector.accounts()
        let giro = try await connector.balance(for: accounts[0])
        #expect(giro.bookedCents == 123_456)
        #expect(giro.availableCents == 373_456)
        #expect(giro.currency == "EUR")
        #expect(giro.asOf == fakeToday)
        let card = try await connector.balance(for: accounts[3])
        #expect(card.bookedCents == -12_345)
        #expect(card.availableCents == 237_655)
    }

    @Test func depotBalanceIsSumOfPositions() async throws {
        let connector = makeDKBConnector(FakeDKB())
        let depot = try #require(try await connector.accounts().first { $0.type == .depot })
        let positions = try await connector.securities(for: depot)
        #expect(positions.map(\.isin) == ["DE0005190003", "IE00B4L5Y983"], "holding without ISIN is skipped")
        #expect(positions.map(\.name) == ["MUSTER AG", "WELT ETF"])
        #expect(positions.map(\.quantity) == [10, Decimal(string: "12.5")])
        #expect(positions.map(\.priceCents) == [8550, 9876])
        #expect(positions.allSatisfy { $0.accountID == depot.id && $0.currency == "EUR" })
        #expect(positions.first?.asOf == BankDay(iso: "2026-11-06")?.startDate)
        #expect(try await connector.balance(for: depot).bookedCents == 85_500 + 123_450)
        #expect(try await connector.transactions(for: depot, since: nil).isEmpty)
    }

    @Test func standardParsersAreTheDefault() async throws {
        let connector = DKBConnector(
            connectionID: "dkb-test", credentials: FakeDKB.credentials, presenter: WaitingPresenter(),
            transport: FakeDKB().transport(), clock: TestClock(), now: { fakeToday }
        )
        let depot = try #require(try await connector.accounts().first { $0.type == .depot })
        #expect(try await connector.securities(for: depot).count == 2)
    }

    @Test func brokenMT535IsFormatChanged() {
        #expect(throws: ConnectorError.self) {
            try DKBStatementParsers.standard.mt535?(Data(":16R:FIN\n:35B:ISIN DE0005190003\nX\n:16S:FIN".utf8), "dkb-x", fakeToday)
        }
    }

    @Test func mt940FallbackWhenCAMTIsNotOffered() async throws {
        var options = FakeDKB.Options()
        options.mt940Only = true
        let bank = FakeDKB(options)
        let transport = bank.transport()
        let connector = makeDKBConnector(bank, transport: transport)
        let giro = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: giro, since: nil)
        #expect(await transport.requestTypes.contains(["HKKAZ", "HKTAN"]))
        #expect(await !transport.requestTypes.contains { $0.contains("HKCAZ") })
        #expect(transactions.count == 4)
        let pending = try #require(transactions.first { $0.status == .pending })
        #expect(pending.counterpartName == "REWE Markt")
        #expect(pending.bookingDate == nil)
        #expect(pending.valueDate == BankDay(iso: "2026-11-08"))
        let debit = try #require(transactions.first { $0.mref == "MANDAT-001" })
        #expect(debit.amountCents == -4590)
        #expect(debit.bookingDate == BankDay(iso: "2026-11-02"))
        #expect(debit.counterpartName == "Stadtwerke Muster")
        #expect(debit.counterpartIBAN == "DE00700500000000000002")
        #expect(debit.creditorID == "DE98ZZZ09999999999")
        #expect(debit.eref == "E2E-STROM-11")
        #expect(debit.purpose == "Abschlag Strom")
    }

    @Test func noStatementFormatIsUnsupported() async throws {
        var options = FakeDKB.Options()
        options.mt940Only = true
        let connector = makeDKBConnector(FakeDKB(options), parsers: DKBStatementParsers(mt535: DKBStatementParsers.standard.mt535))
        let giro = try #require(try await connector.accounts().first)
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.transactions(for: giro, since: nil) }
    }

    @Test func depotWithoutMT535ParserIsUnsupported() async throws {
        let connector = makeDKBConnector(FakeDKB(), parsers: .none)
        let depot = try #require(try await connector.accounts().first { $0.type == .depot })
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.securities(for: depot) }
    }

    @Test func transactionsPageThroughCAMTWithPending() async throws {
        let bank = FakeDKB()
        let transport = bank.transport()
        let connector = makeDKBConnector(bank, transport: transport)
        let giro = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: giro, since: nil)
        #expect(transactions.count == 6)
        #expect(transactions.filter { $0.status == .pending }.map(\.counterpartName) == ["REWE Markt"])
        #expect(Set(transactions.map(\.id)).count == 6, "two identical bakery payments get distinct IDs")
        #expect(transactions.contains { $0.id.rawValue.hasSuffix("#2") })

        let caz = await transport.requests.compactMap { $0.first { $0.type == "HKCAZ" } }
        #expect(caz.map { $0[6].first } == [nil, "P2"])
        #expect(caz.first?[1].first == "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08", "newest camt.052 from HICAZS")
        #expect(caz.first?[3].first == "20250816", "since == nil → HICAZS storage period (450 days)")
    }

    @Test func sinceIsSentAndRespected() async throws {
        let bank = FakeDKB()
        let transport = bank.transport()
        let connector = makeDKBConnector(bank, transport: transport)
        let giro = try #require(try await connector.accounts().first)
        let since = try #require(BankDay(iso: "2026-11-03")).startDate
        let transactions = try await connector.transactions(for: giro, since: since)
        #expect(transactions.allSatisfy { $0.status == .pending || $0.effectiveDate >= BankDay(since) })
        #expect(transactions.count == 4)
        let caz = await transport.requests.compactMap { $0.first { $0.type == "HKCAZ" } }
        #expect(caz.first?[3].first == "20261103")
    }

    @Test func cardTransactionsKeepForeignCurrency() async throws {
        let connector = makeDKBConnector(FakeDKB())
        let card = try #require(try await connector.accounts().first { $0.type == .card })
        let transactions = try await connector.transactions(for: card, since: nil)
        let uber = try #require(transactions.first { $0.counterpartName == "UBER TRIP" })
        #expect(uber.amountCents == -1120)
        #expect(uber.originalAmountCents == -1200)
        #expect(uber.originalCurrency == "USD")
        #expect(transactions.contains { $0.status == .pending && $0.counterpartName == "AMAZON" })
        #expect(try await connector.cardStatements(for: card).isEmpty)
    }

    @Test func approvalForOldHistoryGoesThroughDecoupledPath() async throws {
        var options = FakeDKB.Options()
        options.statementSCA = true
        options.pollsUntilApproval = 2
        let bank = FakeDKB(options)
        let transport = bank.transport()
        let presenter = WaitingPresenter()
        let connector = makeDKBConnector(bank, presenter: presenter, transport: transport)
        let giro = try #require(try await connector.accounts().first)
        let transactions = try await connector.transactions(for: giro, since: nil)
        #expect(transactions.count == 6)
        #expect(presenter.presented == [.decoupled(message: "Bitte bestätige den Umsatzabruf in der DKB-App.", pollInterval: 1)])
        let types = await transport.requestTypes
        #expect(Array(types.suffix(6)) == [["HKIDN", "HKVVB", "HKTAN"], ["HKCAZ", "HKTAN"], ["HKTAN"], ["HKTAN"], ["HKCAZ", "HKTAN"], ["HKEND"]])
    }

    @Test func systemIDIsSynchronisedOnceAndReused() async throws {
        let store = InMemoryDKBStateStore()
        let first = FakeDKB()
        let firstTransport = first.transport()
        _ = try await makeDKBConnector(first, store: store, transport: firstTransport).accounts()
        #expect(await firstTransport.requestTypes.contains(["HKIDN", "HKVVB", "HKTAN", "HKSYN"]))
        #expect(await store.loadSystemID() == FakeDKB.systemID)

        let second = FakeDKB()
        let secondTransport = second.transport()
        _ = try await makeDKBConnector(second, store: store, transport: secondTransport).accounts()
        let initRequest = try #require(await secondTransport.requests.first { $0.contains { $0.type == "HKIDN" && $0[1].first == FakeDKB.login } })
        #expect(!initRequest.contains { $0.type == "HKSYN" })
        #expect(initRequest.first { $0.type == "HKIDN" }?[2].first == FakeDKB.systemID)
    }

    @Test func everyDialogIsEnded() async throws {
        let bank = FakeDKB()
        let transport = bank.transport()
        let connector = makeDKBConnector(bank, transport: transport)
        for account in try await connector.accounts() {
            _ = try await connector.balance(for: account)
            _ = try await connector.transactions(for: account, since: nil)
            _ = try await connector.securities(for: account)
        }
        let requests = await transport.requests
        let personalInits = requests.filter { $0.contains { $0.type == "HKIDN" && $0[1].first == FakeDKB.login } }.count
        let anonymous = requests.filter { $0.contains { $0.type == "HKIDN" && $0[1].first == "9999999999" } }.count
        let ends = requests.filter { $0.contains { $0.type == "HKEND" } }.count
        #expect(anonymous == 1, "BPD fetched anonymously once per connector")
        #expect(personalInits + anonymous == ends)
        #expect(personalInits > 1)
    }

    @Test func endsDialogAlsoOnFailure() async throws {
        var options = FakeDKB.Options()
        options.brokenCAMT = true
        let bank = FakeDKB(options)
        let transport = bank.transport()
        let connector = makeDKBConnector(bank, transport: transport)
        let giro = try #require(try await connector.accounts().first)
        await #expect(throws: ConnectorError.self) { try await connector.transactions(for: giro, since: nil) }
        #expect(await transport.requestTypes.last == ["HKEND"])
    }

    @Test func rejectsForeignAccounts() async throws {
        let connector = makeDKBConnector(FakeDKB())
        let accounts = try await connector.accounts()
        let foreignConnection = Account(id: accounts[0].id, connectionID: "other", type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.balance(for: foreignConnection) }
        let unknown = Account(id: "dkb-0000000000000000", connectionID: "dkb-test", type: .giro, name: "x")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.transactions(for: unknown, since: nil) }
    }

    @Test func segmentErrorsMapToConnectorErrors() throws {
        func response(_ code: String) throws -> FinTSResponse {
            try FinTSResponse(bytes: FinTSMessage.build(dialogID: "D", messageNumber: 1, segments: [FakeDKB.code("HIRMG", "3060", "W"), FakeDKB.code("HIRMS", code, "Text mit DE00120300001234567890", reference: 3)], security: nil))
        }
        #expect(throws: ConnectorError.authFailed) { try DKBConnector.checkSegmentErrors(response("9942")) }
        #expect(throws: ConnectorError.formatChanged(detail: "DKB FinTS 9210")) { try DKBConnector.checkSegmentErrors(response("9210")) }
        #expect(throws: Never.self) { try DKBConnector.checkSegmentErrors(response("3010")) }
    }

    @Test func fintsAmounts() {
        #expect(DKBAmount.cents("1234,56") == 123_456)
        #expect(DKBAmount.cents("1234,") == 123_400)
        #expect(DKBAmount.cents("0,5") == 50)
        #expect(DKBAmount.cents("12") == 1200)
        #expect(DKBAmount.cents("1.234,56") == nil)
        #expect(DKBAmount.cents("-1,00") == nil)
        #expect(DKBMapping.cardLast4("4930********1234") == "1234")
        #expect(DKBMapping.cardLast4("12") == nil)
    }
}

// MARK: - Conformance

@Suite(.serialized) struct DKBConformanceTests {
    static func subject() -> ConformanceSubject {
        func connector(_ options: FakeDKB.Options = .init()) -> ConformanceSubject.Factory {
            { makeDKBConnector(FakeDKB(options)) }
        }
        var current = FakeDKB.Options()
        current.initSCA = true
        current.pollsUntilApproval = 2
        var after = current
        after.phase = .afterBooking
        var pinWrong = FakeDKB.Options()
        pinWrong.pinWrong = true
        var timeout = current
        timeout.pollsUntilApproval = 1000
        var rejected = current
        rejected.rejectApproval = true
        var broken = FakeDKB.Options()
        broken.brokenCAMT = true
        var rateLimited = FakeDKB.Options()
        rateLimited.transportError = .rateLimited(retryAfter: 60)
        var down = FakeDKB.Options()
        down.transportError = .bankUnavailable

        let (initSCA, slowApproval) = (current, timeout)
        return ConformanceSubject(
            name: "DKBConnector (FinTS, synthetischer Server)",
            makeConnector: connector(current),
            pending: .scenario(before: connector(current), after: connector(after)),
            failures: [
                .init("Falsche PIN", expected: .authFailed, makeConnector: connector(pinWrong)),
                .init("Freigabe ohne Presenter", expected: .authRequired(.decoupled(message: "", pollInterval: 0))) {
                    makeDKBConnector(FakeDKB(initSCA), presenter: nil)
                },
                .init("Freigabe abgebrochen", expected: .cancelled) {
                    makeDKBConnector(FakeDKB(slowApproval), presenter: CancellingPresenter())
                },
                .init("Freigabe-Timeout", expected: .authFailed, makeConnector: connector(timeout)),
                .init("Freigabe abgelehnt", expected: .authFailed, makeConnector: connector(rejected)),
                .init("camt.052 kaputt", expected: .formatChanged(detail: ""), makeConnector: connector(broken)),
                .init("429", expected: .rateLimited(retryAfter: 0), makeConnector: connector(rateLimited)),
                .init("Bank nicht erreichbar", expected: .bankUnavailable, makeConnector: connector(down)),
            ],
            secrets: FakeDKB.secrets
        )
    }

    static func mt940Subject() -> ConformanceSubject {
        var current = FakeDKB.Options()
        current.mt940Only = true
        var after = current
        after.phase = .afterBooking
        var pinWrong = current
        pinWrong.pinWrong = true
        let (before, booked, wrongPIN) = (current, after, pinWrong)
        return ConformanceSubject(
            name: "DKBConnector (MT940-Fallback, synthetischer Server)",
            makeConnector: { makeDKBConnector(FakeDKB(before)) },
            pending: .scenario(before: { makeDKBConnector(FakeDKB(before)) }, after: { makeDKBConnector(FakeDKB(booked)) }),
            failures: [.init("Falsche PIN", expected: .authFailed) { makeDKBConnector(FakeDKB(wrongPIN)) }],
            secrets: FakeDKB.secrets
        )
    }

    @Test func conformanceWithMT940Fallback() async {
        let report = await ConnectorConformance.run(Self.mt940Subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed)
    }

    @Test func conformance() async {
        let report = await ConnectorConformance.run(Self.subject())
        #expect(report.passed, "\(report)")
        #expect(report.outcome(of: "pending → booked") == .passed)
        #expect(report.outcome(of: "since respektiert") == .passed)
    }
}
