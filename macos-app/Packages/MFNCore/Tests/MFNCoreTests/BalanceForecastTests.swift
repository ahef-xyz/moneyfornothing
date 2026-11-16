import Foundation
import Testing
@testable import MFNCore

private func d(_ y: Int, _ m: Int, _ day: Int) -> BankDay { BankDay(year: y, month: m, day: day)! }

private func tx(_ name: String, _ cents: Int, _ day: BankDay, status: TransactionStatus = .booked) -> Transaction {
    Transaction(accountID: "giro", bookingDate: status == .booked ? day : nil, valueDate: day, amountCents: cents,
                counterpartName: name, purpose: "\(name) \(day.iso) \(cents)", status: status)
}

private func item(_ title: String, _ cents: Int, _ day: BankDay, created: BankDay, ignoring: Set<TransactionID> = []) -> PlannedItem {
    PlannedItem(accountID: "giro", day: day, amountCents: cents, title: title, createdAt: created.startDate.addingTimeInterval(12 * 3600), ignoredMatches: ignoring)
}

@Suite struct BalanceForecastTests {
    let today = d(2026, 11, 16)

    /// Salary on the 28th, rent on the 1st, two contracts with one insurer, weekly groceries.
    private var history: [Transaction] {
        var list: [Transaction] = []
        for month in [8, 9, 10] {
            list.append(tx("Muster Technik GmbH", 320_000 + month * 100, d(2026, month, 28)))
            list.append(tx("Versicherung AG", -2_000, d(2026, month, 5)))
            list.append(tx("Versicherung AG", -5_500, d(2026, month, 12)))
            for week in 0..<4 { list.append(tx("Markt", -6_000 - week * 100, d(2026, month, 2 + week * 7))) }
        }
        for month in [9, 10, 11] { list.append(tx("Hausverwaltung", -90_000, d(2026, month, 1))) }
        list.append(tx("Versicherung AG", -2_000, d(2026, 11, 5)))
        list.append(tx("Versicherung AG", -5_500, d(2026, 11, 12)))
        // Ended in August: not recurring anymore.
        for month in [6, 7, 8] { list.append(tx("Fitnessstudio", -3_000, d(2026, month, 10))) }
        return list
    }

    @Test func recurringSeries() {
        let series = BalanceForecast.recurring(actual: history, today: today)
        let byTitle = Dictionary(grouping: series, by: \.title)
        #expect(byTitle["Muster Technik GmbH"]?.map(\.cents) == [320_900], "median of the three salaries")
        #expect(byTitle["Hausverwaltung"]?.map(\.last) == [d(2026, 11, 1)])
        #expect(Set(byTitle["Versicherung AG"]?.map(\.cents) ?? []) == [-2_000, -5_500], "two contracts, one counterpart")
        #expect(byTitle["Markt"] == nil, "several a month")
        #expect(byTitle["Fitnessstudio"] == nil, "ended")
    }

    @Test func estimatesRunUntilTheHorizonAndSkipWhatTheBankAnnounced() {
        let announced = tx("Hausverwaltung", -90_000, d(2026, 12, 1), status: .planned)
        let forecast = BalanceForecast.forecast(planned: [announced], actual: history, items: [], today: today, until: d(2027, 1, 31))
        let rent = forecast.events.filter { $0.title == "Hausverwaltung" }
        #expect(rent.map(\.dueDay) == [d(2026, 12, 1), d(2027, 1, 1)])
        #expect(rent.map(\.isEstimate) == [false, true], "December comes from the bank, January is estimated")
        #expect(forecast.events.filter { $0.title == "Muster Technik GmbH" }.map(\.dueDay) == [d(2026, 11, 28), d(2026, 12, 28), d(2027, 1, 28)])
        #expect(forecast.events.map(\.day) == forecast.events.map(\.day).sorted())
    }

    @Test func announcedPaymentAlreadyBookedIsLeftOut() {
        let announced = tx("Stadtwerke", -8_000, d(2026, 11, 15), status: .planned)
        let booked = tx("Stadtwerke", -8_000, d(2026, 11, 16))
        let overdue = tx("Verein", -4_000, d(2026, 11, 12), status: .planned)
        let stale = tx("Alt", -4_000, d(2026, 11, 1), status: .planned)
        let forecast = BalanceForecast.forecast(planned: [announced, overdue, stale], actual: [booked], items: [], today: today, until: today.adding(days: 30))
        #expect(forecast.events.map(\.title) == ["Verein"])
        #expect(forecast.events.first?.day == today, "overdue counts as due today")
        #expect(forecast.events.first?.isOverdue == true)
    }

    @Test func plannedItemsCountUntilABookingLooksLikeThem() {
        let repair = item("Autoreparatur", -120_000, d(2026, 11, 20), created: d(2026, 11, 10))
        let trip = item("Urlaub", -80_000, d(2027, 1, 10), created: d(2026, 11, 10))
        let workshop = tx("Werkstatt Meier", -131_000, d(2026, 11, 18))
        let before = tx("Werkstatt Alt", -120_000, d(2026, 11, 8))
        let rent = tx("Hausverwaltung", -120_000, d(2026, 11, 19))

        var forecast = BalanceForecast.forecast(planned: [], actual: [before], items: [repair, trip], today: today, until: d(2027, 2, 1))
        #expect(forecast.events.map(\.title) == ["Autoreparatur", "Urlaub"], "a booking from before the plan is not the plan")
        #expect(forecast.matches.isEmpty)

        forecast = BalanceForecast.forecast(planned: [], actual: [workshop, before], items: [repair, trip], today: today, until: d(2027, 2, 1))
        #expect(forecast.matches == [repair.id: workshop.id], "within 25 % and a week")
        #expect(forecast.events.map(\.title) == ["Urlaub"])

        var ignoring = repair
        ignoring.ignoredMatches = [workshop.id]
        forecast = BalanceForecast.forecast(planned: [], actual: [workshop], items: [ignoring], today: today, until: d(2027, 2, 1))
        #expect(forecast.matches.isEmpty)
        #expect(forecast.events.map(\.title) == ["Autoreparatur"])

        // A monthly counterpart with the same amount is not the one-off item.
        let monthly = [9, 10].map { tx("Hausverwaltung", -120_000, d(2026, $0, 19)) } + [rent]
        forecast = BalanceForecast.forecast(planned: [], actual: monthly, items: [repair], today: today.adding(days: 4), until: d(2026, 11, 30))
        #expect(forecast.matches.isEmpty)
    }

    @Test func oneBookingExecutesOneAnnouncedPayment() {
        let first = tx("Sparkonto", -5_000, d(2026, 11, 15), status: .planned)
        let second = Transaction(accountID: "giro", bookingDate: nil, valueDate: d(2026, 11, 17), amountCents: -5_000,
                                 counterpartName: "Sparkonto", purpose: "zweiter Dauerauftrag", status: .planned)
        let booked = tx("Sparkonto", -5_000, d(2026, 11, 16))
        let forecast = BalanceForecast.forecast(planned: [first, second], actual: [booked], items: [], today: today, until: today.adding(days: 30))
        #expect(forecast.events.map(\.source) == [.bank(second.id)], "the second one is still to come")
    }

    @Test func overdueItemCountsToday() {
        let late = item("Handwerker", -50_000, d(2026, 11, 2), created: d(2026, 10, 20))
        let forecast = BalanceForecast.forecast(planned: [], actual: [], items: [late], today: today, until: today.adding(days: 30))
        #expect(forecast.events.map(\.day) == [today])
    }

    @Test func pathAndEarliestDay() {
        let events = [
            ForecastEvent(source: .manual(UUID()), day: d(2026, 11, 20), dueDay: d(2026, 11, 20), cents: -150_000, title: "Reparatur"),
            ForecastEvent(source: .recurring(key: "+gehalt", occurrence: 1), day: d(2026, 11, 28), dueDay: d(2026, 11, 28), cents: 300_000, title: "Gehalt"),
            ForecastEvent(source: .recurring(key: "-miete", occurrence: 1), day: d(2026, 12, 1), dueDay: d(2026, 12, 1), cents: -100_000, title: "Miete"),
            ForecastEvent(source: .manual(UUID()), day: d(2027, 1, 5), dueDay: d(2027, 1, 5), cents: -10_000, title: "Später"),
        ]
        let path = BalanceForecast.path(start: 100_000, events: events, today: today, until: d(2026, 12, 31))
        #expect(path.steps.map(\.cents) == [-50_000, 250_000, 150_000])
        #expect(path.endCents == 150_000)
        #expect(path.lowestCents == -50_000)
        #expect(path.lowestDay == d(2026, 11, 20))
        #expect(path.firstNegativeDay == d(2026, 11, 20))

        let fine = Array(events.dropFirst())
        #expect(BalanceForecast.earliestDay(spending: 50_000, start: 100_000, events: fine, today: today, until: d(2026, 12, 31)) == today)
        // 250 000 would be gone before the rent: only after the salary and with the rent still covered.
        #expect(BalanceForecast.earliestDay(spending: 250_000, start: 100_000, events: fine, today: today, until: d(2026, 12, 31)) == d(2026, 11, 28))
        #expect(BalanceForecast.earliestDay(spending: 350_000, start: 100_000, events: fine, today: today, until: d(2026, 12, 31)) == nil)
    }
}

@Suite struct PlannedItemStoreTests {
    @Test func itemsFollowTheirAccount() async throws {
        let store = InMemoryLedgerStore()
        let connection = Connection(id: "c", connectorID: .mock, displayName: "Bank")
        await store.upsert(connection: connection)
        await store.replaceAccounts([Account(id: "giro", connectionID: "c", type: .giro, name: "Giro")], of: "c")
        let later = item("Später", -1_000, d(2027, 1, 5), created: d(2026, 11, 10))
        var sooner = item("Früher", -2_000, d(2026, 12, 5), created: d(2026, 11, 10))
        try await store.upsertPlannedItem(later)
        try await store.upsertPlannedItem(sooner)
        await #expect(throws: PlannedItemError.unknownAccount("unknown")) {
            try await store.upsertPlannedItem(PlannedItem(accountID: "unknown", day: d(2026, 12, 1), amountCents: -1, title: "x"))
        }
        #expect(await store.snapshot().plannedItems.map(\.title) == ["Früher", "Später"])
        sooner.amountCents = -2_500
        try await store.upsertPlannedItem(sooner)
        #expect(await store.snapshot().plannedItems.map(\.amountCents) == [-2_500, -1_000])
        await store.removePlannedItem(later.id)
        #expect(await store.snapshot().plannedItems.count == 1)
        await store.removeConnection("c")
        #expect(await store.snapshot().plannedItems.isEmpty)
    }
}
