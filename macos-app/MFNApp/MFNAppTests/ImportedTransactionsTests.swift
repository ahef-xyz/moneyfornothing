import Foundation
import MFNCore
import Testing
@testable import MFN

@MainActor @Suite struct ImportedTransactionsTests {
    private static let batchA: ImportBatchID = "batch-a"
    private static let batchB: ImportBatchID = "batch-b"

    private static func model() -> AppModel {
        Fixture.model(ledger: Fixture.snapshot(transactions: [
            Fixture.transaction("bank-1"),
            Fixture.transaction("imp-1", importID: batchA),
            Fixture.transaction("imp-2", cents: -2_000, importID: batchA),
            Fixture.transaction("imp-3", account: Fixture.other, cents: -3_000, importID: batchB),
            Fixture.transaction("bank-2", account: Fixture.other, cents: -4_000),
        ]))
    }

    @Test func indexCountsPerAccountAndBatch() {
        let index = Self.model().importIndex
        #expect(index.count == 3)
        #expect(index.byAccount[Fixture.giro.id] == 2)
        #expect(index.byAccount[Fixture.other.id] == 1)
        #expect(index.byBatch[Self.batchA] == 2)
        #expect(index.byBatch[Self.batchB] == 1)
    }

    @Test func emptyIndexHasNoCounts() {
        let index = ImportIndex()
        #expect(index.count == 0 && index.byAccount.isEmpty && index.byBatch.isEmpty)
    }

    @Test func modelCountsMatchTheIndex() {
        let model = Self.model()
        #expect(model.importedCount(of: Fixture.giro.id) == 2)
        #expect(model.importedCount(of: "unknown") == 0)
        #expect(model.importedCount(ofImport: Self.batchB) == 1)
        #expect(model.importedCount(ofImport: "missing") == 0)
    }

    @Test func onlyImportedRowsCanBeRemoved() {
        let model = Self.model()
        #expect(model.areAllImported(["imp-1", "imp-2"]))
        #expect(model.areAllImported(["imp-3"]))
        #expect(!model.areAllImported(["bank-1"]))
        #expect(!model.areAllImported(["imp-1", "bank-1"]))
        #expect(!model.areAllImported(["unknown"]))
        #expect(!model.areAllImported([]))
    }

    @Test func lockedModelOpensNoRemovalRequest() {
        let model = Self.model()
        model.requestRemoveImports(["imp-1"])
        model.requestRemoveImports(of: Fixture.giro.id)
        model.requestRemoveImport(Self.batchA)
        #expect(model.importRemoval == nil)
        #expect(!model.canRemoveSelectedImports)
    }

    @Test func removalRequestTexts() {
        let one = ImportRemovalRequest(ids: ["a"], scope: "aus „Giro“")
        #expect(one.title == "1 importierten Umsatz entfernen?")
        #expect(one.message.hasPrefix("Der Umsatz wird aus „Giro“ aus MFN gelöscht."))
        let many = ImportRemovalRequest(ids: ["a", "b"], scope: nil)
        #expect(many.title == "2 importierte Umsätze entfernen?")
        #expect(many.message.hasPrefix("Die Umsätze werden aus MFN gelöscht."))
    }

    @Test func sourceTitle() {
        let named = ImportBatch(accountID: Fixture.giro.id, format: "ing", fileName: nil, encoding: nil, rowCount: 1)
        let generic = ImportBatch(accountID: Fixture.giro.id, format: nil, fileName: nil, encoding: nil, rowCount: 1)
        #expect(generic.sourceTitle == "CSV-Import")
        #expect(named.sourceTitle.hasPrefix("CSV-Import"))
    }
}
