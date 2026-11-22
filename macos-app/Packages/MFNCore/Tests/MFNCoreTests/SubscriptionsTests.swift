import Foundation
import Testing
@testable import MFNCore

private func day(_ iso: String) -> BankDay { BankDay(iso: iso)! }

private func booking(_ iso: String, _ cents: Int, _ name: String, account: AccountID = "giro",
                     status: TransactionStatus = .booked, category: CategoryID? = nil) -> Transaction {
    Transaction(accountID: account, bookingDate: status == .booked ? day(iso) : nil, valueDate: day(iso), amountCents: cents,
                counterpartName: name, purpose: "Lastschrift \(iso)", status: status, categoryID: category)
}

/// One booking per step of `months`, the newest on `last`.
private func series(_ name: String, cents: [Int], last: String, months: Int = 1, account: AccountID = "giro") -> [Transaction] {
    cents.reversed().enumerated().map { offset, amount in
        booking(day(last).adding(months: -offset * months).description, amount, name, account: account)
    }
}

private let today = day("2026-11-22")

@Suite struct SubscriptionsTests {
    @Test func monthlySubscription() throws {
        let found = Subscriptions.detect(transactions: series("Musikdienst GmbH", cents: [-999, -999, -999, -999], last: "2026-11-05"), today: today)
        let music = try #require(found.first)
        #expect(found.count == 1)
        #expect(music.cadence == .monthly)
        #expect(music.cents == -999)
        #expect(music.count == 4)
        #expect(music.last == day("2026-11-05"))
        #expect(music.next == day("2026-12-05"))
        #expect(music.yearlyCents == -11_988)
        #expect(music.monthlyCents == -999)
        #expect(!music.isEnded)
        #expect(music.priceChange == nil)
        #expect(music.title == "Musikdienst GmbH")
    }

    @Test func twoMonthlyBookingsAreNotEnough() {
        #expect(Subscriptions.detect(transactions: series("Neu AG", cents: [-500, -500], last: "2026-11-05"), today: today).isEmpty)
    }

    @Test func quarterlyAndYearly() throws {
        let transactions = series("Rundfunk", cents: [-5_508, -5_508, -5_508], last: "2026-11-15", months: 3)
            + series("Haftpflicht", cents: [-8_400, -8_640], last: "2026-10-01", months: 12)
        let found = Subscriptions.detect(transactions: transactions, today: today)
        let fee = try #require(found.first { $0.title == "Rundfunk" })
        #expect(fee.cadence == .quarterly)
        #expect(fee.yearlyCents == -22_032)
        #expect(fee.monthlyCents == -1_836)
        #expect(fee.next == day("2027-02-15"))
        let insurance = try #require(found.first { $0.title == "Haftpflicht" })
        #expect(insurance.cadence == .yearly)
        #expect(insurance.cents == -8_640)
        #expect(insurance.monthlyCents == -720)
        #expect(insurance.next == day("2027-10-01"))
        // A yearly price is not "one fixed price, then another" with a single booking before.
        #expect(insurance.priceChange == nil)
    }

    @Test func priceChangeKeepsTheSeries() throws {
        let found = Subscriptions.detect(transactions: series("Streaming", cents: [-1_299, -1_299, -1_299, -1_799, -1_799], last: "2026-11-10"), today: today)
        let streaming = try #require(found.first)
        #expect(found.count == 1)
        #expect(streaming.cents == -1_799)
        #expect(streaming.count == 5)
        #expect(streaming.priceChange == RecurringPayment.PriceChange(previousCents: -1_299, since: day("2026-10-10")))
    }

    @Test func oldPriceChangeIsNoLongerPointedOut() throws {
        let found = Subscriptions.detect(transactions: series("Streaming", cents: [-1_299, -1_299, -1_799, -1_799, -1_799, -1_799, -1_799, -1_799], last: "2026-11-10"), today: today)
        #expect(try #require(found.first).priceChange == nil)
    }

    @Test func variableBillCountsWithoutPriceChange() throws {
        let found = Subscriptions.detect(transactions: series("Stadtwerke", cents: [-8_100, -7_900, -8_650, -8_200], last: "2026-11-01"), today: today)
        let power = try #require(found.first)
        #expect(power.cents == -8_200)
        #expect(power.priceChange == nil)
    }

    @Test func shopsAreNotSubscriptions() {
        // Weekly groceries, and a shop that happens to be visited once a month with very different sums.
        var transactions = (0..<12).map { booking(today.adding(days: -$0 * 7).description, -4_000 - $0 * 150, "Supermarkt") }
        transactions += series("Baumarkt", cents: [-1_200, -9_800, -3_100, -45_000], last: "2026-11-03")
        #expect(Subscriptions.detect(transactions: transactions, today: today).isEmpty)
    }

    @Test func twoContractsWithOneCompany() {
        let transactions = series("Versicherung AG", cents: [-2_500, -2_500, -2_500], last: "2026-11-01")
            + series("Versicherung AG", cents: [-4_100, -4_100, -4_100], last: "2026-11-15")
        let found = Subscriptions.detect(transactions: transactions, today: today)
        #expect(found.map(\.cents) == [-4_100, -2_500])
        #expect(Set(found.map(\.id)).count == 2)
    }

    @Test func endedSeriesIsMarkedThenDropped() throws {
        let transactions = series("Fitnessstudio", cents: [-2_990, -2_990, -2_990, -2_990], last: "2026-09-01")
        let ended = try #require(Subscriptions.detect(transactions: transactions, today: today).first)
        #expect(ended.isEnded)
        #expect(ended.next == day("2026-10-01"))
        // A few days late is not ended.
        #expect(try #require(Subscriptions.detect(transactions: transactions, today: day("2026-10-08")).first).isEnded == false)
        #expect(Subscriptions.detect(transactions: transactions, today: day("2027-02-01")).isEmpty)
    }

    @Test func pausedContractCountsFromItsRestart() throws {
        let transactions = series("Zeitung", cents: [-1_500, -1_500, -1_500], last: "2026-03-01")
            + series("Zeitung", cents: [-1_500, -1_500, -1_500], last: "2026-11-01")
        let paper = try #require(Subscriptions.detect(transactions: transactions, today: today).first)
        #expect(paper.count == 3)
        #expect(paper.transactionIDs.count == 3)
    }

    @Test func incomeTransfersAndOtherAccounts() throws {
        let transactions = series("Arbeitgeber SE", cents: [320_000, 320_000, 325_000], last: "2026-10-28")
            + series("Eigenes Tagesgeld", cents: [-50_000, -50_000, -50_000], last: "2026-11-02").map {
                var copy = $0
                copy.categoryID = "umbuchung"
                return copy
            }
            + series("Musikdienst", cents: [-999, -999, -999], last: "2026-11-05", account: "karte")
            + [booking("2026-11-20", -999, "Vorgemerkt GmbH", status: .pending)]
        let found = Subscriptions.detect(transactions: transactions, today: today)
        #expect(found.map(\.title) == ["Musikdienst", "Arbeitgeber SE"])
        let salary = try #require(found.last)
        #expect(salary.isIncome)
        #expect(salary.accountID == "giro")
        #expect(found.first?.accountID == "karte")
    }

    @Test func transfersBetweenOwnAccountsAreLeftOutWithoutCategory() {
        // Standing order giro → savings, booked a day later there; nothing is categorized yet.
        let out = series("Eigenes Tagesgeld", cents: [-30_000, -30_000, -30_000, -30_000], last: "2026-11-02")
        let arriving = out.map { booking($0.effectiveDate.adding(days: 1).description, 30_000, "Eigenes Girokonto", account: "tagesgeld") }
        let rent = series("Hausverwaltung", cents: [-95_000, -95_000, -95_000], last: "2026-11-01")
        let found = Subscriptions.detect(transactions: out + arriving + rent, today: today)
        #expect(found.map(\.title) == ["Hausverwaltung"])
        // Without the other account in MFN it is a payment like any other.
        #expect(Subscriptions.detect(transactions: out + rent, today: today).map(\.title) == ["Hausverwaltung", "Eigenes Tagesgeld"])

        // One half only, but the counterpart IBAN is one of the user's accounts.
        let toOwn = out.map {
            Transaction(accountID: $0.accountID, bookingDate: $0.bookingDate, valueDate: $0.valueDate, amountCents: $0.amountCents,
                        counterpartName: $0.counterpartName, counterpartIBAN: "de00 1111 2222 3333 4444 55", purpose: $0.purpose, status: .booked)
        }
        #expect(Subscriptions.detect(transactions: toOwn + rent, ownIBANs: ["DE00111122223333444455"], today: today).map(\.title) == ["Hausverwaltung"])
        #expect(Subscriptions.detect(transactions: toOwn + rent, ownIBANs: ["DE00999999999999999999"], today: today).count == 2)
    }

    @Test func orderIsExpensesByMonthlyAmountThenIncomeThenEnded() {
        let transactions = series("Klein", cents: [-500, -500, -500], last: "2026-11-01")
            + series("Jahr", cents: [-24_000, -24_000], last: "2026-06-01", months: 12)
            + series("Gehalt", cents: [100_000, 100_000, 100_000], last: "2026-11-01")
            + series("Vorbei", cents: [-9_000, -9_000, -9_000], last: "2026-08-20")
        #expect(Subscriptions.detect(transactions: transactions, today: today).map(\.title) == ["Jahr", "Klein", "Gehalt", "Vorbei"])
    }
}

@Suite struct RecurringEntryTests {
    private let music = series("Musikdienst GmbH", cents: [-999, -999, -999, -999], last: "2026-11-05")

    @Test func changedPaymentCarriesTheUsersValuesAndRemembersTheDetectedOnes() throws {
        let detected = Subscriptions.detect(transactions: music, today: today)
        let id = try #require(detected.first?.id)
        let entry = RecurringEntry(seriesID: id, accountID: "giro", title: "Musik", amountCents: -1_299, cadence: .monthly)
        let changed = try #require(Subscriptions.applying([entry], to: detected, today: today).first)
        #expect(changed.id == id, "hiding and the list keep following the same payment")
        #expect(changed.title == "Musik")
        #expect(changed.cents == -1_299)
        #expect(changed.isEdited && !changed.isOwn)
        #expect(changed.entryID == entry.id)
        #expect(changed.detected == RecurringPayment.Detected(title: "Musikdienst GmbH", cents: -999, cadence: .monthly))
        #expect(changed.next == day("2026-12-05"))
        // Without the entry everything is as detected again.
        #expect(Subscriptions.applying([], to: detected, today: today) == detected)
    }

    @Test func changedRhythmMovesTheNextDate() throws {
        let detected = Subscriptions.detect(transactions: music, today: today)
        let entry = RecurringEntry(seriesID: detected[0].id, accountID: "giro", title: "Musikdienst GmbH", amountCents: -999, cadence: .yearly)
        let changed = try #require(Subscriptions.applying([entry], to: detected, today: today).first)
        #expect(changed.cadence == .yearly)
        #expect(changed.next == day("2027-11-05"))
        #expect(changed.yearlyCents == -999)
        #expect(!changed.isEnded)
    }

    @Test func ownEntryIsListedWithItsNextDate() throws {
        let rent = RecurringEntry(accountID: "giro", title: "Miete bar", amountCents: -80_000, cadence: .monthly, anchorDay: day("2026-01-31"))
        let pay = RecurringEntry(accountID: "giro", title: "Nebenjob", amountCents: 45_000, cadence: .quarterly, anchorDay: day("2027-02-15"))
        let all = Subscriptions.applying([rent, pay], to: Subscriptions.detect(transactions: music, today: today), today: today)
        #expect(all.map(\.title) == ["Miete bar", "Musikdienst GmbH", "Nebenjob"], "expenses by size, then income")
        let own = try #require(all.first)
        #expect(own.isOwn && !own.isEdited && !own.isEnded)
        #expect(own.id == "own:\(rent.id.uuidString)")
        #expect(own.next == day("2026-11-30"), "the 31st, where the month has one")
        #expect(own.transactionIDs.isEmpty)
        // An anchor in the future counts back in its rhythm.
        #expect(all[2].next == day("2027-02-15"))
    }

    @Test func nextDayInRhythm() {
        #expect(Subscriptions.nextDay(from: day("2026-11-22"), every: .monthly, today: today) == today)
        #expect(Subscriptions.nextDay(from: day("2026-11-21"), every: .monthly, today: today) == day("2026-12-21"))
        #expect(Subscriptions.nextDay(from: day("2024-03-10"), every: .yearly, today: today) == day("2027-03-10"))
        #expect(Subscriptions.nextDay(from: day("2028-06-01"), every: .halfYearly, today: today) == day("2026-12-01"))
        #expect(Subscriptions.nextDay(from: day("2026-01-31"), every: .monthly, today: day("2027-03-01")) == day("2027-03-31"))
    }

    @Test func changeOfAVanishedPaymentDoesNothing() {
        let entry = RecurringEntry(seriesID: "gone", accountID: "giro", title: "Alt", amountCents: -100, cadence: .monthly)
        #expect(Subscriptions.applying([entry], to: [], today: today).isEmpty)
    }
}
