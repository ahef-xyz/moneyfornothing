import Foundation
import MFNCore
import MFNMock
import os
import Testing
@testable import MFNConformance

private let dataset = MockDataset.demo(today: BankDay(iso: "2026-11-09") ?? .today)

/// Reference subject: the MockConnector must pass the full suite.
private func mockSubject(connection: ConnectionID = MockConnections.dkb) -> ConformanceSubject {
    ConformanceSubject(
        name: "MockConnector",
        makeConnector: { MockConnector(connection: connection, dataset: dataset) },
        pending: .scenario(
            before: { MockConnector(connection: connection, dataset: dataset) },
            after: { MockConnector(connection: connection, dataset: dataset, phase: .afterBooking) }
        ),
        failures: [
            .init("Falsche PIN", expected: .authFailed) { MockConnector(connection: connection, dataset: dataset, scenario: .failing(.authFailed)) },
            .init("Sitzung abgelaufen", expected: .sessionExpired) { MockConnector(connection: connection, dataset: dataset, scenario: .failing(.sessionExpired)) },
            .init("429", expected: .rateLimited(retryAfter: 0)) { MockConnector(connection: connection, dataset: dataset, scenario: .failing(.rateLimited(retryAfter: 60))) },
            .init("Freigabe ohne Presenter", expected: .authRequired(.pushConfirm(message: ""))) {
                MockConnector(connection: connection, dataset: dataset, scenario: .requiresApproval(.pushConfirm(message: "Bitte bestätigen")))
            },
        ],
        secrets: ["mock-pin-12345", "mock-session-cookie-abcdef"]
    )
}

@Suite(.serialized) struct MockConformanceTests {
    @Test(arguments: [MockConnections.ing, MockConnections.dkb, MockConnections.tradeRepublic, MockConnections.c24, MockConnections.easybank])
    func mockConnectorPasses(connection: ConnectionID) async {
        let report = await ConnectorConformance.run(mockSubject(connection: connection))
        #expect(report.passed, "\(report)")
        #expect(report.checks.count == ConnectorConformance.checkNames.count)
    }
}

// MARK: - The suite must catch broken connectors

/// Wraps the mock and injects one defect.
private struct BrokenConnector: BankConnector {
    enum Defect: Sendable { case ignoresSince, unstableFingerprint, throwsForeignError, leaksSecret, categorises, keepsDuplicatePending }
    let defect: Defect
    let base = MockConnector(connection: MockConnections.dkb, dataset: dataset)
    var id: ConnectorID { base.id }
    private static let log = Logger(subsystem: Log.subsystem, category: "broken-test")

    func accounts() async throws -> [Account] {
        if defect == .leaksSecret { Self.log.error("login with pin \("broken-leak-secret-987", privacy: .public)") }
        if defect == .throwsForeignError { throw URLError(.timedOut) }
        return try await base.accounts()
    }

    func balance(for account: Account) async throws -> Balance { try await base.balance(for: account) }

    func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        switch defect {
        case .ignoresSince:
            return try await base.transactions(for: account, since: nil)
        case .unstableFingerprint:
            let list = try await base.transactions(for: account, since: since)
            let salt = UUID().uuidString
            return list.map { t in
                Transaction(accountID: t.accountID, bookingDate: t.bookingDate, valueDate: t.valueDate, amountCents: t.amountCents, counterpartName: t.counterpartName, purpose: t.purpose + salt, status: t.status, rawJSON: t.rawJSON)
            }
        case .categorises:
            return try await base.transactions(for: account, since: since).map { var t = $0; t.categoryID = "x"; t.categorySource = .rule; return t }
        default:
            return try await base.transactions(for: account, since: since)
        }
    }

    func cardStatements(for account: Account) async throws -> [CardStatement] { try await base.cardStatements(for: account) }
    func securities(for account: Account) async throws -> [SecurityPosition] { try await base.securities(for: account) }
}

/// "After booking" connector whose booked rows carry a different merchant and amount, so pendings cannot match.
private struct NonMatchingAfter: BankConnector {
    let base = MockConnector(connection: MockConnections.dkb, dataset: dataset, phase: .afterBooking)
    var id: ConnectorID { base.id }
    func accounts() async throws -> [Account] { try await base.accounts() }
    func balance(for account: Account) async throws -> Balance { try await base.balance(for: account) }
    func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        let before = Set(dataset.transactions[account.id]?.filter { $0.status == .pending }.map(\.valueDate) ?? [])
        return try await base.transactions(for: account, since: since).map { t in
            guard before.contains(t.valueDate), t.bookingDate == t.valueDate.adding(days: 2) else { return t }
            return Transaction(accountID: t.accountID, bookingDate: t.bookingDate, valueDate: t.valueDate, amountCents: t.amountCents - 1, counterpartName: "Ganz anders", purpose: t.purpose, status: .booked)
        }
    }
    func cardStatements(for account: Account) async throws -> [CardStatement] { try await base.cardStatements(for: account) }
    func securities(for account: Account) async throws -> [SecurityPosition] { try await base.securities(for: account) }
}

/// "After booking" connector that still lists the reservations next to their bookings.
private struct PendingAndBookedAfter: BankConnector {
    let before = MockConnector(connection: MockConnections.dkb, dataset: dataset)
    let base = MockConnector(connection: MockConnections.dkb, dataset: dataset, phase: .afterBooking)
    var id: ConnectorID { base.id }
    func accounts() async throws -> [Account] { try await base.accounts() }
    func balance(for account: Account) async throws -> Balance { try await base.balance(for: account) }
    func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        let after = try await base.transactions(for: account, since: since)
        let afterIDs = Set(after.map(\.id))
        let reservations = try await before.transactions(for: account, since: since).filter { $0.status == .pending && !afterIDs.contains($0.id) }
        return after + reservations
    }
    func cardStatements(for account: Account) async throws -> [CardStatement] { try await base.cardStatements(for: account) }
    func securities(for account: Account) async throws -> [SecurityPosition] { try await base.securities(for: account) }
}

@Suite(.serialized) struct PendingTogetherWithBookingTests {
    @Test func reservationListedNextToBookingIsNotDoubled() async {
        var subject = mockSubject()
        subject.pending = .scenario(before: { MockConnector(connection: MockConnections.dkb, dataset: dataset) }, after: { PendingAndBookedAfter() })
        let report = await ConnectorConformance.run(subject)
        #expect(report.outcome(of: "pending → booked")?.isFailure == false, "\(report)")
    }
}

@Suite(.serialized) struct SuiteDetectsDefectsTests {
    private func subject(_ defect: BrokenConnector.Defect) -> ConformanceSubject {
        var subject = mockSubject()
        subject.makeConnector = { BrokenConnector(defect: defect) }
        return subject
    }

    @Test func detectsIgnoredSince() async {
        let report = await ConnectorConformance.run(subject(.ignoresSince))
        #expect(report.outcome(of: "since respektiert")?.isFailure == true, "\(report)")
    }

    @Test func detectsUnstableFingerprint() async {
        let report = await ConnectorConformance.run(subject(.unstableFingerprint))
        #expect(report.outcome(of: "Fingerprint stabil")?.isFailure == true, "\(report)")
    }

    @Test func detectsForeignErrors() async {
        var subject = mockSubject()
        subject.failures.append(.init("Timeout") { BrokenConnector(defect: .throwsForeignError) })
        let report = await ConnectorConformance.run(subject)
        #expect(report.outcome(of: "Fehlerpfade")?.isFailure == true, "\(report)")
    }

    @Test func detectsLoggedSecret() async {
        var subject = subject(.leaksSecret)
        subject.secrets = ["broken-leak-secret-987"]
        let report = await ConnectorConformance.run(subject)
        #expect(report.outcome(of: "Keine Secrets in Logs")?.isFailure == true, "\(report)")
    }

    @Test func detectsCategorisationInConnector() async {
        let report = await ConnectorConformance.run(subject(.categorises))
        #expect(report.outcome(of: "Modell-Invarianten")?.isFailure == true, "\(report)")
    }

    @Test func detectsUnmatchedPending() async {
        var subject = mockSubject()
        subject.pending = .scenario(before: { MockConnector(connection: MockConnections.dkb, dataset: dataset) }, after: { NonMatchingAfter() })
        let report = await ConnectorConformance.run(subject)
        #expect(report.outcome(of: "pending → booked")?.isFailure == true, "\(report)")
    }

    @Test func missingFailureScenariosFail() async {
        var subject = mockSubject()
        subject.failures = []
        let report = await ConnectorConformance.run(subject)
        #expect(!report.passed)
    }
}

extension ConformanceReport.Check.Outcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
