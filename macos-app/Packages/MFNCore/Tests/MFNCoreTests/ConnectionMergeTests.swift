import Foundation
import Testing
@testable import MFNCore

/// Synthetic data only: web banking (`web`) merged into FinTS (`fints`) of the same bank.
@Suite struct ConnectionMergeTests {
    static let web = Connection(id: "ing-web", connectorID: .ing, displayName: "ING")
    static let fints = Connection(id: "fints-ing-1", connectorID: .ing, displayName: "ING")

    static func day(_ string: String) -> BankDay {
        BankDay(iso: string) ?? .today
    }

    static func booking(
        _ account: AccountID, _ date: String, _ cents: Int, _ name: String,
        iban: String? = nil, status: TransactionStatus = .booked, category: CategoryID? = nil, source: CategorySource? = nil
    ) -> Transaction {
        Transaction(
            accountID: account, bookingDate: day(date), valueDate: day(date), amountCents: cents,
            counterpartName: name, counterpartIBAN: iban, purpose: "\(name) \(date)", status: status,
            categoryID: category, categorySource: source
        )
    }

    static func snapshot(accounts: [Account], transactions: [Transaction]) -> LedgerSnapshot {
        var snapshot = LedgerSnapshot()
        snapshot.connections = [web, fints]
        snapshot.accounts = accounts
        snapshot.transactions = transactions
        return snapshot
    }

    @Test func pairsAccountsByIBANThenByOnlyAccountOfAType() throws {
        let accounts = [
            Account(id: "w-giro", connectionID: Self.web.id, iban: "DE02 1203 0000 0000 2020 51", type: .giro, name: "Girokonto"),
            Account(id: "w-extra", connectionID: Self.web.id, iban: "DE02120300000000202052", type: .tagesgeld, name: "Extra-Konto"),
            Account(id: "w-depot", connectionID: Self.web.id, type: .depot, name: "Depot"),
            Account(id: "w-old", connectionID: Self.web.id, iban: "DE02120300000000202099", type: .tagesgeld, name: "Altes Konto"),
            Account(id: "f-giro", connectionID: Self.fints.id, iban: "de02120300000000202051", type: .giro, name: "Girokonto FinTS"),
            Account(id: "f-extra", connectionID: Self.fints.id, iban: "DE02120300000000202052", type: .tagesgeld, name: "Extra"),
            Account(id: "f-depot", connectionID: Self.fints.id, type: .depot, name: "Direkt-Depot"),
            Account(id: "f-new", connectionID: Self.fints.id, iban: "DE02120300000000202077", type: .giro, name: "Neu"),
        ]
        let plan = try ConnectionMerge.plan(Self.snapshot(accounts: accounts, transactions: []), source: Self.web.id, target: Self.fints.id)
        let pairs = plan.accounts.map { "\($0.pair.source.id.rawValue)>\($0.pair.target.id.rawValue):\($0.pair.reason.rawValue)" }
        #expect(pairs == ["w-giro>f-giro:iban", "w-extra>f-extra:iban", "w-depot>f-depot:onlyOfType"])
        #expect(plan.unmatchedSourceAccounts.map(\.id) == ["w-old"])
        #expect(plan.unmatchedTargetAccounts.map(\.id) == ["f-new"])
        // Target accounts take the names shown for their source; equal names need no rename.
        #expect(plan.accounts.map(\.newName) == ["Girokonto", "Extra-Konto", "Depot"])
    }

    @Test func carriesTheUsersOwnAccountName() throws {
        let accounts = [
            Account(id: "w-giro", connectionID: Self.web.id, iban: "DE02120300000000202051", type: .giro, name: "Girokonto"),
            Account(id: "f-giro", connectionID: Self.fints.id, iban: "DE02120300000000202051", type: .giro, name: "Girokonto"),
            Account(id: "w-extra", connectionID: Self.web.id, iban: "DE02120300000000202052", type: .tagesgeld, name: "Extra-Konto"),
            Account(id: "f-extra", connectionID: Self.fints.id, iban: "DE02120300000000202052", type: .tagesgeld, name: "Extra-Konto"),
        ]
        var snapshot = Self.snapshot(accounts: accounts, transactions: [])
        snapshot.customAccountNames = ["w-giro": "Haushalt"]
        let plan = try ConnectionMerge.plan(snapshot, source: Self.web.id, target: Self.fints.id)
        #expect(plan.accounts.map(\.newName) == ["Haushalt", nil])
    }

    @Test func rejectsDifferentBanksAndSameConnection() {
        var snapshot = Self.snapshot(accounts: [], transactions: [])
        snapshot.connections.append(Connection(id: "dkb-1", connectorID: .dkb, displayName: "DKB"))
        #expect(throws: ConnectionMerge.PlanError.differentBanks) { try ConnectionMerge.plan(snapshot, source: "dkb-1", target: Self.fints.id) }
        #expect(throws: ConnectionMerge.PlanError.sameConnection) { try ConnectionMerge.plan(snapshot, source: Self.web.id, target: Self.web.id) }
        #expect(throws: ConnectionMerge.PlanError.unknownConnection) { try ConnectionMerge.plan(snapshot, source: "gone", target: Self.fints.id) }
    }

    @Test func splitsHistoryMatchesAndLeftovers() throws {
        let w: AccountID = "w-giro"
        let f: AccountID = "f-giro"
        let accounts = [
            Account(id: w, connectionID: Self.web.id, iban: "DE02120300000000202051", type: .giro, name: "Giro"),
            Account(id: f, connectionID: Self.fints.id, iban: "DE02120300000000202051", type: .giro, name: "Giro"),
        ]
        let transactions = [
            // Older than the FinTS window: history to move.
            Self.booking(w, "2026-07-01", -4_200, "Stadtwerke Musterstadt", category: "utilities", source: .rule),
            // Same booking, web full name vs. MT940 truncated name, one day apart.
            Self.booking(w, "2026-10-05", -1_999, "Musterladen GmbH Filiale 12", category: "shopping", source: .manual),
            Self.booking(f, "2026-10-06", -1_999, "MUSTERLADEN GMBH"),
            // Same IBAN, names differ completely: strong by IBAN.
            Self.booking(w, "2026-10-10", 250_000, "Arbeitgeber AG", iban: "DE89370400440532013000"),
            Self.booking(f, "2026-10-10", 250_000, "Lohn/Gehalt", iban: "DE89 3704 0044 0532 0130 00"),
            // Only amount and day match: weak.
            Self.booking(w, "2026-10-12", -500, "Kartenzahlung"),
            Self.booking(f, "2026-10-12", -500, "VISA 1234"),
            // Two identical coffees on one day pair one-to-one.
            Self.booking(w, "2026-10-14", -350, "Café Muster"),
            Self.booking(w, "2026-10-14", -350, "Café Muster"),
            Self.booking(f, "2026-10-14", -350, "CAFE MUSTER"),
            Self.booking(f, "2026-10-14", -350, "CAFE MUSTER"),
            // Web only inside the window: suspicious.
            Self.booking(w, "2026-10-20", -7_777, "Nur im Web"),
            // FinTS only: new.
            Self.booking(f, "2026-11-01", -1_234, "Nur FinTS"),
            // Planned in the web: not matchable.
            Self.booking(w, "2026-11-30", -9_900, "Dauerauftrag Miete", status: .planned),
            // Different amount: never a match.
            Self.booking(f, "2026-10-21", -7_778, "Nur im Web"),
        ]
        let plan = try ConnectionMerge.plan(Self.snapshot(accounts: accounts, transactions: transactions), source: Self.web.id, target: Self.fints.id)
        let giro = try #require(plan.accounts.first)
        #expect(giro.windowStart == Self.day("2026-10-06"))
        #expect(giro.history.map(\.counterpartName) == ["Stadtwerke Musterstadt"])
        #expect(giro.matched.count == 5)
        #expect(giro.weakMatches == 1)
        #expect(giro.matched.first { $0.weak }?.target.counterpartName == "VISA 1234")
        #expect(giro.sourceOnlyInWindow.map(\.counterpartName) == ["Nur im Web"])
        #expect(Set(giro.targetOnly.map(\.counterpartName)) == ["Nur FinTS", "Nur im Web"])
        #expect(giro.dropped.map(\.status) == [.planned])
        // The manual category of the web booking goes to the uncategorised FinTS twin.
        #expect(giro.categoriesToCarry == 1)
        // Nothing booked is lost: the web-only booking moves with the history.
        #expect(Set(giro.moving.map(\.counterpartName)) == ["Stadtwerke Musterstadt", "Nur im Web"])
        #expect(plan.suspicious == 1)
    }

    /// Old reservations and orders of the web channel would stay on the target forever.
    @Test func dropsStalePendingAndPlannedButKeepsCancelled() throws {
        let accounts = [
            Account(id: "w", connectionID: Self.web.id, iban: "DE02120300000000202051", type: .giro, name: "Giro"),
            Account(id: "f", connectionID: Self.fints.id, iban: "DE02120300000000202051", type: .giro, name: "Giro"),
        ]
        let plan = try ConnectionMerge.plan(Self.snapshot(accounts: accounts, transactions: [
            Self.booking("w", "2026-06-01", -100, "Alte Reservierung", status: .pending),
            Self.booking("w", "2026-06-02", -200, "Alter Auftrag", status: .planned),
            Self.booking("w", "2026-06-03", -300, "Storniert", status: .cancelled),
            Self.booking("w", "2026-10-20", -400, "Vorgemerkt", status: .pending),
            Self.booking("w", "2026-10-21", -500, "Vorgemerkt mit Zwilling", status: .pending),
            Self.booking("f", "2026-10-01", -999, "FinTS"),
            Self.booking("f", "2026-10-21", -500, "VORGEMERKT MIT ZWILLING", status: .pending),
        ]), source: Self.web.id, target: Self.fints.id)
        let giro = try #require(plan.accounts.first)
        #expect(giro.history.map(\.counterpartName) == ["Storniert"])
        #expect(Set(giro.dropped.map(\.counterpartName)) == ["Alte Reservierung", "Alter Auftrag", "Vorgemerkt"])
        #expect(giro.matched.map(\.source.counterpartName) == ["Vorgemerkt mit Zwilling"])
        #expect(giro.sourceOnlyInWindow.isEmpty)
    }

    @Test func targetWithoutTransactionsTakesAllHistory() throws {
        let accounts = [
            Account(id: "w-depot", connectionID: Self.web.id, type: .depot, name: "Depot"),
            Account(id: "f-depot", connectionID: Self.fints.id, type: .depot, name: "Depot"),
        ]
        let plan = try ConnectionMerge.plan(
            Self.snapshot(accounts: accounts, transactions: [Self.booking("w-depot", "2026-09-01", -100, "Gebühr")]),
            source: Self.web.id, target: Self.fints.id
        )
        let depot = try #require(plan.accounts.first)
        #expect(depot.windowStart == nil)
        #expect(depot.history.count == 1)
        #expect(depot.matched.isEmpty)
    }
}

@Suite struct ConnectionMergeApplyTests {
    typealias T = ConnectionMergeTests

    /// Web giro with an old booking, a duplicate (manual category), a web-only booking in the
    /// window and a budget; FinTS giro with the duplicate's twin.
    static func ledger() -> LedgerSnapshot {
        let accounts = [
            Account(id: "w-giro", connectionID: T.web.id, iban: "DE02120300000000202051", type: .giro, name: "Girokonto"),
            Account(id: "f-giro", connectionID: T.fints.id, iban: "DE02120300000000202051", type: .giro, name: "Girokonto FinTS"),
        ]
        var snapshot = T.snapshot(accounts: accounts, transactions: [
            T.booking("w-giro", "2026-06-01", -4_200, "Stadtwerke", category: "utilities", source: .rule),
            T.booking("w-giro", "2026-10-10", -1_999, "Musterladen", category: "shopping", source: .manual),
            T.booking("w-giro", "2026-10-15", -7_777, "Nur im Web"),
            T.booking("f-giro", "2026-10-10", -1_999, "MUSTERLADEN"),
        ])
        snapshot.customAccountNames = ["w-giro": "Haushalt"]
        snapshot.budgets = ["w-giro": AccountBudget(accountID: "w-giro", amountCents: 100_000)]
        return snapshot
    }

    @Test func movesHistoryCarriesCategoryNameAndBudgetAndRemovesSource() async throws {
        let snapshot = Self.ledger()
        let store = InMemoryLedgerStore(snapshot)
        let changes = ConnectionMerge.changes(try ConnectionMerge.plan(snapshot, source: T.web.id, target: T.fints.id), in: snapshot)
        #expect(changes.accounts == ["w-giro": "f-giro"])
        try await store.applyMerge(changes)

        let after = await store.snapshot()
        #expect(after.connections.map(\.id) == [T.fints.id])
        #expect(after.accounts.map(\.id) == ["f-giro"])
        let giro = after.transactions(of: "f-giro")
        // History and the web-only booking moved (same ID), the duplicate kept once with the manual category.
        #expect(giro.count == 3)
        let old = try #require(giro.first { $0.counterpartName == "Stadtwerke" })
        #expect(old.id == snapshot.transactions[0].id)
        #expect(old.categoryID == "utilities")
        #expect(giro.contains { $0.counterpartName == "Nur im Web" })
        #expect(giro.first { $0.counterpartName == "MUSTERLADEN" }?.categoryID == "shopping")
        #expect(giro.first { $0.counterpartName == "MUSTERLADEN" }?.categorySource == .manual)
        #expect(after.customAccountNames == ["f-giro": "Haushalt"])
        #expect(after.budgets.keys.map(\.rawValue) == ["f-giro"])
        #expect(after.transactions.allSatisfy { $0.accountID == "f-giro" })
    }

    /// A sync replaced the target row meanwhile: the category is carried by ID and never brings
    /// back the stale row.
    @Test func movesDepotHistoryWhereTheTargetHasNoPointOfThatDay() async throws {
        let accounts = [
            Account(id: "w-depot", connectionID: ConnectionMergeTests.web.id, type: .depot, name: "Depot"),
            Account(id: "f-depot", connectionID: ConnectionMergeTests.fints.id, type: .depot, name: "Depot"),
        ]
        var snapshot = ConnectionMergeTests.snapshot(accounts: accounts, transactions: [])
        snapshot.record([
            DepotValuePoint(accountID: "w-depot", day: ConnectionMergeTests.day("2026-11-01"), valueCents: 100, purchaseCents: 90),
            DepotValuePoint(accountID: "w-depot", day: ConnectionMergeTests.day("2026-11-02"), valueCents: 110, purchaseCents: 90),
            DepotValuePoint(accountID: "f-depot", day: ConnectionMergeTests.day("2026-11-02"), valueCents: 111, purchaseCents: nil),
        ])
        let store = InMemoryLedgerStore(snapshot)
        let changes = ConnectionMerge.changes(try ConnectionMerge.plan(snapshot, source: ConnectionMergeTests.web.id, target: ConnectionMergeTests.fints.id), in: snapshot)
        #expect(changes.depotValues.map(\.day) == [ConnectionMergeTests.day("2026-11-01")])
        try await store.applyMerge(changes)
        let history = await store.snapshot().depotHistory
        #expect(history["w-depot"] == nil)
        // The target keeps its own point of the same day.
        #expect(history["f-depot"]?.map(\.valueCents) == [100, 111])
    }

    @Test func categoryForAVanishedTargetRowIsSkipped() async throws {
        let snapshot = Self.ledger()
        let changes = ConnectionMerge.changes(try ConnectionMerge.plan(snapshot, source: T.web.id, target: T.fints.id), in: snapshot)
        var moved = snapshot
        let twin = try #require(snapshot.transactions.first { $0.counterpartName == "MUSTERLADEN" })
        moved.transactions.removeAll { $0.id == twin.id }
        let store = InMemoryLedgerStore(moved)
        try await store.applyMerge(changes)
        #expect(await store.snapshot().transactions.contains { $0.id == twin.id } == false)
    }
}

extension ConnectionMergeTests {
    @Test func newMarkPassesToTheTargetTwin() throws {
        let w: AccountID = "w-giro"
        let f: AccountID = "f-giro"
        let accounts = [
            Account(id: w, connectionID: Self.web.id, iban: "DE02120300000000202051", type: .giro, name: "Giro"),
            Account(id: f, connectionID: Self.fints.id, iban: "DE02120300000000202051", type: .giro, name: "Giro"),
        ]
        let source = Self.booking(w, "2026-10-10", 250_000, "Arbeitgeber AG", iban: "DE89370400440532013000")
        let target = Self.booking(f, "2026-10-10", 250_000, "Lohn/Gehalt", iban: "DE89370400440532013000")
        var snapshot = Self.snapshot(accounts: accounts, transactions: [source, target])
        snapshot.newTransactionIDs = [source.id]
        let changes = ConnectionMerge.changes(try ConnectionMerge.plan(snapshot, source: Self.web.id, target: Self.fints.id), in: snapshot)
        #expect(changes.newMarks == [target.id])
        snapshot.applyMerge(changes)
        #expect(snapshot.newTransactionIDs == [target.id])
    }
}
