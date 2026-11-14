import Foundation
import MFNCore

/// Waits between status polls. Injected so tests never sleep for real.
public protocol DecoupledClock: Sendable {
    /// Throws `ConnectorError.cancelled` when the task is cancelled.
    func sleep(for duration: Duration) async throws(ConnectorError)
}

/// Real time via `Task.sleep`.
public struct SystemDecoupledClock: DecoupledClock {
    public init() {}

    public func sleep(for duration: Duration) async throws(ConnectorError) {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }
}

/// Decoupled TAN (DKB-App, security function `942`).
///
/// Flow after the bank answered a request with `HITAN` (order reference) + `3956`:
/// 1. Show `AuthChallenge.decoupled` via the presenter (in parallel to polling).
/// 2. Wait `waitBeforeFirstStatus`, then poll `HKTAN` process `S` every `waitBetweenStatus`.
///    The presenter returning `.confirmed` ("Ich habe freigegeben") triggers an immediate poll.
/// 3. `3956` = still pending → keep polling. `0020`/`3076`, or the business answer → done; the
///    poll response carries the result of the original request.
/// 4. More than `maxStatusRequests` polls, a rejection (`9xxx`) → `ConnectorError.authFailed`.
///    User cancels → `ConnectorError.cancelled`. No presenter → `ConnectorError.authRequired`.
///
/// Never retries anything on its own beyond the polls the bank allows.
public struct DecoupledTANHandler: FinTSTANHandler {
    public let parameters: DecoupledTANParameters
    public let presenter: (any AuthChallengePresenter)?
    public let clock: any DecoupledClock

    private static let log = Log.logger("fints-tan")

    public static let defaultMessage = "Bitte bestätige den Zugriff in der DKB-App."

    public init(parameters: DecoupledTANParameters, presenter: (any AuthChallengePresenter)?, clock: any DecoupledClock = SystemDecoupledClock()) {
        self.parameters = parameters
        self.presenter = presenter
        self.clock = clock
    }

    public func resolve(_ challenge: FinTSTANChallenge, dialog: FinTSDialog) async throws(ConnectorError) -> FinTSResponse {
        guard let orderReference = challenge.orderReference, !orderReference.isEmpty else {
            throw .formatChanged(detail: "FinTS: Freigabe ohne Auftragsreferenz (HITAN)")
        }
        let message = challenge.challengeText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? Self.defaultMessage
        let authChallenge = AuthChallenge.decoupled(message: message, pollInterval: parameters.waitBetweenStatus.seconds)
        guard let presenter else { throw .authRequired(authChallenge) }

        Self.log.info("Decoupled-Freigabe angefordert für \(challenge.requestTypes.joined(separator: ","), privacy: .public)")
        let signal = ConfirmationSignal()
        let presentation = Task {
            do {
                let response = try await presenter.present(authChallenge)
                await signal.finish(response == .confirmed ? .confirmed : .cancelled)
            } catch is CancellationError {
                // We cancelled the sheet after a successful poll.
            } catch {
                await signal.finish(.cancelled)
            }
        }
        defer { presentation.cancel() }

        let final = try await poll(orderReference: orderReference, dialog: dialog, signal: signal)
        Self.log.info("Decoupled-Freigabe erteilt")
        return Self.carryingDialogData(from: challenge, into: final)
    }

    private func poll(orderReference: String, dialog: FinTSDialog, signal: ConfirmationSignal) async throws(ConnectorError) -> FinTSResponse {
        var wait = parameters.waitBeforeFirstStatus
        for attempt in 1...parameters.statusRequestLimit {
            if await signal.state == .cancelled { throw .cancelled }
            if await signal.consumeConfirmation() == false {
                try await clock.sleep(for: wait)
            }
            if await signal.state == .cancelled { throw .cancelled }
            wait = parameters.waitBetweenStatus

            let response = try await dialog.send([FinTSSegments.tanStatusPoll(version: parameters.hktanVersion, orderReference: orderReference)])
            switch Self.evaluate(response) {
            case .approved:
                return response
            case .pending:
                Self.log.debug("Freigabe ausstehend (Abfrage \(attempt, privacy: .public))")
            case let .rejected(code):
                Self.log.error("Freigabe abgelehnt: \(code, privacy: .public)")
                throw .authFailed
            }
        }
        Self.log.error("Freigabe nicht innerhalb von \(parameters.statusRequestLimit, privacy: .public) Abfragen erteilt")
        throw .authFailed
    }

    enum PollOutcome: Equatable {
        case approved, pending, rejected(String)
    }

    /// `3956` = still pending; errors = rejected/expired; otherwise approved (`0020`, `3076`, data).
    static func evaluate(_ response: FinTSResponse) -> PollOutcome {
        if let error = response.errors.first { return .rejected(error.code) }
        if response.has(FinTSCode.decoupledPending) { return .pending }
        let approvedCodes: Set<String> = [FinTSCode.executed, "3076"]
        if response.allCodes.contains(where: { approvedCodes.contains($0.code) }) { return .approved }
        return response.segments.contains(where: { !envelopeTypes.contains($0.type) }) ? .approved : .pending
    }

    static let envelopeTypes: Set<String> = ["HNHBK", "HNHBS", "HNVSK", "HNVSD", "HNSHK", "HNSHA", "HIRMG", "HIRMS", "HITAN"]

    /// A challenge on dialog init (`HKIDN`): the bank may send BPD/UPD with the first answer only.
    /// Carry those segments into the final answer so `FinTSDialog.open` still finds them.
    static func carryingDialogData(from challenge: FinTSTANChallenge, into final: FinTSResponse) -> FinTSResponse {
        guard challenge.requestTypes.contains("HKIDN") else { return final }
        let present = Set(final.segments.map(\.type))
        let carried = challenge.response.segments.filter { !envelopeTypes.contains($0.type) && !present.contains($0.type) }
        guard !carried.isEmpty,
              let bytes = try? FinTSWire.encode(final.segments + carried),
              let merged = try? FinTSResponse(bytes: bytes)
        else { return final }
        return merged
    }
}

/// Shared state between the presentation task and the poll loop.
actor ConfirmationSignal {
    enum State: Equatable { case waiting, confirmed, cancelled }

    private(set) var state = State.waiting
    private var confirmationPending = false

    func finish(_ newState: State) {
        guard state == .waiting else { return }
        state = newState
        confirmationPending = newState == .confirmed
    }

    /// `true` once after the user confirmed: poll immediately instead of waiting.
    func consumeConfirmation() -> Bool {
        defer { confirmationPending = false }
        return confirmationPending
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

private extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}
