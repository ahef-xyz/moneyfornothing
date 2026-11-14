import Foundation
import MFNCore

/// Web-banking endpoints of easybank (ex Barclays), from `Fixtures/Easybank/endpoints.md`.
///
/// All calls are `POST` with a JSON body; the session is the cookie set of the web login
/// (`FedAuth`, `ASP.NET_SessionId`, `XSRF-TOKEN`, …). Read-only: no payment, limit or
/// instalment endpoint is used or even listed here.
enum EasybankEndpoints {
    static let host = "banking.easybank.de"
    static let base = URL(string: "https://banking.easybank.de")

    /// Overview: card accounts (`AccountListResponse`) and recent dashboard transactions.
    /// Request body not recorded; `{}` (see STATUS.md, easybank).
    static let retailLanding = "/services/flow/RetailLanding"
    /// Open a card account: statement summary + current-cycle and pending transactions, **no OTP**.
    /// Body: `{"Account": <account object from the list>}` (`account-transaction-history-request.json`).
    static let accountTransactionHistory = "/services/flow/AccountTransactionHistory"
    /// Full history (paged, 50). First call per session answers `OTPRequired: true`.
    /// Not used yet: the `SendOTP` request and paging are not recorded (STATUS.md).
    static let getTransactions = "/call/directive/TransactionViewDirective/GetTransactions"
    static let sendOTP = "/call/directive/VbOtpboxDirective/SendOTP"

    static func url(_ path: String) -> URL? {
        URL(string: path, relativeTo: base)?.absoluteURL
    }

    /// Pseudo-cookie names for values the web app keeps only in memory
    /// (`window.VeriBranch.Config`), handed over by the web login (protocol v3, `.javaScript`).
    /// The app sends them as headers `UniqueKey` / `pcid` on every call; without them the bank
    /// answers `Result.IsSuccess = false`. They are never sent as cookies.
    static let uniqueKeyName = "mfn.easybank.UniqueKey"
    static let pcidName = "mfn.easybank.PCID"
    static let appValueNames: Set<String> = [uniqueKeyName, pcidName]

    /// Headless login (protocol v4): the app fills the login form with the stored username and
    /// password (`EasybankLoginScript`); the user approves in the easybank app (or enters an SMS code).
    /// `FedAuth` is the cookie the bank sets after a completed login (`endpoints.md`, cookie names);
    /// the login is complete once the app has also published its `UniqueKey`. The bank ends a
    /// session after 5 min of inactivity (PSD2); an expired session simply means a new headless login.
    static func loginRequest() -> WebLoginRequest? {
        guard let url = URL(string: "https://banking.easybank.de/") else { return nil }
        return WebLoginRequest(
            url: url,
            completion: .cookiesPresent(["FedAuth", uniqueKeyName]),
            cookieDomains: ["easybank.de"],
            message: "Bitte melde dich bei easybank an und gib den SMS-Code ein.",
            storageKeys: [
                .javaScript(key: uniqueKeyName, expression: "window.VeriBranch && VeriBranch.Config && VeriBranch.Config.UniqueKey", domain: host),
                .javaScript(key: pcidName, expression: "window.VeriBranch && VeriBranch.Config && VeriBranch.Config.PCID", domain: host),
            ],
            automation: EasybankLoginScript.automation
        )
    }

    /// Headers the single-page app sends; values derived from the session, never logged.
    static func headers(cookies: [SessionCookie], appValues: [SessionCookie] = []) -> [String: String] {
        var headers = [
            "X-Requested-With": "XMLHttpRequest",
            "Origin": "https://banking.easybank.de",
            "Referer": "https://banking.easybank.de/",
        ]
        if let uniqueKey = appValues.first(where: { $0.name == uniqueKeyName })?.value {
            headers["UniqueKey"] = uniqueKey
        }
        if let pcid = appValues.first(where: { $0.name == pcidName })?.value {
            headers["pcid"] = pcid
        }
        // Anti-CSRF: the app mirrors the XSRF-TOKEN cookie into the x-xsrf-token header.
        if let token = cookies.first(where: { $0.name == "XSRF-TOKEN" })?.value {
            headers["X-XSRF-TOKEN"] = token.removingPercentEncoding ?? token
        }
        return headers
    }
}
