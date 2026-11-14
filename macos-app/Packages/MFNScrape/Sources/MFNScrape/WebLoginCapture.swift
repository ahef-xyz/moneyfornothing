import Foundation
import MFNCore

/// The web-view-independent part of an interactive web login (`AuthChallenge.webLogin`).
///
/// The app owns the `WKWebView`; this type decides what to read from it, when the login is
/// complete and what goes back to the connector. Keeping that here makes it testable without
/// WebKit:
///
/// 1. After every navigation (and while polling) the app runs `storageScript(forPage:)` in the
///    web view and passes the result to `recordStorage(scriptResult:page:)`.
/// 2. `isComplete(currentURL:cookies:)` evaluates `WebLoginRequest.completion`; a
///    `.cookiesPresent` name may be satisfied by a cookie or by a storage entry.
/// 3. `session(cookies:)` is the payload of `AuthResponse.webSession`.
///
/// Storage values are secrets like cookies: they are never part of `description`, mirrors or logs.
public struct WebLoginCapture: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let request: WebLoginRequest
    private var storage: [StorageKey: String] = [:]

    public init(request: WebLoginRequest) {
        self.request = request
    }

    // MARK: Web Storage

    /// Storage keys readable on `page` (Web Storage is per origin, so the host must match exactly).
    public func storageKeys(forPage page: URL?) -> [StorageKey] {
        guard let host = page?.host().map(Self.normalize), !host.isEmpty else { return [] }
        return request.storageKeys.filter { Self.normalize($0.domain) == host }
    }

    /// JavaScript for `WKWebView.evaluateJavaScript` that reads this page's storage keys via
    /// `sessionStorage.getItem` / `localStorage.getItem`, or evaluates a `.javaScript` key's
    /// expression (v3). Evaluates to a JSON object string (index → value; non-string results
    /// JSON-encoded); missing or failing keys are left out. `nil` if no key belongs to `page`.
    public func storageScript(forPage page: URL?) -> String? {
        let keys = storageKeys(forPage: page)
        guard !keys.isEmpty else { return nil }
        var readers: [String] = []
        for key in keys {
            switch key.source {
            case .sessionStorage, .localStorage:
                // Storage keys are embedded as JSON literals, never concatenated into code.
                guard let name = Self.jsonLiteral(key.key) else { return nil }
                readers.append("function(){return window.\(key.source.rawValue).getItem(\(name));}")
            case .javaScript:
                // The expression is code by design; it comes from the connector, not the page.
                guard let expression = key.expression, !expression.isEmpty else { readers.append("function(){return null;}"); continue }
                readers.append("function(){return (\(expression));}")
            }
        }
        return "(function(){var r=[\(readers.joined(separator: ","))],o={};for(var i=0;i<r.length;i++){try{var v=r[i]();if(typeof v==='string')o[i]=v;else if(typeof v==='number'||typeof v==='boolean')o[i]=String(v);else if(v!==null&&v!==undefined)o[i]=JSON.stringify(v);}catch(e){}}return JSON.stringify(o);})()"
    }

    private static func jsonLiteral(_ string: String) -> String? {
        guard let data = try? JSONEncoder().encode(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Records the result of `storageScript(forPage:)` for the same `page`. A key the page no
    /// longer has (or an unreadable result) drops its entry – the latest state of the page wins.
    public mutating func recordStorage(scriptResult: String?, page: URL?) {
        let keys = storageKeys(forPage: page)
        guard !keys.isEmpty else { return }
        let values = scriptResult.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        for (index, key) in keys.enumerated() {
            if let value = values[String(index)], !value.isEmpty {
                storage[key] = value
            } else {
                storage[key] = nil
            }
        }
    }

    /// `true` while a storage key of `page` has no value yet (the app may wait briefly for a
    /// single-page app to write it after a `.urlPrefix` completion).
    public func isMissingStorage(forPage page: URL?) -> Bool {
        storageKeys(forPage: page).contains { storage[$0] == nil }
    }

    /// Found storage entries as pseudo-cookies, in the order of `request.storageKeys`.
    public var storageEntries: [SessionCookie] {
        request.storageKeys.compactMap { key in
            storage[key].map { SessionCookie(name: key.key, value: $0, domain: key.domain, isHTTPOnly: false) }
        }
    }

    // MARK: Completion and result

    /// Whether `request.completion` is met. `cookies` are all cookies of the web view's store.
    public func isComplete(currentURL: URL?, cookies: [SessionCookie]) -> Bool {
        switch request.completion {
        case let .urlPrefix(prefix):
            return currentURL?.absoluteString.hasPrefix(prefix) ?? false
        case let .cookiesPresent(required):
            let names = Set(session(cookies: cookies).map(\.name))
            return required.allSatisfy(names.contains)
        }
    }

    /// Payload for `AuthResponse.webSession`: the cookies of `request.cookieDomains` (including
    /// HttpOnly ones) followed by the found storage entries. A cookie with the name and domain
    /// of a found storage entry is dropped so the connector sees exactly one value per name.
    public func session(cookies: [SessionCookie]) -> [SessionCookie] {
        let entries = storageEntries
        let kept = WebLoginSession.filter(cookies, domains: request.cookieDomains).filter { cookie in
            !entries.contains { $0.name == cookie.name && Self.normalize($0.domain) == Self.normalize(cookie.domain) }
        }
        return kept + entries
    }

    /// Converts a cookie from `WKHTTPCookieStore` without losing HttpOnly/Secure/expiry.
    public static func sessionCookie(_ cookie: HTTPCookie) -> SessionCookie {
        SessionCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path.isEmpty ? "/" : cookie.path,
            expires: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly
        )
    }

    static func normalize(_ domain: String) -> String {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: Redaction

    public var description: String {
        "WebLoginCapture(\(storage.count)/\(request.storageKeys.count) storage entries, values redacted)"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
