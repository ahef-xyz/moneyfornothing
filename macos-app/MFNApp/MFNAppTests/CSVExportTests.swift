import Foundation
import MFNCore
import Testing
@testable import MFN

@MainActor @Suite struct CSVExportTests {
    @Test func scopeIsBankAndAccountName() {
        let model = Fixture.model()
        #expect(model.csvExportScope(of: Fixture.giro) == "Testbank Giro")
        let fileName = TransactionCSVExporter.fileName(scope: model.csvExportScope(of: Fixture.other), day: Fixture.day)
        #expect(fileName == "MFN-Testbank-Rücklage-2026-03-14.csv")
        #expect(!fileName.contains(" "))
    }

    @Test func exportOfAnotherAccountIgnoresSearchAndFilters() {
        let model = Fixture.model(ledger: Fixture.snapshot(transactions: [
            Fixture.transaction("booked-1", cents: -100, purpose: "Miete"),
            Fixture.transaction("booked-2", cents: -200, purpose: "Strom"),
            Fixture.transaction("pending-1", cents: -300, status: .pending, purpose: "Kaffee"),
            Fixture.transaction("cancelled-1", cents: -400, status: .cancelled),
            Fixture.transaction("elsewhere", account: Fixture.other),
        ]))
        model.ledgerQuery.text = "Miete"
        model.ledgerQuery.onlyImported = true
        let rows = model.unfilteredExportRows(of: Fixture.giro.id)
        #expect(Set(rows.map(\.id.rawValue)) == ["booked-1", "booked-2", "pending-1"])
        // Upcoming first, then booked.
        #expect(rows.first?.id == "pending-1")
        #expect(!rows.contains { $0.accountID == Fixture.other.id })
    }

    @Test func exportItemFollowsTheSelection() {
        // Locked: no list, nothing to export.
        #expect(Fixture.model().csvExportItem == nil)
        #expect(!Fixture.model().canExportCSV)
    }
}
