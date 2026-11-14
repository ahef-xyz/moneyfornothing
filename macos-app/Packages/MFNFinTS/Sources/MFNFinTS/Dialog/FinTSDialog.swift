import Foundation
import MFNCore

/// The bank asked for a TAN / approval (codes `0030`, `3955`, `3956`).
public struct FinTSTANChallenge: Sendable {
    public let response: FinTSResponse
    public let codes: [FinTSReturnCode]
    /// `HITAN` element 3 (Auftragsreferenz): needed for polling / submitting the TAN.
    public let orderReference: String?
    /// `HITAN` element 4: text to show the user.
    public let challengeText: String?
    /// Request segment types of the message that triggered the challenge.
    public let requestTypes: [String]

    public var isDecoupled: Bool { codes.contains { $0.code == FinTSCode.decoupledPending } }
}

/// Resolves TAN challenges, e.g. the DKB decoupled flow (`TAN/Decoupled*`): present the
/// approval via `AuthChallengePresenter`, poll with `HKTAN` process S through `dialog.send`,
/// and return the bank's final answer to the original request.
public protocol FinTSTANHandler: Sendable {
    func resolve(_ challenge: FinTSTANChallenge, dialog: FinTSDialog) async throws(ConnectorError) -> FinTSResponse
}

/// One FinTS dialog (init → business transactions → end).
///
/// Use `FinTSDialog.run(…)`: it guarantees `HKEND`, also when the body throws – banks block
/// users after a few dialogs that were never ended.
public actor FinTSDialog {
    public let bank: FinTSBank
    public let product: FinTSProduct
    public let mechanism: FinTSTANMechanism
    public private(set) var systemID: String
    public private(set) var bpd: FinTSBPD
    public private(set) var upd: FinTSUPD
    public private(set) var dialogID = "0"
    public private(set) var isOpen = false

    private let credentials: FinTSCredentials
    private let transport: any FinTSTransport
    private let tanHandler: (any FinTSTANHandler)?
    private let now: @Sendable () -> Date
    private var messageNumber = 1

    private static let log = Log.logger("fints")
    /// Upper bound for 3040 paging, protects against a bank returning the same touchdown forever.
    public static let maximumPages = 200

    public init(
        bank: FinTSBank,
        credentials: FinTSCredentials,
        product: FinTSProduct,
        mechanism: FinTSTANMechanism,
        transport: any FinTSTransport,
        systemID: String = "0",
        bpd: FinTSBPD = .empty,
        upd: FinTSUPD = .empty,
        tanHandler: (any FinTSTANHandler)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bank = bank
        self.credentials = credentials
        self.product = product
        self.mechanism = mechanism
        self.transport = transport
        self.systemID = systemID
        self.bpd = bpd
        self.upd = upd
        self.tanHandler = tanHandler
        self.now = now
    }

    /// Opens a dialog, runs `body`, and always ends the dialog.
    public static func run<T: Sendable>(
        _ dialog: FinTSDialog,
        synchronize: Bool = false,
        _ body: (FinTSDialog) async throws(ConnectorError) -> T
    ) async throws(ConnectorError) -> T {
        do {
            _ = try await dialog.open(synchronize: synchronize)
            let result = try await body(dialog)
            await dialog.close()
            return result
        } catch {
            await dialog.close()
            throw error
        }
    }

    // MARK: - Dialog

    /// Dialog initialisation: `HKIDN`, `HKVVB`, `HKTAN` process 4 (PSD2, two-step only), optionally
    /// `HKSYN` to obtain a customer system ID (needed once per user; persist it). One-step (999)
    /// sends no `HKTAN`, like python-fints, which ING accepts.
    @discardableResult
    public func open(synchronize: Bool = false) async throws(ConnectorError) -> FinTSResponse {
        var segments = [
            FinTSSegments.identification(bank: bank, customerID: credentials.effectiveCustomerID, systemID: synchronize ? "0" : systemID),
            FinTSSegments.processingPreparation(bpdVersion: bpd.version, updVersion: upd.version, product: product),
        ]
        if case .twoStep = mechanism {
            segments.append(FinTSSegments.tanProcess4(version: mechanism.hktanVersion, referenceSegment: "HKIDN", tanMedium: tanMedium))
        }
        if synchronize { segments.append(FinTSSegments.synchronization()) }
        isOpen = true
        let response = try await send(segments, addTANSegment: false)
        if let newBPD = FinTSBPD(response) { bpd = newBPD }
        if let newUPD = FinTSUPD(response) { upd = newUPD }
        if synchronize, let id = response.segment("HISYN")?[0].first {
            systemID = id
        }
        return response
    }

    /// Sends business segments. Adds `HKTAN` process 4 when the BPD says the first segment
    /// needs a TAN (two-step). TAN challenges go to the `tanHandler`.
    ///
    /// `acceptedSegmentErrors`: segment-level error codes the caller handles itself (e.g. ING
    /// `9010` = account without transactions). Banks report them together with `HIRMG 9050`
    /// ("partially faulty"); without this list that message-level error throws `formatChanged`.
    public func send(_ segments: [FinTSSegment], acceptedSegmentErrors: Set<String> = []) async throws(ConnectorError) -> FinTSResponse {
        try await send(segments, addTANSegment: true, acceptedSegmentErrors: acceptedSegmentErrors)
    }

    /// Repeats a request while the bank answers `3040` (more data), passing the touchdown point.
    public func sendAllPages(
        acceptedSegmentErrors: Set<String> = [],
        _ makeSegment: (_ touchdown: String?) -> FinTSSegment
    ) async throws(ConnectorError) -> [FinTSResponse] {
        var responses: [FinTSResponse] = []
        var touchdown: String?
        for _ in 0..<Self.maximumPages {
            let response = try await send([makeSegment(touchdown)], acceptedSegmentErrors: acceptedSegmentErrors)
            responses.append(response)
            // The business segment is always number 3 in a secured message (HNSHK is 2).
            guard let next = response.touchdown(for: 3) ?? response.segmentCodes.first(where: { $0.code == FinTSCode.touchdown })?.parameters.first else {
                return responses
            }
            guard next != touchdown else { throw .formatChanged(detail: "FinTS: Aufsetzpunkt wiederholt sich") }
            touchdown = next
        }
        throw .formatChanged(detail: "FinTS: mehr als \(Self.maximumPages) Seiten")
    }

    /// Ends the dialog with `HKEND`. Never throws: failures are logged, the dialog counts as closed.
    public func close() async {
        guard isOpen else { return }
        isOpen = false
        guard dialogID != "0" else { return }
        do {
            let message = try FinTSMessage.build(dialogID: dialogID, messageNumber: messageNumber, segments: [FinTSSegments.dialogEnd(dialogID: dialogID)], security: security(tan: nil), now: now())
            messageNumber += 1
            _ = try await transport.exchange(message)
        } catch {
            Self.log.error("HKEND fehlgeschlagen: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internals

    private var tanMedium: String? {
        if case let .twoStep(_, _, medium) = mechanism { return medium }
        return nil
    }

    private func security(tan: String?) -> FinTSMessage.Security {
        FinTSMessage.Security(bank: bank, credentials: credentials, systemID: systemID, mechanism: mechanism, tan: tan)
    }

    private func send(_ segments: [FinTSSegment], addTANSegment: Bool, acceptedSegmentErrors: Set<String> = []) async throws(ConnectorError) -> FinTSResponse {
        guard isOpen else { throw .formatChanged(detail: "FinTS-Dialog ist nicht offen") }
        var segments = segments
        if addTANSegment, case .twoStep = mechanism, let first = segments.first, first.type != "HKTAN", bpd.tanRequired[first.type] == true {
            segments.append(FinTSSegments.tanProcess4(version: mechanism.hktanVersion, referenceSegment: first.type, tanMedium: tanMedium))
        }
        let requestTypes = segments.map(\.type)

        let bytes: [UInt8]
        do {
            bytes = try FinTSMessage.build(dialogID: dialogID, messageNumber: messageNumber, segments: segments, security: security(tan: nil), now: now())
        } catch {
            throw .formatChanged(detail: "FinTS-Nachricht nicht kodierbar: \(error)")
        }
        messageNumber += 1
        let answer = try await transport.exchange(bytes)

        let response: FinTSResponse
        do {
            response = try FinTSResponse(bytes: answer)
        } catch {
            throw .formatChanged(detail: "FinTS-Antwort nicht lesbar: \(error)")
        }
        if let id = response.dialogID, dialogID == "0" { dialogID = id }
        Self.log.info("FinTS \(requestTypes.joined(separator: ","), privacy: .public) → \(response.allCodes.map(\.code).joined(separator: ","), privacy: .public)")

        try Self.checkMessageErrors(response, acceptedSegmentErrors: acceptedSegmentErrors)

        let tanCodes = response.allCodes.filter { [FinTSCode.tanRequired, FinTSCode.scaRequired, FinTSCode.decoupledPending].contains($0.code) }
        if !tanCodes.isEmpty, !requestTypes.contains("HKEND") {
            let hitan = response.segment("HITAN")
            let challenge = FinTSTANChallenge(
                response: response,
                codes: tanCodes,
                orderReference: hitan?[2].first,
                challengeText: hitan?[3].first,
                requestTypes: requestTypes
            )
            // Polls (HKTAN S) are sent by the handler itself; do not recurse into it.
            if requestTypes.first == "HKTAN" { return response }
            guard let tanHandler else {
                throw .authRequired(.decoupled(message: challenge.challengeText ?? "Bitte bestätige den Zugriff in der App deiner Bank.", pollInterval: 2))
            }
            return try await tanHandler.resolve(challenge, dialog: self)
        }
        return response
    }

    /// Message-level errors (`HIRMG 9xxx`) end the conversation; segment-level errors are left
    /// to the connector (e.g. ING `9010` = account without transactions).
    /// `acceptedSegmentErrors`: if every segment-level error is in this set and the message-level
    /// error is only the generic `9050`, the response is returned for the caller to inspect.
    static func checkMessageErrors(_ response: FinTSResponse, acceptedSegmentErrors: Set<String> = []) throws(ConnectorError) {
        guard let error = response.messageCodes.first(where: \.isError) else { return }
        let allErrors = response.errors.map(\.code)
        if allErrors.contains(where: { $0 == FinTSCode.pinWrong || $0 == FinTSCode.pinBlocked || $0.hasPrefix("993") || $0 == "9931" }) {
            throw .authFailed
        }
        let segmentErrors = response.segmentCodes.filter(\.isError).map(\.code)
        if !acceptedSegmentErrors.isEmpty, !segmentErrors.isEmpty,
           segmentErrors.allSatisfy(acceptedSegmentErrors.contains),
           response.messageCodes.filter(\.isError).allSatisfy({ $0.code == FinTSCode.partiallyFaulty }) {
            return
        }
        // 9800/9050 only say "dialog aborted"/"partly faulty"; the reason is the next error
        // (e.g. 9078 product not registered, 9400 no anonymous dialog). Report that one.
        let generic: Set<String> = ["9800", FinTSCode.partiallyFaulty]
        let reason = response.errors.first { !generic.contains($0.code) } ?? error
        log.error("FinTS abgelehnt: \(response.errors.map(\.code).joined(separator: ", "), privacy: .public)")
        // The detail is logged publicly (SyncEngine). Message-level texts (HIRMG) are generic;
        // segment-level texts (HIRMS) can name accounts, so those carry the code only.
        if response.messageCodes.contains(reason) {
            throw .formatChanged(detail: "FinTS \(reason.code): \(reason.text)")
        }
        throw .formatChanged(detail: "FinTS \(reason.code)")
    }

    // MARK: - Anonymous BPD

    /// Fetches the BPD anonymously (no credentials): HKIDN 9999999999 + HKVVB, then HKEND.
    public static func fetchBPD(bank: FinTSBank, product: FinTSProduct, transport: any FinTSTransport, now: Date = Date()) async throws(ConnectorError) -> FinTSBPD {
        let initSegments = [
            FinTSSegments.identification(bank: bank, customerID: "", systemID: "0", anonymous: true),
            FinTSSegments.processingPreparation(bpdVersion: 0, updVersion: 0, product: product),
        ]
        let response: FinTSResponse
        do {
            let message = try FinTSMessage.build(dialogID: "0", messageNumber: 1, segments: initSegments, security: nil, now: now)
            response = try FinTSResponse(bytes: try await transport.exchange(message))
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw .formatChanged(detail: "FinTS anonym: \(error)")
        }
        try checkMessageErrors(response)
        if let id = response.dialogID, id != "0" {
            if let end = try? FinTSMessage.build(dialogID: id, messageNumber: 2, segments: [FinTSSegments.dialogEnd(dialogID: id)], security: nil, now: now) {
                _ = try? await transport.exchange(end)
            }
        }
        guard let bpd = FinTSBPD(response) else { throw .formatChanged(detail: "FinTS: keine BPD in der anonymen Antwort") }
        return bpd
    }
}
