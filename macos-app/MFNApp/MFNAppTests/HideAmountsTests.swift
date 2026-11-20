import Foundation
import MFNCore
import Testing
@testable import MFN

@MainActor @Suite struct HideAmountsTests {
    private static let shortfall = SnapshotIndex.Shortfall(
        day: Fixture.day, missingCents: 5_000, plannedOutCents: 20_000, dayText: "14. März", missingText: "50,00 €"
    )

    private static func model(hidden: Bool) -> AppModel {
        let model = Fixture.model()
        var index = SnapshotIndex()
        index.shortfalls[Fixture.giro.id] = shortfall
        #if DEBUG
        model.applyIndexForTesting(index)
        #endif
        model.hideAmounts = hidden
        return model
    }

    @Test func shortfallIsHiddenWithHideAmounts() {
        #expect(Self.model(hidden: false).shortfall(for: Fixture.giro.id) == Self.shortfall)
        #expect(Self.model(hidden: true).shortfall(for: Fixture.giro.id) == nil)
        #expect(Self.model(hidden: false).shortfall(for: Fixture.other.id) == nil)
    }

    @Test func foreignAmountFollowsHideAmounts() {
        let foreign = Fixture.transaction("f", original: (cents: -1_250, currency: "USD"))
        let model = Fixture.model()
        let shown = model.foreignAmountText(of: foreign)
        #expect(shown?.contains("12,50") == true)
        model.hideAmounts = true
        #expect(model.foreignAmountText(of: foreign) == nil)
    }

    @Test func noForeignAmountWithoutOriginal() {
        #expect(Fixture.model().foreignAmountText(of: Fixture.transaction("plain")) == nil)
    }

    /// An account topped up as its debits come: the estimated debits must not warn.
    @Test func shortfallCountsKnownPaymentsOnly() {
        let today = Fixture.day
        let estimate = ForecastEvent(source: .recurring(key: "-miete", occurrence: 1), day: today, dueDay: today, cents: -80_000, title: "Miete")
        let planned = ForecastEvent(source: .manual(UUID()), day: today.adding(days: 2), dueDay: today.adding(days: 2), cents: -3_000, title: "Werkstatt")
        let basis = SnapshotIndex.ForecastBasis(bookedCents: 5_000, startCents: 5_000,
                                                forecast: AccountForecast(events: [estimate, planned], until: today.adding(months: 12)),
                                                horizon: today.adding(days: 14), ownPlannedCents: -3_000)
        let path = SnapshotIndex.knownPath(basis, today: today)
        #expect(path.steps.map(\.event.title) == ["Werkstatt"])
        #expect(path.lowestCents == 2_000 && path.firstNegativeDay == nil)
    }

    /// Known payments alone take the balance below zero: that is what the warning reports,
    /// whatever the estimates add before or after.
    @Test func knownPaymentsBelowZeroAreFound() {
        let today = Fixture.day
        let salary = ForecastEvent(source: .recurring(key: "+gehalt", occurrence: 1), day: today, dueDay: today, cents: 300_000, title: "Gehalt")
        let workshop = ForecastEvent(source: .manual(UUID()), day: today.adding(days: 2), dueDay: today.adding(days: 2), cents: -8_000, title: "Werkstatt")
        let order = ForecastEvent(source: .bank("t-order"), day: today.adding(days: 5), dueDay: today.adding(days: 5), cents: -4_000, title: "Dauerauftrag")
        let basis = SnapshotIndex.ForecastBasis(bookedCents: 5_000, startCents: 5_000,
                                                forecast: AccountForecast(events: [salary, workshop, order], until: today.adding(months: 12)),
                                                horizon: today.adding(days: 14), ownPlannedCents: -8_000)
        let path = SnapshotIndex.knownPath(basis, today: today)
        #expect(path.steps.map(\.event.title) == ["Werkstatt", "Dauerauftrag"])
        #expect(path.firstNegativeDay == today.adding(days: 2))
        #expect(path.lowestCents == -7_000)
    }
}
