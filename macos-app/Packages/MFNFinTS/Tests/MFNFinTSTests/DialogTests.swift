import Foundation
import MFNCore
import Testing
@testable import MFNFinTS

/// A fake FinTS server: answers by request type. Never a real bank.
struct FakeBank {
    var pinWrong = false
    var pages = 3
    var decoupled = false

    static let bank = FinTSBank(url: URL(string: "https://fints.example.invalid/")!, blz: "12345678")
    static let credentials = FinTSCredentials(userID: "testuser", pin: "geheim-1234")

    func respond(_ request: [FinTSSegment]) -> [UInt8] {
        let types = request.map(\.type)
        func number(of type: String) -> Int { request.first { $0.type == type }?.number ?? 3 }
        var segments: [FinTSSegment] = []

        if types.contains("HKEND") {
            segments = [code("HIRMG", "0100", "Dialog beendet.")]
        } else if types.contains("HKIDN") {
            if pinWrong {
                segments = [code("HIRMG", "9050", "Teilweise fehlerhaft."), code("HIRMS", "9340", "PIN falsch.", reference: number(of: "HKIDN"))]
            } else {
                segments = [
                    code("HIRMG", "0010", "Nachricht entgegengenommen."),
                    code("HIRMS", "3920", "Zugelassene TAN-Verfahren.", reference: number(of: "HKTAN"), parameters: ["942"]),
                    FinTSSegment(type: "HIBPA", version: 3, elements: ["17", FinTSDataElement(texts: ["280", "12345678"]), "Testbank", "1", "1", "300"]),
                    FinTSSegment(type: "HISALS", version: 7, elements: ["1", "1", "0"]),
                    FinTSSegment(type: "HISALS", version: 6, elements: ["1", "1", "0"]),
                    FinTSSegment(type: "HIKAZS", version: 7, elements: ["1", "1", "0", FinTSDataElement(texts: ["90", "N", "N"])]),
                    FinTSSegment(type: "HIPINS", version: 1, elements: ["1", "1", "0", FinTSDataElement(texts: ["5", "20", "6", "Benutzer", "Kunde", "HKSAL", "J", "HKKAZ", "N", "HKSPA", "N"])]),
                    FinTSSegment(type: "HIUPA", version: 4, elements: ["testuser", "3", "0"]),
                    FinTSSegment(type: "HIUPD", version: 6, elements: [
                        FinTSDataElement(texts: ["1234567890", nil, "280", "12345678"]), "DE00123456781234567890", "testuser", "1", "EUR",
                        "Muster", "Max", "Girokonto", .empty, FinTSDataElement(texts: ["HKSAL", "1"]), FinTSDataElement(texts: ["HKKAZ", "1"]),
                    ]),
                ]
                if types.contains("HKSYN") {
                    segments.append(FinTSSegment(type: "HISYN", version: 4, reference: number(of: "HKSYN"), elements: ["SYS-4711"]))
                }
            }
        } else if types.contains("HKSAL") {
            if decoupled, !types.contains("HKTAN") {
                segments = [code("HIRMG", "0010", "OK")]
            } else if decoupled {
                segments = [
                    code("HIRMG", "3060", "Teilweise liegen Warnungen vor."),
                    code("HIRMS", "3956", "Bitte in der App freigeben.", reference: number(of: "HKTAN")),
                    FinTSSegment(type: "HITAN", version: 7, reference: number(of: "HKTAN"), elements: ["4", .empty, "ORDER-1", "Bitte in der DKB-App bestätigen"]),
                ]
            } else {
                segments = [
                    code("HIRMG", "0010", "OK"),
                    code("HIRMS", "0020", "Auftrag ausgeführt.", reference: number(of: "HKSAL")),
                    FinTSSegment(type: "HISAL", version: 7, reference: number(of: "HKSAL"), elements: ["DE00", "Girokonto", "EUR", FinTSDataElement(texts: ["C", "1234,56", "EUR", "20261109"])]),
                ]
            }
        } else if types.contains("HKKAZ") {
            let touchdown = request.first { $0.type == "HKKAZ" }?[5].first
            let page = touchdown.flatMap { Int($0.dropFirst()) } ?? 1
            segments = [code("HIRMG", "0010", "OK")]
            if page < pages {
                segments.append(code("HIRMS", "3040", "Es liegen weitere Informationen vor.", reference: number(of: "HKKAZ"), parameters: ["P\(page + 1)"]))
            }
            segments.append(FinTSSegment(type: "HIKAZ", version: 7, reference: number(of: "HKKAZ"), elements: [.binary(Data("page \(page)".utf8))]))
        } else if types.contains("HKTAN"), request.first(where: { $0.type == "HKTAN" })?[0].first == "S" {
            segments = [
                code("HIRMG", "0010", "OK"),
                code("HIRMS", "0020", "Auftrag ausgeführt.", reference: number(of: "HKTAN")),
                FinTSSegment(type: "HISAL", version: 7, reference: number(of: "HKTAN"), elements: ["DE00", "Girokonto", "EUR", FinTSDataElement(texts: ["C", "99,00", "EUR", "20261109"])]),
            ]
        }
        // Responses are built with the same builder (no security envelope needed for tests).
        return (try? FinTSMessage.build(dialogID: "DIALOG-1", messageNumber: 1, segments: segments, security: nil)) ?? []
    }

    func code(_ type: String, _ code: String, _ text: String, reference: Int? = nil, parameters: [String] = []) -> FinTSSegment {
        var texts: [String?] = [code, nil, text]
        texts += parameters.map { Optional($0) }
        return FinTSSegment(type: type, version: 2, reference: reference, elements: [FinTSDataElement(texts: texts)])
    }

    func transport() -> ScriptedFinTSTransport {
        ScriptedFinTSTransport { request, _ throws(ConnectorError) in respond(request) }
    }
}

private func dialog(_ bank: FakeBank, transport: ScriptedFinTSTransport, mechanism: FinTSTANMechanism = .oneStep, handler: (any FinTSTANHandler)? = nil) -> FinTSDialog {
    FinTSDialog(bank: FakeBank.bank, credentials: FakeBank.credentials, product: .unregistered, mechanism: mechanism, transport: transport, tanHandler: handler)
}

@Suite struct DialogTests {
    @Test func initParsesBPDUPDAndSystemID() async throws {
        let transport = FakeBank().transport()
        let d = dialog(FakeBank(), transport: transport)
        let response = try await d.open(synchronize: true)
        #expect(response.dialogID == "DIALOG-1")
        #expect(await d.dialogID == "DIALOG-1")
        #expect(await d.systemID == "SYS-4711")
        let bpd = await d.bpd
        #expect(bpd.version == 17)
        #expect(bpd.bankName == "Testbank")
        #expect(bpd.versions["HKSAL"] == [6, 7])
        #expect(bpd.bestVersion(of: "HKSAL", supported: [5, 6]) == 6)
        #expect(bpd.tanRequired == ["HKSAL": true, "HKKAZ": false, "HKSPA": false])
        let account = try #require(await d.upd.accounts.first)
        #expect(account.iban == "DE00123456781234567890")
        #expect(account.kind == .giro)
        #expect(account.allowedTransactions == ["HKSAL", "HKKAZ"])
        await d.close()
        #expect(await transport.requestTypes == [["HKIDN", "HKVVB", "HKSYN"], ["HKEND"]])
    }

    @Test func runAlwaysEndsDialogEvenWhenBodyThrows() async {
        let transport = FakeBank().transport()
        await #expect(throws: ConnectorError.unsupportedAccount) {
            try await FinTSDialog.run(dialog(FakeBank(), transport: transport)) { _ throws(ConnectorError) -> Int in
                throw .unsupportedAccount
            }
        }
        #expect(await transport.requestTypes.last == ["HKEND"])
    }

    @Test func wrongPINMapsToAuthFailed() async {
        let transport = FakeBank(pinWrong: true).transport()
        await #expect(throws: ConnectorError.authFailed) {
            try await FinTSDialog.run(dialog(FakeBank(pinWrong: true), transport: transport)) { _ throws(ConnectorError) in 0 }
        }
    }

    /// DKB's live answer to an unregistered product (2026-11-11): 9800 first, the reason after it.
    @Test func reportsTheReasonBehindTheGenericAbort() throws {
        let hirmg = FinTSSegment(type: "HIRMG", version: 2, elements: [
            FinTSDataElement(texts: ["9800", nil, "Der Dialog wurde abgebrochen."]),
            FinTSDataElement(texts: ["9078", nil, "FinTS-Produkt ist nicht registriert."]),
        ])
        let response = try FinTSResponse(bytes: try FinTSMessage.build(dialogID: "0", messageNumber: 1, segments: [hirmg], security: nil))
        #expect(throws: ConnectorError.formatChanged(detail: "FinTS 9078: FinTS-Produkt ist nicht registriert.")) {
            try FinTSDialog.checkMessageErrors(response)
        }
    }

    /// Segment texts (HIRMS) can name accounts and the detail is logged publicly: code only.
    @Test func segmentReasonCarriesCodeOnly() throws {
        let hirmg = FinTSSegment(type: "HIRMG", version: 2, elements: [FinTSDataElement(texts: ["9050", nil, "Teilweise fehlerhaft."])])
        let hirms = FinTSSegment(type: "HIRMS", version: 2, reference: 3, elements: [FinTSDataElement(texts: ["9210", nil, "Konto 1234567890 nicht zulässig."])])
        let response = try FinTSResponse(bytes: try FinTSMessage.build(dialogID: "0", messageNumber: 1, segments: [hirmg, hirms], security: nil))
        #expect(throws: ConnectorError.formatChanged(detail: "FinTS 9210")) {
            try FinTSDialog.checkMessageErrors(response)
        }
    }

    @Test func pagesThroughTouchdowns() async throws {
        let transport = FakeBank(pages: 3).transport()
        let responses = try await FinTSDialog.run(dialog(FakeBank(), transport: transport)) { d throws(ConnectorError) in
            let account = await d.upd.accounts[0]
            return try await d.sendAllPages { touchdown in
                FinTSSegments.statementMT940(version: 7, account: account, from: nil, to: nil, touchdown: touchdown)
            }
        }
        let pages = responses.compactMap { $0.segment("HIKAZ")?[0].components.first??.binary }.map { String(decoding: $0, as: UTF8.self) }
        #expect(pages == ["page 1", "page 2", "page 3"])
        let kazRequests = await transport.requests.compactMap { $0.first { $0.type == "HKKAZ" } }
        #expect(kazRequests.map { $0[5].first } == [nil, "P2", "P3"])
    }

    @Test func twoStepAddsHKTANAndCallsHandler() async throws {
        struct ApproveAndPoll: FinTSTANHandler {
            func resolve(_ challenge: FinTSTANChallenge, dialog: FinTSDialog) async throws(ConnectorError) -> FinTSResponse {
                #expect(challenge.isDecoupled)
                #expect(challenge.orderReference == "ORDER-1")
                return try await dialog.send([FinTSSegments.tanStatusPoll(version: 7, orderReference: challenge.orderReference ?? "")])
            }
        }
        let bank = FakeBank(decoupled: true)
        let transport = bank.transport()
        let mechanism = FinTSTANMechanism.twoStep(securityFunction: "942", hktanVersion: 7, tanMedium: nil)
        let response = try await FinTSDialog.run(dialog(bank, transport: transport, mechanism: mechanism, handler: ApproveAndPoll())) { d throws(ConnectorError) in
            let account = await d.upd.accounts[0]
            return try await d.send([FinTSSegments.balance(version: 7, account: account)])
        }
        #expect(response.segment("HISAL")?[3][1] == "99,00")
        #expect(await transport.requestTypes == [["HKIDN", "HKVVB", "HKTAN"], ["HKSAL", "HKTAN"], ["HKTAN"], ["HKEND"]])
        // Two-step keeps security profile PIN:2 (one-step uses PIN:1).
        let heads = await transport.requests.compactMap { $0.first { $0.type == "HNSHK" } }
        #expect(!heads.isEmpty && heads.allSatisfy { $0[0].components.map { $0?.text } == ["PIN", "2"] && $0[1].first == "942" })
    }

    @Test func twoStepWithoutHandlerThrowsAuthRequired() async {
        let bank = FakeBank(decoupled: true)
        let mechanism = FinTSTANMechanism.twoStep(securityFunction: "942", hktanVersion: 7, tanMedium: nil)
        await #expect(throws: ConnectorError.self) {
            try await FinTSDialog.run(dialog(bank, transport: bank.transport(), mechanism: mechanism)) { d throws(ConnectorError) in
                let account = await d.upd.accounts[0]
                return try await d.send([FinTSSegments.balance(version: 7, account: account)])
            }
        }
    }
}

@Suite struct MessageTests {
    let security = FinTSMessage.Security(bank: FakeBank.bank, credentials: FakeBank.credentials, systemID: "SYS", mechanism: .oneStep, tan: nil)
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func headerSizeMatchesMessageLength() throws {
        let bytes = try FinTSMessage.build(dialogID: "0", messageNumber: 1, segments: [FinTSSegments.synchronization()], security: security, now: date, controlReference: "4711")
        let header = try #require(try FinTSWire.parse(bytes).first)
        #expect(header.type == "HNHBK")
        #expect(Int(header[0].first ?? "") == bytes.count)
        #expect(header[0].first?.count == 12)
    }

    @Test func securedLayoutAndNumbering() throws {
        let bytes = try FinTSMessage.build(dialogID: "D", messageNumber: 2, segments: [FinTSSegments.synchronization(), FinTSSegments.sepaAccounts()], security: security, now: date, controlReference: "4711")
        let outer = try FinTSWire.parse(bytes)
        #expect(outer.map(\.type) == ["HNHBK", "HNVSK", "HNVSD", "HNHBS"])
        #expect(outer.map(\.number) == [1, 998, 999, 6])
        let inner = try FinTSWire.parse(try #require(outer[2][0].components.first??.binary))
        #expect(inner.map(\.type) == ["HNSHK", "HKSYN", "HKSPA", "HNSHA"])
        #expect(inner.map(\.number) == [2, 3, 4, 5])
        #expect(inner[0][1].first == "999")
        #expect(inner[3][0].first == "4711")
        #expect(inner[3][2].first == "geheim-1234")
        #expect(outer[3][0].first == "2")
    }

    @Test func redactionHidesPINAndUser() throws {
        let bytes = try FinTSMessage.build(dialogID: "D", messageNumber: 2, segments: [FinTSSegments.identification(bank: FakeBank.bank, customerID: "testuser", systemID: "SYS")], security: security, now: date)
        let response = try FinTSResponse(bytes: bytes)
        let text = FinTSMessage.redactedDescription(response.segments)
        #expect(!text.contains("geheim-1234"))
        #expect(!text.contains("testuser"))
        #expect(!String(describing: FakeBank.credentials).contains("geheim"))
        #expect(!response.description.contains("geheim"))
    }

    @Test func anonymousMessageHasNoSecurity() throws {
        let bytes = try FinTSMessage.build(dialogID: "0", messageNumber: 1, segments: [
            FinTSSegments.identification(bank: FakeBank.bank, customerID: "", systemID: "0", anonymous: true),
            FinTSSegments.processingPreparation(bpdVersion: 0, updVersion: 0, product: .unregistered),
        ], security: nil, now: date)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("HKIDN:2:2+280:12345678+9999999999+0+0'"))
        #expect(text.contains("HKVVB:3:3+0+0+0+MFN-UNREGISTERED+0.1'"))
        #expect(!text.contains("HNVSK"))
    }
}
