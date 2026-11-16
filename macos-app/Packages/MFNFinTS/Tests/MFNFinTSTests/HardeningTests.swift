import Foundation
import MFNCore
import Testing
@testable import MFNFinTS

/// Records HKEND only when it arrives outside a cancelled task (as a real URLSession would).
private actor CancellationAwareTransport: FinTSTransport {
    private let fake = FakeBank()
    private(set) var deliveredTypes: [[String]] = []

    func exchange(_ message: [UInt8]) async throws(ConnectorError) -> [UInt8] {
        if Task.isCancelled { throw .cancelled }
        let segments = ScriptedFinTSTransport.flatten(message)
        deliveredTypes.append(segments.map(\.type).filter { !$0.hasPrefix("HN") })
        return fake.respond(segments)
    }
}

@Suite struct HardeningTests {
    // MARK: Wire

    @Test func hugeBinaryLengthThrowsInsteadOfTrapping() {
        let bytes = Array("HNVSD:999:1+@\(Int.max)@abc'".utf8)
        #expect(throws: FinTSWireError.binaryOutOfBounds(offset: 12)) {
            try FinTSWire.parse(bytes)
        }
    }

    @Test func binaryLengthBeyondMessageThrows() {
        let bytes = Array("HNVSD:999:1+@5@abc'".utf8)
        #expect(throws: FinTSWireError.binaryOutOfBounds(offset: 12)) {
            try FinTSWire.parse(bytes)
        }
    }

    // MARK: Outgoing allowlist

    @Test func readOnlySegmentsAreAllowed() throws {
        try FinTSDialog.checkOutgoing(["HKIDN", "HKVVB", "HKSYN", "HKTAN", "HKEND", "HKSPA", "HKSAL", "HKKAZ", "HKCAZ", "HKWPD"])
    }

    @Test func transferSegmentIsRefusedBeforeSending() async throws {
        let transport = FakeBank().transport()
        let d = FinTSDialog(bank: FakeBank.bank, credentials: FakeBank.credentials, product: .unregistered, mechanism: .oneStep, transport: transport)
        try await d.open()
        let transfer = FinTSSegment(type: "HKCCS", version: 1, elements: ["1"])
        await #expect(throws: ConnectorError.formatChanged(detail: "FinTS: Segment HKCCS ist nicht erlaubt")) {
            try await d.send([transfer])
        }
        await d.close()
        #expect(await transport.requestTypes == [["HKIDN", "HKVVB"], ["HKEND"]])
    }

    // MARK: HKEND under cancellation

    @Test func closeSendsHKENDEvenWhenTaskIsCancelled() async throws {
        let transport = CancellationAwareTransport()
        let d = FinTSDialog(bank: FakeBank.bank, credentials: FakeBank.credentials, product: .unregistered, mechanism: .oneStep, transport: transport)
        try await d.open()
        let closing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await d.close()
        }
        await closing.value
        #expect(await transport.deliveredTypes.last == ["HKEND"])
    }

    // MARK: Message errors

    @Test func tanPollWithBusinessErrorIsLeftToTheHandler() throws {
        let hirmg = FinTSSegment(type: "HIRMG", version: 2, elements: [FinTSDataElement(texts: ["9050", nil, "Teilweise fehlerhaft."])])
        let hirms = FinTSSegment(type: "HIRMS", version: 2, reference: 3, elements: [FinTSDataElement(texts: ["9010", nil, "Keine Umsätze."])])
        let response = try FinTSResponse(bytes: try FinTSMessage.build(dialogID: "0", messageNumber: 1, segments: [hirmg, hirms], security: nil))
        try FinTSDialog.checkMessageErrors(response, isTANPoll: true)
        #expect(throws: ConnectorError.formatChanged(detail: "FinTS 9010")) {
            try FinTSDialog.checkMessageErrors(response)
        }
    }

    @Test func wireErrorDetailCarriesNoPayload() {
        let detail = FinTSDialog.wireErrorDetail(.invalidHeader("HIUPD+DE00123456781234567890"), context: "X")
        #expect(detail == "X: ungültiger Segmentkopf")
    }

    // MARK: Decoupled poll evaluation

    @Test func pollBusinessErrorIsReturnedNotRejected() throws {
        func response(_ segments: [FinTSSegment]) throws -> FinTSResponse {
            try FinTSResponse(bytes: FinTSMessage.build(dialogID: "D", messageNumber: 1, segments: segments, security: nil))
        }
        let partly = FakeDKB.code("HIRMG", "9050", "Teilweise fehlerhaft.")
        #expect(DecoupledTANHandler.evaluate(try response([partly, FakeDKB.code("HIRMS", "9010", "keine Umsätze", reference: 3)])) == .approved)
        #expect(DecoupledTANHandler.evaluate(try response([partly, FakeDKB.code("HIRMS", "9955", "Auftrag abgelehnt", reference: 3)])) == .rejected("9955"))
        #expect(DecoupledTANHandler.evaluate(try response([partly, FakeDKB.code("HIRMS", "9340", "PIN falsch", reference: 3)])) == .rejected("9340"))
        #expect(FinTSCode.scaNotRequired == "3076")
    }

    // MARK: ING storage period

    @Test func ingStatementStartCountsTodayAsFirstDay() throws {
        let today = try #require(BankDay(iso: "2026-11-16"))
        #expect(INGMapping.statementStart(since: nil, today: today, storageDays: 90) == BankDay(iso: "2026-08-19"))
        #expect(INGMapping.statementStart(since: nil, today: today, storageDays: 1) == today)
    }
}
