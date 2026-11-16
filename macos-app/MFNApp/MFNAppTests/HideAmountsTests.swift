import Foundation
import MFNCore
import Testing
@testable import MFN

@MainActor @Suite struct HideAmountsTests {
    private static let shortfall = SnapshotIndex.Shortfall(
        day: Fixture.day, missingCents: 5_000, plannedOutCents: 20_000, estimated: false, dayText: "14. März", missingText: "50,00 €"
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

    @Test func shortfallTextsNameThePaymentKind() {
        let text = ShortfallFormat.text(Self.shortfall)
        #expect(text.contains("geplante Zahlungen") && !text.contains("regelmäßige"))
        var estimated = Self.shortfall
        estimated.estimated = true
        #expect(ShortfallFormat.short(estimated).contains("regelmäßige"))
    }
}
