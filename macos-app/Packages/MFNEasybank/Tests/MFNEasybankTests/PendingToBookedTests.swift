import Foundation
import MFNCore
import Testing
@testable import MFNEasybank

private func day(_ y: Int, _ m: Int, _ d: Int) -> BankDay {
    BankDay(year: y, month: m, day: d) ?? BankDay(Date(timeIntervalSince1970: 0))
}

@Suite struct EasybankPendingToBookedTests {
    let account: AccountID = "easybank:test:card:1234"

    func make(_ status: TransactionStatus, booking: BankDay?, on date: BankDay, cents: Int, merchant: String, original: (Int, String)? = nil) -> Transaction {
        EasybankTransactionBuilder.make(.init(
            accountID: account, status: status, bookingDate: booking, transactionDate: date,
            amountCents: cents, currency: "EUR", merchant: merchant, details: nil,
            originalAmountCents: original?.0, originalCurrency: original?.1, externalID: nil, rawJSON: Data("{}".utf8)
        ))
    }

    @Test func pendingNeverCarriesBookingDate() {
        let t = make(.pending, booking: day(2026, 11, 5), on: day(2026, 11, 4), cents: -100, merchant: "M")
        #expect(t.bookingDate == nil)
        #expect(make(.booked, booking: nil, on: day(2026, 11, 4), cents: -100, merchant: "M").bookingDate == day(2026, 11, 4))
    }

    @Test func foreignCurrencyBookingReplacesReservation() {
        // Reserved at one rate, booked two days later at another (+1.5 %), merchant text longer.
        let pending = make(.pending, booking: nil, on: day(2026, 11, 1), cents: -2000, merchant: "Merchant Beta", original: (2190, "USD"))
        let booked = make(.booked, booking: day(2026, 11, 3), on: day(2026, 11, 1), cents: -2030, merchant: "MERCHANT BETA SAN FRANCISCO", original: (2190, "USD"))
        let merge = TransactionMerger.merge(stored: [pending], incoming: [booked], since: nil)
        #expect(merge.resolved[pending.id] == booked.id)
        #expect(merge.deletions == [pending.id])
        #expect(merge.upserts.map(\.id) == [booked.id])
    }

    @Test func euroAmountMismatchIsNotMerged() {
        let pending = make(.pending, booking: nil, on: day(2026, 11, 1), cents: -2000, merchant: "Merchant")
        let booked = make(.booked, booking: day(2026, 11, 2), on: day(2026, 11, 1), cents: -2030, merchant: "Merchant")
        #expect(!TransactionMerger.matches(pending: pending, booked: booked))
    }

    @Test func sinceKeepsPending() {
        let old = make(.booked, booking: day(2026, 10, 1), on: day(2026, 10, 1), cents: -1, merchant: "A")
        let newer = make(.booked, booking: day(2026, 11, 2), on: day(2026, 11, 1), cents: -2, merchant: "B")
        let pending = make(.pending, booking: nil, on: day(2026, 9, 30), cents: -3, merchant: "C")
        let kept = EasybankTransactionBuilder.filter([old, newer, pending], since: day(2026, 11, 1).startDate)
        #expect(kept.map(\.counterpartName) == ["B", "C"])
    }
}
