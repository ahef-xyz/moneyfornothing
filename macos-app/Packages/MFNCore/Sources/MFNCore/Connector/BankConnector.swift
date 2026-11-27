import Foundation

/// The single interface between `MFNCore` and every bank.
///
/// Frozen with `PROTOCOL.md` Version 5. Do not change without a version bump and human approval.
///
/// Contract (checked by `MFNConformance`):
/// - Read-only. A connector never initiates payments or orders.
/// - Every thrown error is a `ConnectorError`.
/// - `transactions(for:since:)` returns only transactions whose `effectiveDate` is on or after
///   the bank day of `since` (pending transactions may be returned regardless).
/// - Fingerprints are stable across two runs over the same bank data.
/// - `cardStatements` is empty for non-card accounts, `securities` is empty for non-depot accounts.
/// - Raw bank data goes into `Transaction.rawJSON`; no categorisation in connectors.
public protocol BankConnector: Sendable {
    var id: ConnectorID { get }
    func accounts() async throws -> [Account]
    func balance(for account: Account) async throws -> Balance
    func transactions(for account: Account, since: Date?) async throws -> [Transaction]
    func cardStatements(for account: Account) async throws -> [CardStatement]
    func securities(for account: Account) async throws -> [SecurityPosition]
}

/// Shows an approval request to the user (sheet in the app) and returns the result.
///
/// Throws `ConnectorError.cancelled` if the user cancels.
public protocol AuthChallengePresenter: Sendable {
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse
}

public enum AuthChallenge: Hashable, Codable, Sendable {
    /// Approve in the bank's app (DKB decoupled TAN). The connector polls; the presenter returns
    /// `.confirmed` once the user says they approved, or the connector cancels the presentation
    /// itself after a successful poll.
    case decoupled(message: String, pollInterval: TimeInterval)
    /// Enter a code (Trade Republic 2FA, chipTAN). v12: `length` 0 = any length (YAXI does not
    /// always know it).
    case code(prompt: String, length: Int)
    /// Confirm a push notification on the phone (C24, easybank).
    case pushConfirm(message: String)
    /// Interactive login in a web view (scraping banks). The app shows a `WKWebView`, waits for
    /// `request.completion` and returns `.webSession` with the cookies of `request.cookieDomains`
    /// plus one pseudo-cookie per found `request.storageKeys` entry.
    case webLogin(WebLoginRequest)
    /// v12: pick one of the bank's options (TAN method, account). The presenter answers
    /// `.code(<option key>)`; the key must be one of `options`.
    case choice(prompt: String, options: [AuthOption])
    /// v12: enter a code read off an image (photoTAN, chipTAN optic as animated GIF). `length` 0 =
    /// any length. The presenter answers `.code`.
    case imageCode(prompt: String, length: Int, image: AuthImage)
    /// v12: enter a secret the bank asks for in a dialog (PIN, password), shown masked. `length` 0 =
    /// any length. The presenter answers `.code`.
    case secret(prompt: String, length: Int)
}

/// v12: one option of `AuthChallenge.choice`. Texts come from the bank: shown as plain text only.
public struct AuthOption: Hashable, Codable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var detail: String?

    public var id: String { key }

    public init(key: String, label: String, detail: String? = nil) {
        self.key = key
        self.label = label
        self.detail = detail
    }
}

/// v12: the image of `AuthChallenge.imageCode`. Bytes from the bank, decoded by the system image
/// frameworks only (PNG, JPEG, GIF), never interpreted otherwise.
public struct AuthImage: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Largest image the app shows (a photoTAN is a few kB, a chipTAN GIF well below this).
    public static let maximumBytes = 2_000_000

    public var mimeType: String
    public var data: Data
    /// Width on screen in millimetres when it matters (chipTAN optic: 62.5 mm so the TAN generator
    /// can read it), `nil` = natural size.
    public var physicalWidthMM: Double?

    public init(mimeType: String, data: Data, physicalWidthMM: Double? = nil) {
        self.mimeType = mimeType
        self.data = data
        self.physicalWidthMM = physicalWidthMM
    }

    public var description: String { "AuthImage(\(mimeType), \(data.count) bytes)" }
}

/// What the app needs to run a web login for a scraping connector.
public struct WebLoginRequest: Hashable, Codable, Sendable {
    public enum Completion: Hashable, Codable, Sendable {
        /// Done when the web view navigates to a URL starting with this prefix.
        case urlPrefix(String)
        /// Done when all of these names are present, each either as a cookie of `cookieDomains`
        /// or as a `storageKeys` entry with a value.
        case cookiesPresent([String])
    }

    /// A Web Storage entry the connector needs in addition to cookies (protocol v2), e.g. a
    /// bearer token a single-page app keeps in `sessionStorage`.
    ///
    /// The app reads the raw value on a page of `domain` once `completion` is met and returns it
    /// in `.webSession` as `SessionCookie(name: key, value: <raw>, domain: domain, isHTTPOnly: false)`.
    /// A missing key yields no entry. Interpreting the value is the connector's job. The value
    /// is a secret like a cookie: keychain only, never logged.
    public struct StorageKey: Hashable, Codable, Sendable {
        public enum Source: String, Hashable, Codable, Sendable {
            case sessionStorage
            case localStorage
            /// v3: value of a JavaScript expression evaluated on a page of `domain` after login,
            /// for values a web app keeps only in memory (e.g. `window.VeriBranch.Config.UniqueKey`).
            /// The expression comes from the connector, never from the page.
            case javaScript
        }

        /// Storage key, or for `.javaScript` the name the value is handed over under.
        public var key: String
        public var source: Source
        /// Host whose storage holds the key, e.g. `banking.c24.de` (Web Storage is per origin).
        public var domain: String
        /// Only for `.javaScript`: the expression to evaluate. Non-string results are JSON-encoded.
        public var expression: String?

        public init(key: String, source: Source, domain: String, expression: String? = nil) {
            self.key = key
            self.source = source
            self.domain = domain
            self.expression = expression
        }

        /// v3: hands over the value of `expression` under `key`.
        public static func javaScript(key: String, expression: String, domain: String) -> StorageKey {
            StorageKey(key: key, source: .javaScript, domain: domain, expression: expression)
        }
    }

    /// Start page of the web banking login.
    public var url: URL
    public var completion: Completion
    /// Only cookies of these domains (and their subdomains) are handed to the connector.
    public var cookieDomains: [String]
    /// Shown above the web view, e.g. "Bitte melde dich bei C24 an und bestätige in der App."
    public var message: String
    /// Web Storage entries to hand over next to the cookies. Empty for cookie-only logins (v1).
    public var storageKeys: [StorageKey]
    /// v4: headless login. If set, the app never shows the web view: it loads `url` in a hidden
    /// web view and runs `automation.script` with the connection's stored credentials. `nil` = the
    /// user logs in visibly in the web view (v1–v3 behaviour).
    public var automation: WebLoginAutomation?

    public init(
        url: URL,
        completion: Completion,
        cookieDomains: [String],
        message: String,
        storageKeys: [StorageKey] = [],
        automation: WebLoginAutomation? = nil
    ) {
        self.url = url
        self.completion = completion
        self.cookieDomains = cookieDomains
        self.message = message
        self.storageKeys = storageKeys
        self.automation = automation
    }

    private enum CodingKeys: String, CodingKey {
        case url, completion, cookieDomains, message, storageKeys, automation
    }

    /// Tolerates v1 JSON (persisted sync state) without `storageKeys`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        completion = try container.decode(Completion.self, forKey: .completion)
        cookieDomains = try container.decode([String].self, forKey: .cookieDomains)
        message = try container.decode(String.self, forKey: .message)
        storageKeys = try container.decodeIfPresent([StorageKey].self, forKey: .storageKeys) ?? []
        automation = try container.decodeIfPresent(WebLoginAutomation.self, forKey: .automation)
    }
}

/// v4: script that logs in without showing the web view (see `PROTOCOL.md` → Headless-Login).
///
/// The app loads `WebLoginRequest.url` in a hidden web view and, after **every** main-frame page
/// load, runs `script` as the body of an async JavaScript function (`callAsyncJavaScript`) in an
/// isolated content world. Arguments:
/// - `credentials`: object, field key → value (`ConnectorID.credentialFields`). Passed as an
///   argument, never spliced into source; the script never logs or stores them.
/// - `state`: what the previous run returned (`null` on the first run), so one script can drive a
///   login across page navigations.
/// - `url`: current page URL (string).
///
/// Bridge object `mfn` in the same content world:
/// - `mfn.status(message)`: text shown to the user, e.g. "Bitte in der C24-App bestätigen."
/// - `await mfn.requestCode(prompt, length)`: asks the user for a code (SMS/2FA), resolves with
///   the string, rejects with `"cancelled"`.
/// - v5 `mfn.showQRCode(payload, message)`: the app draws a QR code from `payload` itself; a new
///   call replaces it, `mfn.status`/`mfn.requestCode` hide it. `payload` is a login token.
///
/// Return value: any JSON value, kept as `state` for the next page load. Throwing an `Error` whose
/// message starts with `authFailed` ends the login with `ConnectorError.authFailed` (wrong
/// credentials, never retried); any other error with `.formatChanged(detail: "login script")`.
/// Completion is still detected via `WebLoginRequest.completion` (polled independently of the
/// script). Not completed within `timeout` → `ConnectorError.cancelled`.
public struct WebLoginAutomation: Hashable, Codable, Sendable {
    /// Body of an async JS function with parameters `credentials`, `state`, `url`. From the
    /// connector, never from the page.
    public var script: String
    /// Shown while the login runs, before the script sets its own status.
    public var message: String
    /// Seconds until the login is given up (includes waiting for app approval).
    public var timeout: TimeInterval

    public init(script: String, message: String, timeout: TimeInterval = 300) {
        self.script = script
        self.message = message
        self.timeout = timeout
    }
}

/// Protocol v2 name from `PROTOCOL.md`; nested in `WebLoginRequest` to keep the namespace small.
public typealias StorageKey = WebLoginRequest.StorageKey

public enum AuthResponse: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case confirmed
    /// Code entered by the user. Never logged; `description` is redacted.
    case code(String)
    /// Cookies captured from a completed web login, plus Web Storage entries as pseudo-cookies
    /// (see `WebLoginRequest.StorageKey`).
    case webSession([SessionCookie])

    public var description: String {
        switch self {
        case .confirmed: "confirmed"
        case .code: "code(<redacted>)"
        case let .webSession(cookies): "webSession(\(cookies.count) cookies)"
        }
    }

    public var debugDescription: String { description }
}

/// A cookie captured from `WKWebView`, transferable into `URLSession`, or a Web Storage entry
/// handed over as pseudo-cookie (`name` = storage key, `isHTTPOnly == false`). Value is redacted
/// in `description`; persist only via `Keychain`.
public struct SessionCookie: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool

    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil, isSecure: Bool = true, isHTTPOnly: Bool = true) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    public var description: String { "\(name)=<redacted>; domain=\(domain)" }
    public var debugDescription: String { description }
}

public enum ConnectorError: Error, Hashable, Codable, Sendable, CustomStringConvertible {
    case authRequired(AuthChallenge)
    case authFailed
    case sessionExpired
    case rateLimited(retryAfter: TimeInterval)
    case bankUnavailable
    case formatChanged(detail: String)
    case unsupportedAccount
    case cancelled

    public var description: String {
        switch self {
        case .authRequired: String(localized: "Freigabe erforderlich", bundle: .module)
        case .authFailed: String(localized: "Anmeldung fehlgeschlagen", bundle: .module)
        case .sessionExpired: String(localized: "Sitzung abgelaufen", bundle: .module)
        case let .rateLimited(retryAfter): Self.rateLimitedText(retryAfter: retryAfter)
        case .bankUnavailable: String(localized: "Bank nicht erreichbar", bundle: .module)
        case let .formatChanged(detail): String(localized: "Antwortformat geändert: \(detail)", bundle: .module)
        case .unsupportedAccount: String(localized: "Konto wird nicht unterstützt", bundle: .module)
        case .cancelled: String(localized: "Abgebrochen", bundle: .module)
        }
    }

    /// Short waits in seconds or minutes, long ones (quota pauses) as a time of day or a date.
    static func rateLimitedText(retryAfter: TimeInterval, now: Date = Date()) -> String {
        let seconds = max(0, Int(retryAfter))
        if seconds < 120 {
            return String(localized: "Zu viele Anfragen, erneut in \(seconds) s", bundle: .module)
        }
        if seconds < 3600 {
            let minutes = (seconds + 59) / 60
            return String(localized: "Zu viele Anfragen, erneut in \(minutes) min", bundle: .module)
        }
        let until = now.addingTimeInterval(retryAfter)
        let text = seconds < 24 * 3600
            ? until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale.autoupdatingCurrent))
            : until.formatted(Date.FormatStyle().day().month(.abbreviated).locale(Locale.autoupdatingCurrent))
        return String(localized: "Zu viele Anfragen, erneut ab \(text)", bundle: .module)
    }

    /// Errors after which MFN must not retry automatically (risk of locking the bank login).
    public var forbidsAutomaticRetry: Bool {
        switch self {
        case .authFailed, .authRequired, .cancelled, .formatChanged, .unsupportedAccount: true
        case .sessionExpired, .rateLimited, .bankUnavailable: false
        }
    }
}
