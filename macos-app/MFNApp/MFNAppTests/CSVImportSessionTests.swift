import Foundation
import MFNCore
import Testing
@testable import MFN

@MainActor @Suite struct CSVImportSessionTests {
    /// Columns: Datum;Name;Zweck;Wert A (point decimals);Wert B (comma decimals).
    private static let csv = """
        Datum;Name;Zweck;Wert A;Wert B
        01.03.2026;Erika Mustermann;Miete;-1234.50;-1.234,50
        02.03.2026;Max Beispiel;Strom;-20.25;-20,25
        03.03.2026;Erika Mustermann;Kaffee;-3.40;-3,40
        """

    private static func session(
        text: String = csv, accountID: AccountID? = Fixture.giro.id,
        stored: @escaping @MainActor (AccountID) -> [MFNCore.Transaction] = { _ in [] }
    ) throws -> CSVImportSession {
        let data = Data(text.utf8)
        let document = try CSVDocument(data: data)
        return CSVImportSession(fileName: "test.csv", data: data, document: document, accounts: [Fixture.giro], accountID: accountID, stored: stored)
    }

    private static func settle(_ session: CSVImportSession) async {
        for _ in 0..<500 where session.isRefreshing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func amountColumnChangeDetectsTheSeparator() async throws {
        let session = try Self.session()
        session.setColumn(3, for: .amount)
        #expect(session.document.decimalSeparator == .point)
        session.setColumn(4, for: .amount)
        #expect(session.document.decimalSeparator == .comma)
        session.setColumn(3, for: .debit)
        #expect(session.document.decimalSeparator == .point)
        session.cancel()
    }

    @Test func otherColumnsDoNotRedetect() async throws {
        let session = try Self.session()
        session.setColumn(3, for: .amount)
        #expect(session.document.decimalSeparator == .point)
        // Mapping the comma column to a non-amount field leaves the separator alone.
        session.setColumn(4, for: .purpose)
        #expect(session.document.decimalSeparator == .point)
        session.cancel()
    }

    @Test func manualChoiceSurvivesLaterColumnChanges() async throws {
        let session = try Self.session()
        session.setDecimalSeparator(.comma)
        session.setColumn(3, for: .amount)
        #expect(session.document.decimalSeparator == .comma)
        session.setColumn(4, for: .credit)
        #expect(session.document.decimalSeparator == .comma)
        session.cancel()
    }

    @Test func previewIsBuiltOncePerRefresh() async throws {
        let session = try Self.session()
        session.setColumn(0, for: .bookingDate)
        session.setColumn(1, for: .counterparty)
        session.setColumn(2, for: .purpose)
        session.setColumn(4, for: .amount)
        try await Task.sleep(for: .milliseconds(50))
        await Self.settle(session)
        #expect(!session.isRefreshing)
        #expect(session.previewRows.count == 3)
        #expect(session.previewRows.allSatisfy { $0.state == .new })
        #expect(session.importCount == 3)
        // Same value on repeated reads: no recomputation in a body pass.
        #expect(session.previewRows.map(\.id) == session.previewRows.map(\.id))
        session.cancel()
    }

    @Test func storedRowsMarkDuplicatesInThePreview() async throws {
        let first = try Self.session()
        first.setColumn(0, for: .bookingDate)
        first.setColumn(1, for: .counterparty)
        first.setColumn(2, for: .purpose)
        first.setColumn(4, for: .amount)
        try await Task.sleep(for: .milliseconds(50))
        await Self.settle(first)
        let stored = first.result.transactions
        #expect(stored.count == 3)

        let second = try Self.session(stored: { _ in stored })
        second.setColumn(0, for: .bookingDate)
        second.setColumn(1, for: .counterparty)
        second.setColumn(2, for: .purpose)
        second.setColumn(4, for: .amount)
        try await Task.sleep(for: .milliseconds(50))
        await Self.settle(second)
        #expect(second.previewRows.count == 3)
        #expect(second.previewRows.allSatisfy { $0.state == .duplicate })
        #expect(second.importCount == 0)
        first.cancel()
        second.cancel()
    }

    @Test func noAccountClearsThePreview() throws {
        let session = try Self.session(accountID: nil)
        #expect(session.previewRows.isEmpty)
        #expect(!session.isRefreshing)
        #expect(session.account == nil)
    }

    @Test func previewRowsAreLimited() {
        var result = CSVParseResult()
        result.transactions = (0..<5).map { Fixture.transaction("row-\($0)", cents: -($0 + 1)) }
        var plan = CSVImportPlan()
        plan.duplicates = [result.transactions[1]]
        plan.likelyDuplicates = [result.transactions[2]]
        let rows = CSVImportSession.previewRows(result: result, plan: plan, limit: 3)
        #expect(rows.map(\.state) == [.new, .duplicate, .likelyDuplicate])
        #expect(CSVImportSession.previewRows(result: result, plan: plan, limit: 50).count == 5)
        #expect(CSVPreviewRow.State.duplicate.title == "Vorhanden")
    }

    @Test func fileSizeCap() throws {
        #expect(AppModel.maxCSVImportBytes == 50 * 1_024 * 1_024)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mfn-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let small = directory.appendingPathComponent("small.csv")
        try Data(Self.csv.utf8).write(to: small)
        if case .failure(let failure) = AppModel.openCSV(at: small) { Issue.record("unexpected: \(failure.message)") }

        // One byte over the cap: refused without being split.
        let big = directory.appendingPathComponent("big.csv")
        try Data(repeating: UInt8(ascii: "a"), count: AppModel.maxCSVImportBytes + 1).write(to: big)
        if case .success = AppModel.openCSV(at: big) { Issue.record("file over the cap was accepted") }
        if case .failure(let failure) = AppModel.openCSV(at: big) { #expect(failure.message.contains("zu groß")) }

        let missing = AppModel.openCSV(at: directory.appendingPathComponent("missing.csv"))
        if case .failure(let failure) = missing { #expect(failure.message == "Die Datei konnte nicht gelesen werden.") } else { Issue.record("missing file opened") }
    }
}
