import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNFinTS

@Suite struct DecoupledTANParametersTests {
    let bpd = FinTSBPD(version: 42, bankName: "DKB", versions: [:], tanRequired: [:], parameterSegments: FakeDKB.bpd.filter { $0.type == "HITANS" })

    @Test func readsDecoupledPollingFromHITANS7() throws {
        let method = try #require(DecoupledTANParameters.method("942", in: bpd))
        #expect(method.hktanVersion == 7)
        #expect(method.isDecoupled)
        #expect(method.name == "DKB-App")
        #expect(method.maxStatusRequests == 10)
        #expect(method.waitBeforeFirstStatus == .seconds(3))
        #expect(method.waitBetweenStatus == .seconds(1))
    }

    @Test func listsAllMethodsHighestVersionWins() {
        let methods = DecoupledTANParameters.all(in: bpd)
        #expect(methods.map(\.securityFunction) == ["912", "942"])
        #expect(methods.allSatisfy { $0.hktanVersion == 7 })
        #expect(methods.first?.isDecoupled == false)
    }

    @Test func version6OnlyUsesDefaults() throws {
        let v6 = FinTSBPD(version: 1, bankName: nil, versions: [:], tanRequired: [:], parameterSegments: FakeDKB.bpd.filter { $0.type == "HITANS" && $0.version == 6 })
        let method = try #require(DecoupledTANParameters.method("942", in: v6))
        #expect(method.hktanVersion == 6)
        #expect(method.maxStatusRequests == nil)
        #expect(method.statusRequestLimit == DecoupledTANParameters.defaultMaxStatusRequests)
    }

    @Test func misalignedParametersYieldNothing() {
        let broken = FinTSSegment(type: "HITANS", version: 7, elements: ["1", "1", "0", FinTSDataElement(texts: ["J", "N", "0", "Unsinn", "x"])])
        #expect(DecoupledTANParameters.methods(in: broken).isEmpty)
    }

    /// Runs against the human-provided fixture once it exists.
    @Test(.enabled(if: Fixtures.exists(.dkb, "bpd-anonymous.fints")))
    func recordedBPDOffers942() throws {
        let response = try FinTSResponse(bytes: ScriptedFinTSTransport.decode(try Fixtures.data(.dkb, "bpd-anonymous.fints")))
        let bpd = try #require(FinTSBPD(response))
        let method = try #require(DecoupledTANParameters.method("942", in: bpd))
        #expect(method.isDecoupled)
        #expect([6, 7].contains(method.hktanVersion))
    }
}

@Suite struct DecoupledTANHandlerTests {
    let parameters = DecoupledTANParameters(securityFunction: "942", name: "DKB-App", hktanVersion: 7, isDecoupled: true, maxStatusRequests: 10, waitBeforeFirstStatus: .seconds(3), waitBetweenStatus: .seconds(1))

    /// Opens a dialog against FakeDKB with init SCA and returns what happened.
    func runInit(_ options: FakeDKB.Options, presenter: (any AuthChallengePresenter)?, clock: TestClock = TestClock()) async throws(ConnectorError) -> (FinTSUPD, [[String]]) {
        let bank = FakeDKB(options)
        let transport = bank.transport()
        let dialog = FinTSDialog(
            bank: DKBConnector.bank, credentials: FakeDKB.credentials, product: .unregistered,
            mechanism: .twoStep(securityFunction: "942", hktanVersion: 7, tanMedium: nil),
            transport: transport, systemID: FakeDKB.systemID,
            tanHandler: DecoupledTANHandler(parameters: parameters, presenter: presenter, clock: clock)
        )
        let upd = try await FinTSDialog.run(dialog) { d throws(ConnectorError) in await d.upd }
        return (upd, await transport.requestTypes)
    }

    @Test func pollsUntilApprovedAndKeepsUPDFromChallenge() async throws {
        let clock = TestClock()
        let presenter = WaitingPresenter()
        var options = FakeDKB.Options()
        options.initSCA = true
        options.pollsUntilApproval = 3
        let (upd, requests) = try await runInit(options, presenter: presenter, clock: clock)
        #expect(upd.accounts.count == 5, "UPD came with the 3956 answer and must survive the poll")
        #expect(requests == [["HKIDN", "HKVVB", "HKTAN"], ["HKTAN"], ["HKTAN"], ["HKTAN"], ["HKEND"]])
        #expect(clock.recorded == [.seconds(3), .seconds(1), .seconds(1)])
        #expect(presenter.presented == [.decoupled(message: "Bitte bestätige die Anmeldung in der DKB-App.", pollInterval: 1)])
    }

    @Test func confirmationPollsImmediately() async throws {
        let clock = TestClock()
        var options = FakeDKB.Options()
        options.initSCA = true
        options.pollsUntilApproval = 1
        _ = try await runInit(options, presenter: ConfirmingPresenter(), clock: clock)
        // The presenter task may or may not have run before the first wait; never more than one wait.
        #expect(clock.recorded.count <= 1)
    }

    @Test func timeoutAfterMaxStatusRequestsIsAuthFailed() async {
        var options = FakeDKB.Options()
        options.initSCA = true
        options.pollsUntilApproval = 1000
        let clock = TestClock()
        await #expect(throws: ConnectorError.authFailed) {
            _ = try await runInit(options, presenter: WaitingPresenter(), clock: clock)
        }
        #expect(clock.recorded.count == 10)
    }

    @Test func rejectionIsAuthFailed() async {
        var options = FakeDKB.Options()
        options.initSCA = true
        options.rejectApproval = true
        await #expect(throws: ConnectorError.authFailed) {
            _ = try await runInit(options, presenter: WaitingPresenter())
        }
    }

    @Test func userCancelIsCancelled() async {
        var options = FakeDKB.Options()
        options.initSCA = true
        options.pollsUntilApproval = 1000
        let big = DecoupledTANParameters(securityFunction: "942", name: "", hktanVersion: 7, isDecoupled: true, maxStatusRequests: 1000, waitBeforeFirstStatus: .seconds(1), waitBetweenStatus: .seconds(1))
        let bank = FakeDKB(options)
        let dialog = FinTSDialog(
            bank: DKBConnector.bank, credentials: FakeDKB.credentials, product: .unregistered,
            mechanism: .twoStep(securityFunction: "942", hktanVersion: 7, tanMedium: nil),
            transport: bank.transport(), systemID: FakeDKB.systemID,
            tanHandler: DecoupledTANHandler(parameters: big, presenter: CancellingPresenter(), clock: TestClock())
        )
        await #expect(throws: ConnectorError.cancelled) {
            try await FinTSDialog.run(dialog) { _ throws(ConnectorError) in 0 }
        }
    }

    @Test func withoutPresenterThrowsAuthRequired() async {
        var options = FakeDKB.Options()
        options.initSCA = true
        do {
            _ = try await runInit(options, presenter: nil)
            Issue.record("expected authRequired")
        } catch {
            #expect(error == .authRequired(.decoupled(message: "Bitte bestätige die Anmeldung in der DKB-App.", pollInterval: 1)))
        }
    }

    @Test func evaluatesPollAnswers() throws {
        func response(_ segments: [FinTSSegment]) throws -> FinTSResponse {
            try FinTSResponse(bytes: FinTSMessage.build(dialogID: "D", messageNumber: 1, segments: segments, security: nil))
        }
        let ok = FakeDKB.code("HIRMG", "0010", "OK")
        #expect(DecoupledTANHandler.evaluate(try response([ok, FakeDKB.code("HIRMS", "3956", "ausstehend", reference: 3)])) == .pending)
        #expect(DecoupledTANHandler.evaluate(try response([ok, FakeDKB.code("HIRMS", "0020", "ausgeführt", reference: 3)])) == .approved)
        #expect(DecoupledTANHandler.evaluate(try response([ok, FakeDKB.code("HIRMS", "3076", "keine SCA nötig", reference: 3)])) == .approved)
        #expect(DecoupledTANHandler.evaluate(try response([ok, FakeDKB.code("HIRMS", "9941", "abgelehnt", reference: 3)])) == .rejected("9941"))
        #expect(DecoupledTANHandler.evaluate(try response([ok])) == .pending)
    }
}
