import Foundation
import Testing
@testable import MFNCore

private func day(_ iso: String) -> BankDay { BankDay(iso: iso) ?? .today }

private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

private func booked(_ cents: Int, on iso: String, status: TransactionStatus = .booked, currency: String = "EUR") -> Transaction {
    Transaction(accountID: "manual:A", bookingDate: status == .booked ? day(iso) : nil, valueDate: day(iso), amountCents: cents,
                currency: currency, counterpartName: "Muster", purpose: "Test \(cents) \(iso)", status: status)
}

@Suite struct ManualConnectorIDTests {
    @Test func roundTripsAndKeepsOlderValuesDecodable() throws {
        let encoded = try JSONEncoder().encode([ConnectorID.manual, .ing, .mock])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["manual","ing","mock"]"#)
        #expect(try JSONDecoder().decode([ConnectorID].self, from: encoded) == [.manual, .ing, .mock])
        // v9 data (every case before v10) still decodes unchanged.
        let v9 = #"["ing","dkb","tradeRepublic","c24","easybank","n26","mock"]"#
        #expect(try JSONDecoder().decode([ConnectorID].self, from: Data(v9.utf8)).count == 7)
        let connection = Connection(id: "manual:X", connectorID: .manual, displayName: "Sparbuch")
        #expect(try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection)) == connection)
    }

    @Test func manualHasNoCredentialsSetupOrConnector() {
        #expect(!ConnectorID.manual.displayName.isEmpty)
        #expect(ConnectorID.manual.credentialFields.isEmpty)
        #expect(!ConnectorID.manual.supportsSetup)
        #expect(!ConnectorID.manual.hasConnector)
        #expect(ConnectorID.allCases.filter { !$0.hasConnector } == [.manual])
        #expect(Connection(id: "manual:X", connectorID: .manual, displayName: "").isManual)
    }

    @Test func newIDsShareTheUUIDAndArePrefixed() {
        let ids = ManualAccount.newIDs()
        #expect(ids.connection.rawValue.hasPrefix("manual:"))
        #expect(ids.connection.rawValue == ids.account.rawValue)
        #expect(ManualAccount.newIDs().account != ids.account)
    }
}

@Suite struct ManualBalanceTests {
    @Test func openingBalancePlusBookedFromTheOpeningDay() {
        let transactions = [
            booked(-1_000, on: "2026-01-31"),          // before the opening day: already in it
            booked(250_000, on: "2026-02-01"),         // on the day: counts
            booked(-12_345, on: "2026-02-10"),
            booked(-5_000, on: "2026-02-11", status: .pending),
            booked(-7_000, on: "2026-02-12", status: .cancelled),
            booked(-9_900, on: "2026-02-13", currency: "USD"),
        ]
        let balance = ManualAccount.balance(opening: OpeningBalance(cents: 123_456, day: day("2026-02-01")),
                                            transactions: transactions, currency: "EUR", asOf: asOf)
        #expect(balance == Balance(bookedCents: 123_456 + 250_000 - 12_345, availableCents: nil, currency: "EUR", asOf: asOf))
    }

    @Test func withoutDayEveryBookingCountsAndWithoutOpeningItStartsAtZero() {
        let transactions = [booked(-1_000, on: "2020-01-01"), booked(2_500, on: "2026-02-01")]
        #expect(ManualAccount.balance(opening: OpeningBalance(cents: -500), transactions: transactions, currency: "EUR", asOf: asOf).bookedCents == 1_000)
        #expect(ManualAccount.balance(opening: nil, transactions: transactions, currency: "EUR", asOf: asOf).bookedCents == 1_500)
        #expect(ManualAccount.balance(opening: nil, transactions: [], currency: "CHF", asOf: asOf) == Balance(bookedCents: 0, currency: "CHF", asOf: asOf))
    }

    @Test func hugeSumsSaturateInsteadOfTrapping() {
        let transactions = [booked(Int.max - 10, on: "2026-02-01"), booked(1_000, on: "2026-02-02")]
        #expect(ManualAccount.balance(opening: OpeningBalance(cents: 5), transactions: transactions, currency: "EUR", asOf: asOf).bookedCents == .max)
        let debits = [booked(Int.min + 10, on: "2026-02-01"), booked(-1_000, on: "2026-02-02")]
        #expect(ManualAccount.balance(opening: nil, transactions: debits, currency: "EUR", asOf: asOf).bookedCents == .min)
    }

    @Test func snapshotComputesOnlyForManualAccounts() {
        var snapshot = LedgerSnapshot()
        snapshot.connections = [Connection(id: "manual:A", connectorID: .manual, displayName: "Bar"),
                                Connection(id: "c-dkb", connectorID: .dkb, displayName: "DKB")]
        snapshot.accounts = [Account(id: "manual:A", connectionID: "manual:A", type: .giro, name: "Bar"),
                             Account(id: "a-dkb", connectionID: "c-dkb", type: .giro, name: "Giro")]
        snapshot.openingBalances["manual:A"] = OpeningBalance(cents: 10_000)
        snapshot.transactions = [booked(-2_500, on: "2026-02-01")]
        #expect(snapshot.computedManualBalance(of: "manual:A", asOf: asOf)?.bookedCents == 7_500)
        #expect(snapshot.computedManualBalance(of: "a-dkb", asOf: asOf) == nil)
        #expect(snapshot.computedManualBalance(of: "unknown", asOf: asOf) == nil)

        snapshot.removeConnection("manual:A")
        #expect(snapshot.openingBalances.isEmpty)
    }

    @Test func storeKeepsAndClearsTheOpeningBalance() async {
        let store = InMemoryLedgerStore()
        await store.setOpeningBalance(OpeningBalance(cents: 42, day: day("2026-03-01")), for: "manual:A")
        #expect(await store.snapshot().openingBalances["manual:A"] == OpeningBalance(cents: 42, day: day("2026-03-01")))
        await store.setOpeningBalance(nil, for: "manual:A")
        #expect(await store.snapshot().openingBalances.isEmpty)
    }
}

@Suite struct ManualIBANTests {
    @Test func normalizesAndAcceptsValidIBANs() {
        // Public sample IBAN (allowlisted in scripts/publish-public.ibans).
        #expect(ManualAccount.normalizedIBAN(" de89 3704 0044 0532 0130 00 ") == "DE89370400440532013000")
        #expect(ManualAccount.validate(iban: "DE89370400440532013000") == nil)
        #expect(ManualAccount.normalizedIBAN("   ") == nil)
    }

    @Test func rejectsBadInput() {
        #expect(ManualAccount.validate(iban: "DE00370400440532013000") == .wrongChecksum)
        #expect(ManualAccount.validate(iban: "DE8937040044053201300") == .wrongLength)
        #expect(ManualAccount.validate(iban: "DE89-3704-0044") == .invalidCharacters)
        #expect(ManualAccount.validate(iban: "1234") == .invalidCharacters)
        #expect(ManualAccount.validate(iban: "XX12") == .wrongLength)
        #expect(ManualAccount.validate(iban: "DE8937040044053201300Ä") == .invalidCharacters)
    }
}
