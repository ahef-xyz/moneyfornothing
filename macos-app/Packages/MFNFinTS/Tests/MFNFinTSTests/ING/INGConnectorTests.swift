import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNFinTS

@Suite struct INGConnectorTests {
    private func account(_ connector: INGConnector, _ type: AccountType) async throws -> Account {
        try #require(try await connector.accounts().first { $0.type == type })
    }

    @Test func accountsFromUPD() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "ing-test", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        let accounts = try await connector.accounts()
        #expect(accounts.map(\.type) == [.giro, .tagesgeld, .depot]) // loan is skipped
        #expect(accounts.map(\.name) == ["Girokonto", "Extra-Konto", "Direkt-Depot"])
        #expect(accounts[0].iban == FakeING.giroIBAN)
        #expect(accounts[2].iban == nil)
        #expect(accounts.allSatisfy { $0.connectionID == "ing-test" && $0.currency == "EUR" })
        // IDs are opaque and stable.
        #expect(accounts.allSatisfy { $0.id.rawValue.hasPrefix("ing-") && !$0.id.rawValue.contains(FakeING.giroNumber) })
        #expect(try await FakeING().connector().accounts().map(\.id) == accounts.map(\.id))
        // A second connection with the same accounts gets different IDs.
        #expect(try await FakeING().connector(connectionID: "ing-other").accounts().map(\.id) != accounts.map(\.id))

        #expect(await connector.systemID == "ING-SYS-0815")
        #expect(await transport.requestTypes == [["HKIDN", "HKVVB", "HKSYN"], ["HKEND"]])
    }

    @Test func oneStepSecurityAndNoTANForBusinessSegments() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        let giro = try await account(connector, .giro)
        _ = try await connector.balance(for: giro)
        await connector.endDialog()
        let requests = await transport.requests
        // Security function 999 under one-step profile PIN:1 in every signature head, no HKTAN
        // (ING rejected PIN:2 + HKTAN live with 9010, 2026-11-12).
        let signatureHeads = requests.compactMap { $0.first { $0.type == "HNSHK" } }
        #expect(!signatureHeads.isEmpty && signatureHeads.allSatisfy { $0[1].first == "999" })
        #expect(signatureHeads.allSatisfy { $0[0].components.map { $0?.text } == ["PIN", "1"] })
        #expect(await transport.requestTypes == [
            ["HKIDN", "HKVVB", "HKSYN"], ["HKEND"],
            ["HKIDN", "HKVVB"], ["HKSAL"], ["HKEND"],
        ])
        // Later dialogs reuse the system ID.
        #expect(requests[2].first { $0.type == "HKIDN" }?[2].first == "ING-SYS-0815")
    }

    @Test func balanceFromHISAL() async throws {
        let connector = FakeING().connector()
        let giro = try await account(connector, .giro)
        let balance = try await connector.balance(for: giro)
        #expect(balance == Balance(bookedCents: 349_680, availableCents: 449_680, currency: "EUR", asOf: FakeING.now))
    }

    @Test func transactionsPageThroughTouchdownAndMapMT940() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        let giro = try await account(connector, .giro)
        let transactions = try await connector.transactions(for: giro, since: nil)

        #expect(transactions.count == 4)
        #expect(transactions.map(\.amountCents) == [-1250, 250_000, -320, 1250])
        #expect(transactions.allSatisfy { $0.status == .booked && $0.accountID == giro.id && $0.currency == "EUR" })
        let debit = transactions[0]
        #expect(debit.bookingDate == BankDay(year: 2026, month: 10, day: 21))
        #expect(debit.counterpartName == "Stadtwerke Müllheim GmbH")
        #expect(debit.counterpartIBAN == FakeING.counterpartIBANs[0])
        #expect(debit.purpose == "Rechnung 4711 Strom Oktober")
        #expect(debit.eref == "E2E-0001")
        #expect(debit.mref == "M-77")
        #expect(debit.creditorID == "DE98ZZZ09999999999")
        #expect(debit.id.rawValue == "fp:\(debit.fingerprint)")
        let raw = try #require(try JSONSerialization.jsonObject(with: debit.rawJSON) as? [String: Any])
        #expect(raw["format"] as? String == "MT940")
        #expect(raw["gvc"] as? String == "105")
        #expect((raw["61"] as? String)?.hasPrefix("2610211021DR12,50") == true)
        // Card payment without counterpart name falls back to the posting text.
        #expect(transactions[2].counterpartName == "Kartenzahlung")
        #expect(transactions[2].counterpartIBAN == nil)

        // Two pages: the second HKKAZ carries the touchdown point.
        let kaz = await transport.requests.compactMap { $0.first { $0.type == "HKKAZ" } }
        #expect(kaz.map { $0[5].first } == [nil, "ING-TD-2"])
        #expect(kaz.allSatisfy { $0.version == 7 })
        // since nil → whole storage period (90 days, today is day 1).
        #expect(kaz.allSatisfy { $0[2].first == "20260812" && $0[3].first == nil })
    }

    @Test func sinceOlderThan90DaysIsCappedAndFiltered() async throws {
        let transport = FakeING(pagedStatements: false).transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        let giro = try await account(connector, .giro)

        let oneYearAgo = FakeING.now.addingTimeInterval(-365 * 86400)
        #expect(try await connector.transactions(for: giro, since: oneYearAgo).count == 4)
        let cut = try #require(BankDay(year: 2026, month: 10, day: 23))
        let recent = try await connector.transactions(for: giro, since: cut.startDate)
        #expect(recent.map(\.amountCents) == [-320, 1250])

        let kaz = await transport.requests.compactMap { $0.first { $0.type == "HKKAZ" } }
        #expect(kaz.map { $0[2].first } == ["20260812", "20261023"])
    }

    @Test func fingerprintsStableAcrossRuns() async throws {
        let a = FakeING().connector()
        let b = FakeING(pagedStatements: false).connector()
        let first = try await a.transactions(for: try await account(a, .giro), since: nil)
        let second = try await b.transactions(for: try await account(b, .giro), since: nil)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.fingerprint) == second.map(\.fingerprint))
    }

    @Test func accountWithoutBookingsAnswers9010() async throws {
        for bank in [FakeING(emptyExtraKonto: true), FakeING(emptyExtraKontoMessageLevel: true)] {
            let transport = bank.transport()
            let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
            let extra = try await account(connector, .tagesgeld)
            await #expect(throws: ConnectorError.unsupportedAccount) {
                try await connector.transactions(for: extra, since: nil)
            }
            // The Giro of the same login still works.
            #expect(try await connector.transactions(for: try await account(connector, .giro), since: nil).count == 4)
            // Every dialog opened (sync, shared, a new one after a message-level abort) is ended.
            await connector.endDialog()
            let types = await transport.requestTypes
            #expect(types.filter { $0.contains("HKIDN") }.count == types.filter { $0 == ["HKEND"] }.count)
        }
    }

    @Test func depotPositionsAndBalance() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        let depot = try await account(connector, .depot)
        let positions = try await connector.securities(for: depot)
        #expect(positions.map(\.isin) == ["IE00B4L5Y983", "DE0001102580"])
        #expect(positions.allSatisfy { $0.accountID == depot.id })
        #expect(try await connector.transactions(for: depot, since: nil).isEmpty)
        #expect(try await connector.balance(for: depot).bookedCents == 1_138_456)
        let wpd = await transport.requests.compactMap { $0.first { $0.type == "HKWPD" } }
        // No output currency: ING answers it with 9210 (live, 2026-11-12).
        #expect(!wpd.isEmpty && wpd.allSatisfy { $0.version == 6 && ($0[1].first ?? nil) == nil })

        let giro = try await account(connector, .giro)
        #expect(try await connector.securities(for: giro).isEmpty)
        #expect(try await connector.cardStatements(for: giro).isEmpty)
    }

    @Test func foreignAccountIsRejectedWithoutDialog() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        _ = try await connector.accounts()
        let before = await transport.requests.count
        let foreign = Account(id: "other", connectionID: "c", type: .giro, name: "Fremd")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.balance(for: foreign) }
        let otherConnection = Account(id: try await account(connector, .giro).id, connectionID: "x", type: .giro, name: "Fremd")
        await #expect(throws: ConnectorError.unsupportedAccount) { try await connector.transactions(for: otherConnection, since: nil) }
        // Only the accounts() call inside `account(…)`: it opens the shared dialog (1 message, no HKEND yet).
        #expect(await transport.requests.count == before + 1)
    }

    /// One dialog for a whole sync (live: ~20 dialogs per sync before, 2026-11-12), ended when idle.
    @Test func consecutiveCallsShareOneDialog() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, systemID: "ING-SYS-0815", idleTimeout: .milliseconds(50), now: { FakeING.now })
        let accounts = try await connector.accounts()
        let giro = try #require(accounts.first { $0.type == .giro })
        _ = try await connector.balance(for: giro)
        _ = try await connector.transactions(for: giro, since: nil)
        let depot = try #require(accounts.first { $0.type == .depot })
        _ = try await connector.securities(for: depot)
        let before = await transport.requestTypes
        #expect(before.filter { $0.contains("HKIDN") }.count == 1)
        #expect(!before.contains(["HKEND"]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await transport.requestTypes.last == ["HKEND"])
        #expect(await transport.requestTypes.filter { $0 == ["HKEND"] }.count == 1)
    }

    @Test func wrongPINIsAuthFailedAfterOneAttempt() async throws {
        let transport = FakeING(failure: .pinWrong).transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: "falsch", transport: transport, now: { FakeING.now })
        await #expect(throws: ConnectorError.authFailed) { try await connector.accounts() }
        // Exactly one login attempt – never retried automatically (lock-out risk).
        #expect(await transport.requestTypes.filter { $0.contains("HKIDN") }.count == 1)
    }

    @Test func transportErrorsPassThrough() async {
        await #expect(throws: ConnectorError.bankUnavailable) { try await FakeING(failure: .unavailable).connector().accounts() }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: 120)) { try await FakeING(failure: .rateLimited).connector().accounts() }
    }

    @Test func garbledStatementIsFormatChanged() async throws {
        let connector = FakeING(failure: .garbledStatement).connector()
        let giro = try await account(connector, .giro)
        do {
            _ = try await connector.transactions(for: giro, since: nil)
            Issue.record("expected formatChanged")
        } catch {
            guard case .formatChanged = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func dialogsNeverOverlap() async throws {
        let transport = FakeING().transport()
        let connector = INGConnector(connectionID: "c", userID: FakeING.userID, pin: FakeING.pin, transport: transport, now: { FakeING.now })
        let accounts = try await connector.accounts()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { _ = try await connector.balance(for: account) }
                group.addTask { _ = try await connector.transactions(for: account, since: nil) }
            }
            try await group.waitForAll()
        }
        var open = false
        for types in await transport.requestTypes {
            if types.contains("HKIDN") {
                #expect(!open, "Dialog geöffnet, während ein anderer noch offen ist")
                open = true
            }
            if types.contains("HKEND") { open = false }
        }
    }

    @Test func pinIsNeverInDescriptions() async throws {
        let connector = FakeING().connector()
        #expect(!String(describing: connector).contains(FakeING.pin))
        #expect(!String(reflecting: connector).contains(FakeING.pin))
    }
}

@Suite struct INGConformanceTests {
    static let subject = ConformanceSubject(
        name: "ING (FinTS, Fake-Server)",
        makeConnector: { FakeING().connector() },
        pending: .notApplicable(reason: "ING liefert per FinTS nur MT940 ohne vorgemerkte Umsätze"),
        failures: [
            .init("Falsche PIN", expected: .authFailed) { FakeING(failure: .pinWrong).connector() },
            .init("Bank nicht erreichbar", expected: .bankUnavailable) { FakeING(failure: .unavailable).connector() },
            .init("429", expected: .rateLimited(retryAfter: 120)) { FakeING(failure: .rateLimited).connector() },
            .init("MT940 kaputt", expected: .formatChanged(detail: "")) { FakeING(failure: .garbledStatement).connector() },
            .init("Konto ohne Zahlungseingang (9010)", expected: .unsupportedAccount) { FakeING(emptyExtraKonto: true).connector() },
        ],
        secrets: FakeING.secrets
    )

    @Test func conformance() async {
        let report = await ConnectorConformance.run(Self.subject)
        #expect(report.passed, "\(report)")
        // Everything except pending → booked must actually run.
        for name in ConnectorConformance.checkNames where name != "pending → booked" {
            #expect(report.outcome(of: name) == .passed, "\(name): \(String(describing: report.outcome(of: name)))")
        }
    }
}
