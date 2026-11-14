import Foundation
import Testing
@testable import MFNCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> BankDay { BankDay(year: y, month: m, day: day)! }

private func tx(_ name: String, _ cents: Int, _ day: BankDay, status: TransactionStatus = .booked, category: CategoryID? = nil, account: AccountID = "giro") -> Transaction {
    Transaction(accountID: account, bookingDate: status == .booked ? day : nil, valueDate: day, amountCents: cents, counterpartName: name, purpose: "\(name) \(day.iso) \(cents)", status: status, categoryID: category, categorySource: category == nil ? nil : .manual)
}

@Suite struct BudgetPeriodTests {
    @Test func monthlyWithStartDay() {
        let budget = AccountBudget(accountID: "giro", amountCents: 1, period: .monthly, startDay: 25)
        #expect(budget.range(containing: d(2026, 11, 10)) == d(2026, 10, 25)...d(2026, 11, 24))
        #expect(budget.range(containing: d(2026, 11, 25)).lowerBound == d(2026, 11, 25))
        #expect(budget.range(containing: d(2026, 1, 3)).lowerBound == d(2025, 12, 25))
        #expect(AccountBudget(accountID: "g", amountCents: 1).range(containing: d(2026, 2, 14)) == d(2026, 2, 1)...d(2026, 2, 28))
    }

    @Test func weeklyQuarterlyYearly() {
        // 2026-11-10 is a Tuesday.
        #expect(AccountBudget(accountID: "g", amountCents: 1, period: .weekly, startDay: 1).range(containing: d(2026, 11, 10)) == d(2026, 11, 9)...d(2026, 11, 15))
        #expect(AccountBudget(accountID: "g", amountCents: 1, period: .quarterly).range(containing: d(2026, 11, 10)) == d(2026, 10, 1)...d(2026, 12, 31))
        #expect(AccountBudget(accountID: "g", amountCents: 1, period: .yearly).range(containing: d(2026, 11, 10)) == d(2026, 1, 1)...d(2026, 12, 31))
        let previous = AccountBudget(accountID: "g", amountCents: 1).previousRanges(before: d(2026, 11, 10), count: 2)
        #expect(previous == [d(2026, 10, 1)...d(2026, 10, 31), d(2026, 9, 1)...d(2026, 9, 30)])
    }
}

@Suite struct BudgetForecastTests {
    let today = d(2026, 11, 10)
    let budget = AccountBudget(accountID: "giro", amountCents: 200_000)

    /// Three earlier months with rent 900 €, streaming 13 €, groceries 300 €/month.
    private var history: [Transaction] {
        var list: [Transaction] = []
        for month in [8, 9, 10] {
            list.append(tx("Hausverwaltung", -90_000, d(2026, month, 3)))
            list.append(tx("Streamingdienst", -1_299, d(2026, month, 15)))
            for week in 0..<3 { list.append(tx("Markt \(month)-\(week)", -10_000, d(2026, month, 5 + week * 7))) }
        }
        return list
    }

    @Test func spentRefundsTransfersAndForecast() {
        let current = [
            tx("Hausverwaltung", -90_000, d(2026, 11, 3)),
            tx("Markt", -12_000, d(2026, 11, 6)),
            tx("Markt", -2_000, d(2026, 11, 9), status: .pending),
            tx("Shop", 3_000, d(2026, 11, 8), category: "erstattung"),
            tx("Tagesgeld", -50_000, d(2026, 11, 7), category: "umbuchung"),
            tx("Versicherung", -8_000, d(2026, 11, 20), status: .planned),
            tx("Fremd", -99_999, d(2026, 11, 5), account: "other"),
        ]
        let status = BudgetForecast.status(for: budget, transactions: history + current, today: today)
        #expect(status.spentCents == 90_000 + 12_000 + 2_000 - 3_000)
        #expect(status.plannedCents == 8_000)
        #expect(status.expectedRecurringCents == 1_299, "streaming not yet this month; rent already booked")
        // Variable: groceries 600 € over Sep + Oct (August counts as incomplete: data starts 3 Aug),
        // 61 days → ~9,84 €/day × 20 days left.
        #expect(status.daysLeft == 20)
        #expect(abs(status.expectedVariableCents - 19_672) <= 5, "got \(status.expectedVariableCents)")
        #expect(status.state == .onTrack)
        #expect(status.perDayCents == (200_000 - 101_000 - 8_000 - 1_299) / 20)
    }

    @Test func states() {
        let small = AccountBudget(accountID: "giro", amountCents: 100_000)
        let atRisk = BudgetForecast.status(for: small, transactions: history + [tx("Hausverwaltung", -90_000, d(2026, 11, 3))], today: today)
        #expect(atRisk.state == .atRisk)
        let over = BudgetForecast.status(for: small, transactions: [tx("Auto", -120_000, d(2026, 11, 2))], today: today)
        #expect(over.state == .exceeded)
        #expect(over.perDayCents == 0)
    }

    @Test func noHistoryUsesCurrentPace() {
        let status = BudgetForecast.status(for: budget, transactions: [tx("Markt", -10_000, d(2026, 11, 5))], today: today)
        // 100 € in 10 days → 10 €/day × 20 days.
        #expect(status.expectedVariableCents == 20_000)
    }

    /// Last sync 3 days ago: those 3 days are forecast too, planned payments since then count.
    @Test func forecastStartsAtTheLastSync() {
        let current = [tx("Markt", -10_000, d(2026, 11, 5)), tx("Versicherung", -8_000, d(2026, 11, 9), status: .planned)]
        let fresh = BudgetForecast.status(for: budget, transactions: current, today: today)
        let stale = BudgetForecast.status(for: budget, transactions: current, today: today, dataAsOf: d(2026, 11, 7))
        // No history: pace = 100 € / days covered. Fresh: 10 days covered, 20 to forecast.
        #expect(fresh.expectedVariableCents == 20_000)
        #expect(fresh.plannedCents == 0, "planned on the 9th is in the past and not booked")
        // Stale: 7 days covered (100 €/7 per day), 23 days to forecast; the 9th is after the data.
        #expect(stale.expectedVariableCents == Int((10_000.0 / 7 * 23).rounded()))
        #expect(stale.plannedCents == 8_000)
        #expect(stale.daysLeft == 20, "per-day amount still counts from today")
        #expect(stale.dataAsOf == d(2026, 11, 7))
        // Data date is clamped to today.
        #expect(BudgetForecast.status(for: budget, transactions: current, today: today, dataAsOf: d(2026, 12, 1)).dataAsOf == today)
    }
}

@Suite struct BudgetAnchorTests {
    private func salary(_ day: BankDay, _ cents: Int = 250_000, from name: String = "Arbeitgeber GmbH") -> Transaction {
        tx(name, cents, day)
    }

    @Test func earlyAndLateSalaryMoveThePeriod() {
        let budget = AccountBudget(accountID: "giro", amountCents: 200_000, anchor: .init(toleranceDays: 3))
        let deposits = [salary(d(2026, 9, 30)), salary(d(2026, 11, 2))]
        // October starts with the salary on 30 Sep, November with the late one on 2 Nov.
        #expect(budget.range(containing: d(2026, 10, 15), transactions: deposits) == d(2026, 9, 30)...d(2026, 11, 1))
        #expect(budget.range(containing: d(2026, 11, 1), transactions: deposits) == d(2026, 9, 30)...d(2026, 11, 1), "1 Nov still last month's money")
        #expect(budget.range(containing: d(2026, 11, 2), transactions: deposits).lowerBound == d(2026, 11, 2))
        // No deposit in the window: the fixed day applies.
        #expect(budget.range(containing: d(2026, 12, 10), transactions: deposits).lowerBound == d(2026, 12, 1))
    }

    @Test func smallDepositsAndOtherCounterpartsDoNotCount() {
        let auto = AccountBudget(accountID: "giro", amountCents: 200_000, anchor: .init(toleranceDays: 3))
        let refund = tx("Shop", 4_000, d(2026, 10, 30))
        #expect(auto.range(containing: d(2026, 11, 10), transactions: [refund]).lowerBound == d(2026, 11, 1), "below 25 % of the budget")
        let byName = AccountBudget(accountID: "giro", amountCents: 200_000, anchor: .init(toleranceDays: 3, counterpart: "arbeitgeber"))
        let transfer = tx("Tagesgeld", 300_000, d(2026, 10, 29))
        let pay = salary(d(2026, 10, 31))
        #expect(byName.range(containing: d(2026, 11, 10), transactions: [transfer, pay]).lowerBound == d(2026, 10, 31))
        #expect(auto.range(containing: d(2026, 11, 10), transactions: [transfer, pay]).lowerBound == d(2026, 10, 29), "automatic: the largest")
        let other = tx("Fremd", 500_000, d(2026, 10, 31), account: "other")
        #expect(auto.range(containing: d(2026, 11, 10), transactions: [other]).lowerBound == d(2026, 11, 1), "only this account")
    }

    @Test func historyAndSpendingFollowTheAnchor() {
        let budget = AccountBudget(accountID: "giro", amountCents: 200_000, anchor: .init(toleranceDays: 3))
        let list = [salary(d(2026, 10, 30)), tx("Markt", -5_000, d(2026, 10, 31)), tx("Markt", -7_000, d(2026, 11, 4))]
        let status = BudgetForecast.status(for: budget, transactions: list, today: d(2026, 11, 10))
        #expect(status.range.lowerBound == d(2026, 10, 30))
        #expect(status.spentCents == 12_000, "the 31 Oct purchase belongs to the new period")
        let previous = budget.previousRanges(before: d(2026, 11, 10), count: 1, transactions: list)
        #expect(previous.first?.upperBound == d(2026, 10, 29))
    }

    @Test func weeklyToleranceIsCapped() {
        #expect(AccountBudget(accountID: "g", amountCents: 1, period: .weekly, anchor: .init(toleranceDays: 7)).anchor?.toleranceDays == 3)
    }
}
