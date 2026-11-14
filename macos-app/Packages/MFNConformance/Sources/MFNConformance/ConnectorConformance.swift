import Foundation
import MFNCore
import OSLog

/// What a connector package hands to the conformance suite.
///
/// Every factory must build a connector over **fixtures** (recorded, anonymised bank answers),
/// never against a real bank. Each call returns a fresh instance in its initial state.
public struct ConformanceSubject: Sendable {
    public typealias Factory = @Sendable () async throws -> any BankConnector

    public enum PendingScenario: Sendable {
        /// `before` reports pending transactions; `after` is the same account after booking.
        case scenario(before: Factory, after: Factory)
        /// The bank has no pending transactions (e.g. ING via MT940). Reason is shown in the report.
        case notApplicable(reason: String)
    }

    public struct FailureScenario: Sendable {
        public var name: String
        /// `nil` accepts any `ConnectorError`.
        public var expected: ConnectorError?
        public var makeConnector: Factory

        public init(_ name: String, expected: ConnectorError? = nil, makeConnector: @escaping Factory) {
            self.name = name
            self.expected = expected
            self.makeConnector = makeConnector
        }
    }

    public var name: String
    public var makeConnector: Factory
    public var pending: PendingScenario
    /// At least one: wrong credentials, expired session, unparsable answer, 429 …
    public var failures: [FailureScenario]
    /// Strings that must never appear in logs: fixture PIN, TAN, password, cookie, token, IBANs …
    public var secrets: [String]

    public init(name: String, makeConnector: @escaping Factory, pending: PendingScenario, failures: [FailureScenario], secrets: [String]) {
        self.name = name
        self.makeConnector = makeConnector
        self.pending = pending
        self.failures = failures
        self.secrets = secrets
    }
}

public struct ConformanceReport: Sendable, CustomStringConvertible {
    public struct Check: Sendable {
        public enum Outcome: Sendable, Equatable {
            case passed
            case failed([String])
            case notApplicable(String)
        }

        public var name: String
        public var outcome: Outcome
    }

    public var subject: String
    public var checks: [Check]

    public var failures: [String] {
        checks.flatMap { check -> [String] in
            if case let .failed(messages) = check.outcome { return messages.map { "[\(check.name)] \($0)" } }
            return []
        }
    }

    public var passed: Bool { failures.isEmpty }

    public func outcome(of name: String) -> Check.Outcome? {
        checks.first { $0.name == name }?.outcome
    }

    public var description: String {
        var lines = ["Conformance \(subject): \(passed ? "BESTANDEN" : "FEHLGESCHLAGEN")"]
        for check in checks {
            switch check.outcome {
            case .passed: lines.append("  ✓ \(check.name)")
            case let .notApplicable(reason): lines.append("  – \(check.name): \(reason)")
            case let .failed(messages): lines.append(contentsOf: ["  ✗ \(check.name)"] + messages.map { "      \($0)" })
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Acceptance suite every connector must pass before its branch is merged (docs/archive/phase-2/ORCHESTRATOR.md).
///
/// Framework-neutral: returns a report, the package's test asserts `report.passed`.
/// ```swift
/// @Test func conformance() async {
///     let report = await ConnectorConformance.run(subject)
///     #expect(report.passed, "\(report)")
/// }
/// ```
public enum ConnectorConformance {
    public static let checkNames = [
        "Modell-Invarianten",
        "Fingerprint stabil",
        "since respektiert",
        "pending → booked",
        "Fehlerpfade",
        "Keine Secrets in Logs",
    ]

    public static func run(_ subject: ConformanceSubject) async -> ConformanceReport {
        let start = Date()
        var checks: [ConformanceReport.Check] = []

        let first: Snapshot
        do {
            first = try await Snapshot.load(subject.makeConnector())
        } catch {
            return ConformanceReport(subject: subject.name, checks: [
                .init(name: "Abruf", outcome: .failed(["Abruf über Fixtures schlägt fehl: \(describe(error))"])),
            ])
        }

        checks.append(.init(name: checkNames[0], outcome: invariants(first)))
        checks.append(.init(name: checkNames[1], outcome: await fingerprintStability(subject, first: first)))
        checks.append(.init(name: checkNames[2], outcome: await sinceRespected(subject, first: first)))
        checks.append(.init(name: checkNames[3], outcome: await pendingToBooked(subject)))
        checks.append(.init(name: checkNames[4], outcome: await errorPaths(subject, first: first)))
        checks.append(.init(name: checkNames[5], outcome: logRedaction(subject, since: start)))
        return ConformanceReport(subject: subject.name, checks: checks)
    }

    // MARK: - Snapshot

    struct Snapshot {
        var connector: any BankConnector
        var accounts: [Account]
        var transactions: [AccountID: [Transaction]]
        var balances: [AccountID: Balance]
        var statements: [AccountID: [CardStatement]]
        var securities: [AccountID: [SecurityPosition]]

        static func load(_ connector: any BankConnector, since: Date? = nil) async throws -> Snapshot {
            let accounts = try await connector.accounts()
            var snapshot = Snapshot(connector: connector, accounts: accounts, transactions: [:], balances: [:], statements: [:], securities: [:])
            for account in accounts {
                snapshot.balances[account.id] = try await connector.balance(for: account)
                snapshot.transactions[account.id] = try await connector.transactions(for: account, since: since)
                snapshot.statements[account.id] = try await connector.cardStatements(for: account)
                snapshot.securities[account.id] = try await connector.securities(for: account)
            }
            return snapshot
        }
    }

    // MARK: - Checks

    static func invariants(_ snapshot: Snapshot) -> ConformanceReport.Check.Outcome {
        var problems: [String] = []
        if snapshot.accounts.isEmpty { problems.append("accounts() liefert keine Konten") }
        if Set(snapshot.accounts.map(\.id)).count != snapshot.accounts.count { problems.append("Konto-IDs nicht eindeutig") }

        for account in snapshot.accounts {
            let label = "Konto \(account.id)"
            if !isCurrency(account.currency) { problems.append("\(label): Währung '\(account.currency)' ist kein ISO-4217-Code") }
            if account.type == .card, account.cardLast4.map({ $0.count == 4 && $0.allSatisfy(\.isNumber) }) == false {
                problems.append("\(label): cardLast4 muss 4 Ziffern haben")
            }
            let transactions = snapshot.transactions[account.id] ?? []
            if Set(transactions.map(\.id)).count != transactions.count {
                problems.append("\(label): Transaktions-IDs nicht eindeutig (Transaction.uniquingIDs verwenden)")
            }
            for transaction in transactions {
                let tLabel = "\(label) / \(transaction.id)"
                if transaction.accountID != account.id { problems.append("\(tLabel): accountID passt nicht zum Konto") }
                if !isCurrency(transaction.currency) { problems.append("\(tLabel): ungültige Währung") }
                if (transaction.status == .pending || transaction.status == .planned), transaction.bookingDate != nil {
                    problems.append("\(tLabel): \(transaction.status.rawValue) darf kein bookingDate haben")
                }
                if transaction.status == .booked, transaction.bookingDate == nil {
                    problems.append("\(tLabel): booked braucht ein bookingDate")
                }
                if (transaction.originalAmountCents == nil) != (transaction.originalCurrency == nil) {
                    problems.append("\(tLabel): originalAmountCents und originalCurrency nur gemeinsam")
                }
                if transaction.categoryID != nil || transaction.categorySource != nil || transaction.confidence != nil {
                    problems.append("\(tLabel): Connectoren kategorisieren nicht (nur MFNCore)")
                }
                if (try? JSONSerialization.jsonObject(with: transaction.rawJSON, options: [.fragmentsAllowed])) == nil {
                    problems.append("\(tLabel): rawJSON ist kein gültiges JSON")
                }
                let recomputed = Fingerprint.make(accountID: transaction.accountID, bookingDate: transaction.bookingDate, amountCents: transaction.amountCents, purpose: transaction.purpose, counterpartIBAN: transaction.counterpartIBAN)
                if recomputed != transaction.fingerprint { problems.append("\(tLabel): Fingerprint weicht von Fingerprint.make ab") }
            }
            let statements = snapshot.statements[account.id] ?? []
            if account.type != .card, !statements.isEmpty { problems.append("\(label): cardStatements nur für Kartenkonten") }
            for statement in statements {
                if statement.accountID != account.id { problems.append("\(label): Abrechnung mit fremder accountID") }
                if statement.periodStart > statement.periodEnd { problems.append("\(label): Abrechnungsperiode endet vor Beginn") }
            }
            let positions = snapshot.securities[account.id] ?? []
            if account.type != .depot, !positions.isEmpty { problems.append("\(label): securities nur für Depots") }
            for position in positions {
                if position.accountID != account.id { problems.append("\(label): Position mit fremder accountID") }
                if !isISIN(position.isin) { problems.append("\(label): ISIN '\(position.isin)' ungültig") }
            }
        }
        return problems.isEmpty ? .passed : .failed(Array(problems.prefix(25)))
    }

    static func fingerprintStability(_ subject: ConformanceSubject, first: Snapshot) async -> ConformanceReport.Check.Outcome {
        do {
            let second = try await Snapshot.load(subject.makeConnector())
            var problems: [String] = []
            if second.accounts.map(\.id) != first.accounts.map(\.id) { problems.append("Konto-IDs ändern sich zwischen zwei Läufen") }
            for account in first.accounts {
                let a = (first.transactions[account.id] ?? []).map { "\($0.id.rawValue) \($0.fingerprint)" }.sorted()
                let b = (second.transactions[account.id] ?? []).map { "\($0.id.rawValue) \($0.fingerprint)" }.sorted()
                if a != b { problems.append("Konto \(account.id): IDs/Fingerprints unterscheiden sich zwischen zwei Läufen") }
            }
            return problems.isEmpty ? .passed : .failed(problems)
        } catch {
            return .failed(["Zweiter Lauf schlägt fehl: \(describe(error))"])
        }
    }

    static func sinceRespected(_ subject: ConformanceSubject, first: Snapshot) async -> ConformanceReport.Check.Outcome {
        do {
            let connector = try await subject.makeConnector()
            var problems: [String] = []
            var tested = 0
            for account in first.accounts {
                let all = first.transactions[account.id] ?? []
                let days = Set(all.map(\.effectiveDate)).sorted()
                guard days.count >= 2 else { continue }
                let cut = days[days.count / 2]
                tested += 1
                let filtered = try await connector.transactions(for: account, since: cut.startDate)
                let tooOld = filtered.filter { $0.status != .pending && $0.effectiveDate < cut }
                if !tooOld.isEmpty { problems.append("Konto \(account.id): \(tooOld.count) Buchungen vor since=\(cut)") }
                let expected = Set(all.filter { $0.effectiveDate >= cut }.map(\.id))
                let missing = expected.subtracting(filtered.map(\.id))
                if !missing.isEmpty { problems.append("Konto \(account.id): \(missing.count) Buchungen ab since=\(cut) fehlen") }
            }
            if tested == 0 { return .notApplicable("Kein Konto mit Buchungen an mindestens zwei Tagen in den Fixtures") }
            return problems.isEmpty ? .passed : .failed(problems)
        } catch {
            return .failed(["transactions(since:) schlägt fehl: \(describe(error))"])
        }
    }

    static func pendingToBooked(_ subject: ConformanceSubject) async -> ConformanceReport.Check.Outcome {
        switch subject.pending {
        case let .notApplicable(reason):
            return .notApplicable(reason)
        case let .scenario(makeBefore, makeAfter):
            do {
                let before = try await Snapshot.load(makeBefore())
                let after = try await Snapshot.load(makeAfter())
                var problems: [String] = []
                var pendingSeen = 0
                for account in after.accounts {
                    let old = before.transactions[account.id] ?? []
                    let new = after.transactions[account.id] ?? []
                    pendingSeen += old.filter { $0.status == .pending }.count
                    // Stored state after two syncs, exactly as the store applies merges.
                    let merge = TransactionMerger.merge(stored: old, incoming: new, since: nil)
                    let replaced = merge.deletions.union(merge.upserts.map(\.id))
                    let stored = old.filter { !replaced.contains($0.id) } + merge.upserts
                    let newIDs = Set(new.map(\.id))
                    // Doubled: a pending row left next to a booking that resolves it and did not
                    // resolve another one (also when the bank lists reservation and booking together).
                    let resolvedBookings = Set(merge.resolved.values)
                    var bookings = stored.filter { $0.status == .booked && !resolvedBookings.contains($0.id) }
                    let stalePending = stored.filter { pending in
                        guard pending.status == .pending,
                              let index = bookings.firstIndex(where: { TransactionMerger.resolves(pending: pending, booked: $0) })
                        else { return false }
                        bookings.remove(at: index)
                        return true
                    }
                    if !stalePending.isEmpty {
                        problems.append("Konto \(account.id): \(stalePending.count) vorgemerkte Umsätze bleiben neben der Buchung stehen (verdoppelt)")
                    }
                    let unresolved = old.filter { $0.status == .pending && !newIDs.contains($0.id) && merge.resolved[$0.id] == nil }
                    if !unresolved.isEmpty {
                        problems.append("Konto \(account.id): \(unresolved.count) vorgemerkte Umsätze finden keine Buchung (Händler + Betrag + Datum ± 3 Tage)")
                    }
                }
                if pendingSeen == 0 { problems.append("Szenario 'before' enthält keine vorgemerkten Umsätze") }
                return problems.isEmpty ? .passed : .failed(problems)
            } catch {
                return .failed(["pending-Szenario schlägt fehl: \(describe(error))"])
            }
        }
    }

    static func errorPaths(_ subject: ConformanceSubject, first: Snapshot) async -> ConformanceReport.Check.Outcome {
        var problems: [String] = []
        if subject.failures.isEmpty { problems.append("Keine Fehlerszenarien angegeben (mind. falsche Zugangsdaten)") }

        for scenario in subject.failures {
            do {
                let connector = try await scenario.makeConnector()
                _ = try await Snapshot.load(connector)
                problems.append("\(scenario.name): kein Fehler geworfen")
            } catch let error as ConnectorError {
                if let expected = scenario.expected, !sameCase(expected, error) {
                    problems.append("\(scenario.name): erwartet \(expected), geworfen \(error)")
                }
            } catch {
                problems.append("\(scenario.name): wirft \(type(of: error)) statt ConnectorError")
            }
        }

        // An account the connector never delivered must be rejected with a ConnectorError.
        if let template = first.accounts.first {
            let foreign = Account(id: "conformance-foreign", connectionID: "conformance-foreign", type: template.type, name: "Fremd")
            do {
                _ = try await first.connector.balance(for: foreign)
                _ = try await first.connector.transactions(for: foreign, since: nil)
                problems.append("Fremdes Konto wird nicht abgelehnt")
            } catch is ConnectorError {
                // expected
            } catch {
                problems.append("Fremdes Konto: wirft \(type(of: error)) statt ConnectorError")
            }
        }
        return problems.isEmpty ? .passed : .failed(problems)
    }

    /// Reads this process's unified log (info and above) since the run started.
    /// `.private` values appear as `<private>` here, so any secret in plain text is a leak.
    /// Limitation: `.debug` entries are not persisted and therefore not checked.
    static func logRedaction(_ subject: ConformanceSubject, since start: Date) -> ConformanceReport.Check.Outcome {
        let messages: [String]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: start.addingTimeInterval(-1))
            let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", Log.subsystem)
            messages = try store.getEntries(at: position, matching: predicate)
                .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
        } catch {
            return .failed(["Log nicht lesbar: \(error.localizedDescription)"])
        }
        var problems: [String] = []
        for secret in subject.secrets where !secret.isEmpty {
            if messages.contains(where: { $0.contains(secret) }) {
                problems.append("Secret im Klartext geloggt (\(secret.count) Zeichen, beginnt mit '\(secret.prefix(2))…')")
            }
        }
        let ibanPattern = /[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{4}){3,7}/
        if let line = messages.first(where: { $0.contains(ibanPattern) }) {
            problems.append("IBAN im Klartext geloggt: '\(line.prefix(60))…'")
        }
        return problems.isEmpty ? .passed : .failed(problems)
    }

    // MARK: - Helpers

    static func isCurrency(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    static func isISIN(_ isin: String) -> Bool {
        isin.count == 12 && isin.prefix(2).allSatisfy { $0.isASCII && $0.isUppercase } && isin.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func sameCase(_ lhs: ConnectorError, _ rhs: ConnectorError) -> Bool {
        switch (lhs, rhs) {
        case (.authRequired, .authRequired), (.authFailed, .authFailed), (.sessionExpired, .sessionExpired),
             (.rateLimited, .rateLimited), (.bankUnavailable, .bankUnavailable), (.formatChanged, .formatChanged),
             (.unsupportedAccount, .unsupportedAccount), (.cancelled, .cancelled):
            true
        default:
            false
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ConnectorError { return "ConnectorError.\(error)" }
        return "\(type(of: error)) (kein ConnectorError)"
    }
}
