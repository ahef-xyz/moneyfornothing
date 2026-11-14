import Foundation
import MFNCore

/// The web-view-independent part of a headless web login (`WebLoginRequest.automation`, protocol v4).
///
/// The app owns a hidden `WKWebView` and moves events between WebKit and this state machine;
/// what to run, which results count, how errors map and when the login is given up is decided
/// here, so it is testable without WebKit:
///
/// 1. `navigationStarted()` on every main-frame navigation: a script still running on the old
///    page is outdated, its result (usually an error because the page went away) is ignored.
/// 2. `pageLoaded()` after every main-frame load returns a `Run`; the app calls
///    `callAsyncJavaScript(automation.script, arguments: arguments(for:credentials:url:), in: contentWorld)`
///    and reports back with `scriptSucceeded(_:result:)` / `scriptFailed(_:message:)`.
/// 3. Bridge messages (`mfn.status`, `mfn.requestCode`) go through `handle(bridgeMessage:)`.
/// 4. Completion is detected by `WebLoginCapture` (polled independently); `checkTimeout(now:)`
///    gives up after `automation.timeout` with `.cancelled`.
///
/// Credentials only ever travel as the `credentials` argument, never into script source. The
/// script's state may hold tokens: neither credentials nor state appear in `description`,
/// mirrors or logs.
public struct HeadlessLogin: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Phase: Hashable, Sendable {
        /// Waiting for the first page.
        case starting
        /// The script runs or waits for the next page / completion.
        case running
        /// The script awaits `mfn.requestCode`; the UI shows a code field.
        case waitingForCode(prompt: String, length: Int)
        /// `completion` met; the session went back to the connector.
        case finished
        /// Ended with this error (see `PROTOCOL.md` → Headless-Login).
        case failed(ConnectorError)

        public var isOver: Bool {
            switch self {
            case .finished, .failed: true
            case .starting, .running, .waitingForCode: false
            }
        }
    }

    /// One script run on one page load.
    public struct Run: Hashable, Sendable {
        public let generation: Int
    }

    /// v5: QR code the app draws itself (`mfn.showQRCode`). `payload` is a login token of the
    /// bank: never logged, redacted in `description`.
    public struct QRCode: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let payload: String
        public let message: String
        public var description: String { "QRCode(<redacted>)" }
        public var debugDescription: String { description }
    }

    /// What a bridge message asks the app to do.
    public enum BridgeAction: Equatable, Sendable {
        /// Reply `nil` (status updated, see `status`).
        case reply
        /// Show the code field; reply later with the code or reject with `"cancelled"`.
        case askForCode(prompt: String, length: Int)
        /// Reject the call with this message (malformed message, login already over).
        case reject(String)
    }

    /// Name of the script message handler and of the bridge object.
    public static let handlerName = "mfn"
    /// Name of the isolated content world the script and the bridge run in.
    public static let contentWorldName = "xyz.ahef.mfn.login"
    /// Error message a cancelled `mfn.requestCode` rejects with.
    public static let cancelledMessage = "cancelled"
    /// Longest status text shown (the text comes from the connector's script).
    static let maximumStatusLength = 200

    /// User script injected into `contentWorldName` only (all frames: no; main frame only). The
    /// page's own scripts cannot see `mfn` nor the message handler.
    public static let bridgeSource = """
    (function(){
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!h) { return; }
      window.\(handlerName) = Object.freeze({
        status: function(text) { h.postMessage({ op: "status", text: String(text) }); },
        requestCode: function(prompt, length) {
          return h.postMessage({ op: "requestCode", prompt: String(prompt), length: Number(length) || 0 });
        },
        showQRCode: function(payload, message) {
          h.postMessage({ op: "showQRCode", payload: String(payload), message: message == null ? "" : String(message) });
        }
      });
    })();
    """

    public let automation: WebLoginAutomation
    public let deadline: Date
    public private(set) var phase: Phase = .starting
    /// Status line for the UI: `automation.message` until the script calls `mfn.status`.
    public private(set) var status: String
    /// v5: QR code to show (`mfn.showQRCode`), until `mfn.status` or `mfn.requestCode` replaces it.
    public private(set) var qrCode: QRCode?
    /// Longest QR payload accepted (QR version 40 holds ~2.9 kB in byte mode).
    static let maximumQRPayloadLength = 2048
    private var generation = 0
    /// JSON of the previous run's return value (`nil` = `null`).
    private var state: Data?

    public init(automation: WebLoginAutomation, start: Date = Date()) {
        self.automation = automation
        self.status = automation.message
        self.deadline = start.addingTimeInterval(max(automation.timeout, 1))
    }

    // MARK: Page loads and script runs

    /// A main-frame navigation started: results of runs on the old page no longer count.
    public mutating func navigationStarted() {
        generation += 1
    }

    /// A main-frame page finished loading. Returns the run to start, or `nil` once the login is over.
    public mutating func pageLoaded() -> Run? {
        guard !phase.isOver else { return nil }
        generation += 1
        if phase == .starting { phase = .running }
        return Run(generation: generation)
    }

    public func isCurrent(_ run: Run) -> Bool {
        run.generation == generation && !phase.isOver
    }

    /// Arguments for `callAsyncJavaScript`: `credentials` (field key → value), `state` (previous
    /// return value or `NSNull`), `url` (current page). Never log the result.
    public func arguments(for run: Run, credentials: BankCredentials, url: URL?) -> [String: Any] {
        [
            "credentials": credentials.values,
            "state": stateValue,
            "url": url?.absoluteString ?? "",
        ]
    }

    /// The previous run's return value as a WebKit-compatible object (`NSNull` if none).
    var stateValue: Any {
        guard let state, let value = try? JSONSerialization.jsonObject(with: state, options: .fragmentsAllowed) else { return NSNull() }
        return value
    }

    /// The script returned `result` (WebKit types: string, number, array, dictionary, `NSNull`, or
    /// `nil` for `undefined`). Kept as `state` for the next page load. Outdated runs are ignored.
    public mutating func scriptSucceeded(_ run: Run, result: Any?) {
        guard isCurrent(run) else { return }
        if let result, !(result is NSNull), JSONSerialization.isValidJSONObject([result]) {
            state = try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
        } else {
            state = nil
        }
    }

    /// The script threw (or the call failed) with `message`. Outdated runs (the page navigated
    /// away) are ignored; otherwise the login ends. Returns the error to hand to the connector.
    @discardableResult
    public mutating func scriptFailed(_ run: Run, message: String?) -> ConnectorError? {
        guard isCurrent(run) else { return nil }
        let error = Self.error(forScriptMessage: message)
        phase = .failed(error)
        return error
    }

    /// `PROTOCOL.md`: a message starting with `authFailed` → `.authFailed` (never retried);
    /// anything else → `.formatChanged(detail: "login script")` without the message text.
    /// WebKit prefixes exceptions with their type (`Error: authFailed …`), which is tolerated.
    public static func error(forScriptMessage message: String?) -> ConnectorError {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .formatChanged(detail: "login script") }
        for prefix in ["Uncaught ", "(in promise) "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if let colon = text.range(of: ": "), text[..<colon.lowerBound].allSatisfy({ $0.isLetter }), text[..<colon.lowerBound].hasSuffix("Error") {
            text = String(text[colon.upperBound...])
        }
        return text.hasPrefix("authFailed") ? .authFailed : .formatChanged(detail: "login script")
    }

    /// Reason text of a failed script that may be logged publicly: only the connector's own short
    /// messages (letters, spaces, basic punctuation, ≤ 120 characters, no digits or `@`).
    /// Anything that could carry page or user data yields `nil`.
    public static func loggableReason(forScriptMessage message: String?) -> String? {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for prefix in ["Uncaught ", "(in promise) ", "Error: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        let allowed = CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: ":,.()'-/"))
        guard text.count <= 120, text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return text
    }

    // MARK: Bridge

    /// Handles a message from the bridge (`WKScriptMessage.body`).
    public mutating func handle(bridgeMessage body: Any) -> BridgeAction {
        guard !phase.isOver else { return .reject(Self.cancelledMessage) }
        guard let message = body as? [String: Any], let op = message["op"] as? String else { return .reject("invalid message") }
        switch op {
        case "status":
            guard let text = message["text"] as? String else { return .reject("invalid message") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { status = String(trimmed.prefix(Self.maximumStatusLength)) }
            qrCode = nil
            return .reply
        case "showQRCode":
            guard let payload = message["payload"] as? String, !payload.isEmpty,
                  payload.count <= Self.maximumQRPayloadLength else { return .reject("invalid message") }
            let text = ((message["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            qrCode = QRCode(payload: payload, message: String(text.prefix(Self.maximumStatusLength)))
            if !text.isEmpty { status = String(text.prefix(Self.maximumStatusLength)) }
            return .reply
        case "requestCode":
            let prompt = (message["prompt"] as? String).map { String($0.prefix(Self.maximumStatusLength)) } ?? ""
            let length = (message["length"] as? NSNumber)?.intValue ?? 0
            let clamped = (0...12).contains(length) ? length : 0
            qrCode = nil
            phase = .waitingForCode(prompt: prompt.isEmpty ? "Bitte den Code eingeben." : prompt, length: clamped)
            return .askForCode(prompt: prompt, length: clamped)
        default:
            return .reject("invalid message")
        }
    }

    /// Whether `code` may be sent for the open code request (digits only, exact length if given).
    public func accepts(code: String) -> Bool {
        guard case let .waitingForCode(_, length) = phase else { return false }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        return length == 0 || trimmed.count == length
    }

    /// The code was answered (sent or cancelled): back to running.
    public mutating func codeAnswered() {
        if case .waitingForCode = phase { phase = .running }
    }

    // MARK: End

    /// `completion` met.
    public mutating func finish() {
        guard !phase.isOver else { return }
        phase = .finished
    }

    /// Ends the login with `error` (user cancelled, lock), unless it is already over.
    public mutating func fail(_ error: ConnectorError) {
        guard !phase.isOver else { return }
        phase = .failed(error)
    }

    /// `.cancelled` once `deadline` passed (and the login is not over yet).
    public mutating func checkTimeout(now: Date) -> ConnectorError? {
        guard !phase.isOver, now >= deadline else { return nil }
        phase = .failed(.cancelled)
        return .cancelled
    }

    /// Fraction of the time budget used, for a progress indicator.
    public func elapsedFraction(now: Date) -> Double {
        let total = max(automation.timeout, 1)
        return min(max(1 - deadline.timeIntervalSince(now) / total, 0), 1)
    }

    // MARK: Credentials

    /// Stored credentials usable for `connector`: complete per `credentialFields`, otherwise `nil`
    /// (the app asks for them). Connectors without fields (mock) need none.
    public static func usableCredentials(_ stored: BankCredentials?, for connector: ConnectorID) -> BankCredentials? {
        let credentials = stored ?? BankCredentials()
        return credentials.isComplete(for: connector) ? credentials : nil
    }

    // MARK: Redaction

    public var description: String { "HeadlessLogin(\(phase.redactedName), state redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension HeadlessLogin.Phase {
    var redactedName: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .waitingForCode: "waitingForCode"
        case .finished: "finished"
        case let .failed(error): "failed(\(error.description))"
        }
    }
}
