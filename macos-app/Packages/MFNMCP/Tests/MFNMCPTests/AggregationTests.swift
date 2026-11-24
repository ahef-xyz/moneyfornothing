import Foundation
import MFNCore
import Testing
@testable import MFNMCP

private func day(_ d: Int, month: Int = 10) -> BankDay { BankDay(year: 2026, month: month, day: d)! }

private func tx(_ cents: Int, day d: BankDay, category: CategoryID? = nil, status: TransactionStatus = .booked,
                account: AccountID = "a1", currency: String = "EUR", name: String = "Laden") -> Transaction {
    Transaction(accountID: account, bookingDate: d, valueDate: d, amountCents: cents, currency: currency,
                counterpartName: name, purpose: "Kauf \(cents) \(d.iso)", status: status, categoryID: category,
                categorySource: category == nil ? nil : .manual, confidence: category == nil ? nil : 1)
}

@Suite struct AggregationTests {
    let october = DayPeriod(from: day(1), to: day(31))!

    @Test func sumsCountBookedAndPendingButNeverPlannedOrCancelled() {
        let rows = [
            tx(-1_000, day: day(2), category: "lebensmittel"),
            tx(-250, day: day(3), category: "lebensmittel", status: .pending),
            tx(-9_999, day: day(4), category: "lebensmittel", status: .planned),
            tx(-7_777, day: day(5), category: "lebensmittel", status: .cancelled),
            tx(-500, day: day(6)),
            tx(-123, day: day(1, month: 11), category: "lebensmittel"),
        ]
        let sums = Aggregations.sumByCategory(rows, in: october)
        #expect(sums.first { $0.categoryID == "lebensmittel" }?.cents == -1_250)
        #expect(sums.first { $0.categoryID == "lebensmittel" }?.count == 2)
        #expect(sums.first { $0.categoryID == nil }?.cents == -500)
        let bookedOnly = Aggregations.sumByCategory(rows, in: october, includePending: false)
        #expect(bookedOnly.first { $0.categoryID == "lebensmittel" }?.cents == -1_000)
    }

    @Test func periodEndsAreIncluded() {
        let rows = [tx(-100, day: day(1)), tx(-200, day: day(31)), tx(-400, day: day(30, month: 9)), tx(-800, day: day(1, month: 11))]
        #expect(Aggregations.sumByCategory(rows, in: october).map(\.cents) == [-300])
    }

    @Test func currenciesAreNeverAddedUp() {
        let rows = [tx(-100, day: day(2)), tx(-200, day: day(3), currency: "USD")]
        let sums = Aggregations.sumByCategory(rows, in: october)
        #expect(Set(sums.map(\.currency)) == ["EUR", "USD"])
    }

    @Test func perMonthAndDirection() {
        let period = DayPeriod(from: day(1, month: 9), to: day(31))!
        let rows = [tx(-100, day: day(2, month: 9), category: "abos"), tx(-100, day: day(2), category: "abos"), tx(5_000, day: day(3), category: "gehalt")]
        let sums = Aggregations.sumByCategory(rows, in: period, byMonth: true, direction: .spending)
        #expect(sums.map(\.month) == ["2026-09", "2026-10"])
        #expect(sums.allSatisfy { $0.cents == -100 })
    }

    @Test func comparisonDifferenceIsSecondMinusFirst() {
        let september = DayPeriod(from: day(1, month: 9), to: day(30, month: 9))!
        let rows = [tx(-1_000, day: day(5, month: 9), category: "restaurant"), tx(-4_000, day: day(5), category: "restaurant"), tx(-300, day: day(6), category: "abos")]
        let comparison = Aggregations.compare(rows, first: september, second: october)
        #expect(comparison.first?.categoryID == "restaurant")
        #expect(comparison.first?.differenceCents == -3_000)
        #expect(comparison.first { $0.categoryID == "abos" }?.firstCents == 0)
    }

    @Test func cashFlowLeavesOutOwnTransfersAndShowsEmptyMonths() {
        let accounts = [Account(id: "a1", connectionID: "c1", type: .giro, name: "Giro"), Account(id: "card", connectionID: "c1", type: .card, name: "Visa"),
                        Account(id: "a2", connectionID: "c1", iban: "DE00111122223333", type: .tagesgeld, name: "Tagesgeld")]
        let period = DayPeriod(from: day(1, month: 9), to: day(31))!
        let rows = [
            tx(300_000, day: day(1), category: "gehalt"),
            tx(-50_000, day: day(2), category: "umbuchung"),
            Transaction(accountID: "a1", bookingDate: day(2), valueDate: day(2), amountCents: -150_000, counterpartName: "Eigenes Konto",
                        counterpartIBAN: "de00 1111 2222 3333", purpose: "Übertrag", status: .booked),
            tx(-20_000, day: day(3), category: "kredit", name: "Kreditkartenabrechnung"),
            tx(-8_000, day: day(4), category: "lebensmittel"),
        ]
        let flows = Aggregations.cashFlow(rows, accounts: accounts, in: period)
        #expect(flows.map(\.month) == ["2026-09", "2026-10"])
        #expect(flows[0].netCents == 0)
        #expect(flows[1].incomeCents == 300_000)
        #expect(flows[1].spendingCents == 8_000)
        #expect(flows[1].transfersLeftOut == 3, "also the uncategorized transfer to an own IBAN")
    }

    @Test func balanceOnWalksBackFromToday() {
        let balance = Balance(bookedCents: 10_000, asOf: Date())
        let rows = [tx(-2_000, day: day(20)), tx(500, day: day(10)), tx(-999, day: day(25), status: .pending)]
        #expect(Aggregations.balance(on: day(15), current: balance, transactions: rows) == 12_000)
        #expect(Aggregations.balance(on: day(5), current: balance, transactions: rows) == 11_500)
        #expect(Aggregations.balance(on: day(5), current: balance, transactions: [tx(-1, day: day(9), currency: "USD")]) == nil)
    }

    @Test func moneyIsDecimalText() {
        #expect(Money.decimal(-41_237) == "-412.37")
        #expect(Money.decimal(5) == "0.05")
        #expect(Money.decimal(-5) == "-0.05")
        #expect(Money.decimal(100) == "1.00")
        #expect(Money.cents("12.5") == 1_250)
        #expect(Money.cents("-3") == -300)
        #expect(Money.cents("4,99") == 499)
        #expect(Money.cents(.number(0.1)) == 10)
        #expect(Money.cents("1.234") == nil)
        #expect(Money.cents("abc") == nil)
        #expect(Money.cents("12.50 EUR") == nil)
        #expect(Money.cents("12abc") == nil)
        #expect(Money.cents("1.000") == nil, "a thousands separator is not two decimals")
    }
}

@Suite struct OwnTransferSumTests {
    @Test func uncategorizedTransfersToOwnAccountsJoinTheTransferRow() {
        let d = BankDay(year: 2026, month: 11, day: 3)!
        let period = DayPeriod(from: BankDay(year: 2026, month: 11, day: 1)!, to: BankDay(year: 2026, month: 11, day: 30)!)!
        let rows = [
            Transaction(accountID: "a1", bookingDate: d, valueDate: d, amountCents: -150_000, counterpartName: "Ich", counterpartIBAN: "DE00 1111 2222 3333", purpose: "Übertrag", status: .booked),
            Transaction(accountID: "a1", bookingDate: d, valueDate: d, amountCents: -2_000, counterpartName: "Laden", purpose: "Kauf", status: .booked),
        ]
        let sums = Aggregations.sumByCategory(rows + [Transaction(accountID: "a1", bookingDate: d, valueDate: d, amountCents: -500, counterpartName: "Ich",
                                                                  purpose: "Sparen", status: .booked, categoryID: "umbuchung", categorySource: .manual, confidence: 1)],
                                              in: period, ownIBANs: ["DE00111122223333"])
        #expect(sums.count == 2)
        let transfers = sums.first { $0.categoryID == "umbuchung" }
        #expect(transfers?.cents == -150_500)
        #expect(transfers?.count == 2)
        #expect(transfers?.uncategorizedTransfers == 1)
        #expect(sums.first { $0.categoryID == nil }?.cents == -2_000)
    }
}
