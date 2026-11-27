import Foundation
import MFNCore

/// The pages and calls of www.paypal.com MFN reads (`Fixtures/PayPal/endpoints.md`). All GET.
enum PayPalEndpoints {
    static let host = "www.paypal.com"
    /// HTML; carries the balances as JSON in a script element.
    static let summary = "/myaccount/summary"
    /// HTML; carries the CSRF token of the activity calls in its encoded page state.
    static let activities = "/myaccount/activities/"
    /// JSON: the activity list of a date range.
    static let filter = "/myaccount/activities/filter"

    /// Name the web view's user agent is handed over under (not a cookie, never sent as one).
    static let userAgentName = "mfn-user-agent"

    /// Days per list request. PayPal's page itself asks for a whole year at once, without paging.
    /// Many short ranges in a row do not work: after about a dozen quick list requests PayPal
    /// stopped answering the activity pages (first live sync, 2026-11-22).
    static let windowDays = 365
    /// How far back the first import reads: three requests.
    static let historyDays = 3 * 365 - 1
    /// Pause before every further list request of a run.
    static let pauseSeconds: TimeInterval = 2

    static func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// The list request of the page: its filter form, base64 encoded, as the one query item `q`.
    static func filterURL(from start: BankDay, to end: BankDay) -> URL? {
        let form = "free_text_search=&start_date=\(start.iso)&end_date=\(end.iso)&type=&status=&currency=&filter_id=&issuance_product_name=&asset_names=&asset_symbols="
        // Built by hand: `URLQueryItem` leaves `+` and `/` of base64 as they are, and `+` reads as a space.
        let encoded = Data(form.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
        return URL(string: "https://\(host)\(filter)?q=\(encoded)")
    }

    /// PayPal defends its login against automation (bot detection, reCAPTCHA, device
    /// fingerprint), so there is no headless login: the user logs in in a visible web view and
    /// MFN takes the session cookies. The web view's user agent comes along, so the requests
    /// that follow look like the browser that logged in.
    static func loginRequest() -> WebLoginRequest? {
        guard let url = URL(string: "https://\(host)/signin") else { return nil }
        return WebLoginRequest(
            url: url,
            completion: .urlPrefix("https://\(host)/myaccount"),
            cookieDomains: ["paypal.com"],
            message: String(localized: "Bitte melde dich bei PayPal an. MFN übernimmt danach die Sitzung und liest nur.", bundle: .module),
            storageKeys: [.javaScript(key: userAgentName, expression: "navigator.userAgent", domain: host)]
        )
    }

    static func headers(csrf: String? = nil) -> [String: String] {
        var headers = ["Referer": "https://\(host)\(activities)"]
        if let csrf {
            headers["Accept"] = "application/json"
            headers["X-Requested-With"] = "XMLHttpRequest"
            headers["x-csrf-token"] = csrf
        } else {
            headers["Accept"] = "text/html,application/xhtml+xml"
        }
        return headers
    }
}
