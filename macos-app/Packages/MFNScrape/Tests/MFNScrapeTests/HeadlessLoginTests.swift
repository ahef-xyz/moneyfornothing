import Foundation
import MFNCore
import Testing
@testable import MFNScrape

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let automation = WebLoginAutomation(script: "return null;", message: "Anmeldung läuft …", timeout: 120)
private let credentials = BankCredentials(["username": "max@example.invalid", "password": "Pa55-geheim"])

@Suite struct HeadlessLoginTests {
    @Test func firstRunGetsNullStateThenPreviousResult() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        #expect(login.phase == .starting)
        #expect(login.status == "Anmeldung läuft …")

        let firstRun = login.pageLoaded()
        let first = try #require(firstRun)
        #expect(login.phase == .running)
        let args = login.arguments(for: first, credentials: credentials, url: URL(string: "https://bank.example.invalid/login"))
        #expect(args["state"] is NSNull)
        #expect(args["url"] as? String == "https://bank.example.invalid/login")
        #expect(args["credentials"] as? [String: String] == credentials.values)

        login.scriptSucceeded(first, result: ["step": 2, "user": "x"] as [String: Any])
        let secondRun = login.pageLoaded()
        let second = try #require(secondRun)
        let state = login.arguments(for: second, credentials: credentials, url: nil)["state"] as? [String: Any]
        #expect(state?["step"] as? Int == 2)
        #expect(state?["user"] as? String == "x")

        // `undefined` (nil) resets the state to null; plain strings survive.
        login.scriptSucceeded(second, result: "otp")
        let thirdRun = login.pageLoaded()
        let third = try #require(thirdRun)
        #expect(login.arguments(for: third, credentials: credentials, url: nil)["state"] as? String == "otp")
        login.scriptSucceeded(third, result: nil)
        let fourthRun = login.pageLoaded()
        let fourth = try #require(fourthRun)
        #expect(login.arguments(for: fourth, credentials: credentials, url: nil)["state"] is NSNull)
    }

    @Test func outdatedRunsAreIgnored() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        let firstRun = login.pageLoaded()
        let first = try #require(firstRun)
        login.navigationStarted() // script submitted the form
        // The old page went away: its call fails, but that is not a script error.
        let r1 = login.scriptFailed(first, message: "JavaScript execution returned a result of an unsupported type")
        #expect(r1 == nil)
        login.scriptSucceeded(first, result: "stale")
        #expect(login.phase == .running)
        let secondRun = login.pageLoaded()
        let second = try #require(secondRun)
        #expect(login.arguments(for: second, credentials: credentials, url: nil)["state"] is NSNull)
    }

    @Test func errorMappingFollowsProtocol() {
        #expect(HeadlessLogin.error(forScriptMessage: "authFailed") == .authFailed)
        #expect(HeadlessLogin.error(forScriptMessage: HeadlessLogin.cancelledMessage) == .cancelled)
        #expect(HeadlessLogin.error(forScriptMessage: "Error: cancelled") == .cancelled)
        #expect(HeadlessLogin.error(forScriptMessage: "cancelled by bank") == .formatChanged(detail: "login script"))
        #expect(HeadlessLogin.error(forScriptMessage: "authFailed: falsches Passwort") == .authFailed)
        #expect(HeadlessLogin.error(forScriptMessage: "Error: authFailed wrong pin") == .authFailed)
        #expect(HeadlessLogin.error(forScriptMessage: "TypeError: authFailed") == .authFailed)
        #expect(HeadlessLogin.error(forScriptMessage: "  authFailed\n") == .authFailed)
        // Anything else → formatChanged without the message text (it may contain page data).
        #expect(HeadlessLogin.error(forScriptMessage: "TypeError: null is not an object (evaluating 'form.user')") == .formatChanged(detail: "login script"))
        #expect(HeadlessLogin.error(forScriptMessage: "notAuthFailed") == .formatChanged(detail: "login script"))
        #expect(HeadlessLogin.error(forScriptMessage: nil) == .formatChanged(detail: "login script"))
    }

    @Test func scriptErrorEndsLoginWithoutRetry() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        let runRun = login.pageLoaded()
        let run = try #require(runRun)
        let r2 = login.scriptFailed(run, message: "Error: authFailed")
        #expect(r2 == .authFailed)
        #expect(login.phase == .failed(.authFailed))
        let r3 = login.pageLoaded()
        #expect(r3 == nil, "no further runs after a failure")
        login.finish()
        #expect(login.phase == .failed(.authFailed))
    }

    @Test func timeoutCancels() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        _ = login.pageLoaded()
        let r4 = login.checkTimeout(now: start.addingTimeInterval(119))
        #expect(r4 == nil)
        #expect(login.elapsedFraction(now: start.addingTimeInterval(60)) == 0.5)
        let r5 = login.checkTimeout(now: start.addingTimeInterval(120))
        #expect(r5 == .cancelled)
        #expect(login.phase == .failed(.cancelled))
        let r6 = login.checkTimeout(now: start.addingTimeInterval(500))
        #expect(r6 == nil)
    }

    @Test func finishedLoginIgnoresTimeout() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        _ = login.pageLoaded()
        login.finish()
        let r7 = login.checkTimeout(now: start.addingTimeInterval(1000))
        #expect(r7 == nil)
        #expect(login.phase == .finished)
    }

    @Test func bridgeStatusAndCode() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        _ = login.pageLoaded()
        let r8 = login.handle(bridgeMessage: ["op": "status", "text": "  Bitte in der App bestätigen  "])
        #expect(r8 == .reply)
        #expect(login.status == "Bitte in der App bestätigen")
        let r9 = login.handle(bridgeMessage: ["op": "status", "text": String(repeating: "x", count: 500)])
        #expect(r9 == .reply)
        #expect(login.status.count == HeadlessLogin.maximumStatusLength)

        let action = login.handle(bridgeMessage: ["op": "requestCode", "prompt": "SMS-Code", "length": NSNumber(value: 6)])
        #expect(action == .askForCode(prompt: "SMS-Code", length: 6))
        #expect(login.phase == .waitingForCode(prompt: "SMS-Code", length: 6))
        #expect(!login.accepts(code: "123"))
        #expect(login.accepts(code: "123456"))
        login.codeAnswered()
        #expect(login.phase == .running)
        #expect(!login.accepts(code: "123456"), "no open request")

        let r10 = login.handle(bridgeMessage: "status")
        #expect(r10 == .reject("invalid message"))
        let r11 = login.handle(bridgeMessage: ["op": "pay"])
        #expect(r11 == .reject("invalid message"))
        login.fail(.cancelled)
        let r12 = login.handle(bridgeMessage: ["op": "status", "text": "x"])
        #expect(r12 == .reject(HeadlessLogin.cancelledMessage))
    }

    @Test func implausibleCodeLengthMeansFreeLength() {
        var login = HeadlessLogin(automation: automation, start: start)
        _ = login.pageLoaded()
        let r13 = login.handle(bridgeMessage: ["op": "requestCode", "prompt": "", "length": NSNumber(value: 999)])
        #expect(r13 == .askForCode(prompt: "", length: 0))
        #expect(login.phase == .waitingForCode(prompt: HeadlessLogin.defaultCodePrompt, length: 0))
        #expect(login.accepts(code: "12345678"))
    }

    @Test func bridgeLivesOnlyInOwnWorldAndNeverSeesCredentials() {
        let source = HeadlessLogin.bridgeSource
        #expect(source.contains("messageHandlers.mfn"))
        #expect(source.contains("requestCode"))
        #expect(!source.contains("credentials"))
        #expect(HeadlessLogin.contentWorldName != "page")
    }

    @Test func missingOrIncompleteCredentialsAreNotUsable() {
        #expect(HeadlessLogin.usableCredentials(nil, for: .easybank) == nil)
        #expect(HeadlessLogin.usableCredentials(BankCredentials(["username": "x"]), for: .easybank) == nil)
        #expect(HeadlessLogin.usableCredentials(credentials, for: .easybank) == credentials)
        // Trade Republic: 4-digit numeric PIN.
        #expect(HeadlessLogin.usableCredentials(BankCredentials(["phoneNumber": "+49170", "pin": "12a4"]), for: .tradeRepublic) == nil)
        #expect(HeadlessLogin.usableCredentials(BankCredentials(["phoneNumber": "+49170", "pin": "1234"]), for: .tradeRepublic) != nil)
        // The mock needs none.
        #expect(HeadlessLogin.usableCredentials(nil, for: .mock) == BankCredentials())
        // C24 (v5, QR code login) needs none either.
        #expect(HeadlessLogin.usableCredentials(nil, for: .c24) == BankCredentials())
    }

    @Test func descriptionAndMirrorRedactStateAndCredentials() throws {
        var login = HeadlessLogin(automation: automation, start: start)
        let runRun = login.pageLoaded()
        let run = try #require(runRun)
        login.scriptSucceeded(run, result: ["token": "tok-geheim-123"])
        _ = login.handle(bridgeMessage: ["op": "status", "text": "Bitte bestätigen"])
        for text in [login.description, login.debugDescription, String(reflecting: login), "\(Mirror(reflecting: login).children.map(\.value))"] {
            #expect(!text.contains("tok-geheim-123"))
            #expect(!text.contains("Pa55-geheim"))
        }
        #expect(Mirror(reflecting: login).children.isEmpty)
    }

    @Test func connectionSecretsCoverConnectorSessionConventions() {
        let items = ConnectionSecrets.sessionItems(connection: "c24-ab12", connector: .c24)
        #expect(items.contains(.init(service: "xyz.ahef.mfn.sessions", key: "c24.c24-ab12")))
        let tr = ConnectionSecrets.sessionItems(connection: "live-tradeRepublic", connector: .tradeRepublic)
        #expect(tr.contains(.init(service: "xyz.ahef.mfn", key: "tradeRepublic.session.live-tradeRepublic")))
    }
}

@Suite struct WebDataStorePolicyTests {
    @Test func identifierIsStablePerConnection() {
        let a = WebDataStorePolicy.identifier(for: "c24-ab12")
        #expect(a == WebDataStorePolicy.identifier(for: "c24-ab12"))
        #expect(a != WebDataStorePolicy.identifier(for: "c24-ab13"))
        #expect(a.uuidString.dropFirst(14).first == "5", "version 5 layout")
    }

    @Test func deletesSessionCookiesKeepsDeviceCookies() {
        let request = WebLoginRequest(url: URL(string: "https://bank.example.invalid")!, completion: .cookiesPresent(["tr_claims"]), cookieDomains: ["example.invalid"], message: "")
        let cookies = ["tr_session", "tr_refresh", "tr_claims", "JSESSIONID", "XSRF-TOKEN", "OAuth_state", "aws-waf-token", "device_id", "fp", "_ga"]
            .map { SessionCookie(name: $0, value: "v", domain: "bank.example.invalid") }
        let deleted = WebDataStorePolicy.cookiesToDelete(cookies, after: request).map(\.name)
        #expect(deleted == ["tr_session", "tr_refresh", "tr_claims", "JSESSIONID", "XSRF-TOKEN", "OAuth_state", "aws-waf-token"])
        // Completion names count even without a session-like fragment.
        #expect(WebDataStorePolicy.isSessionCookie(named: "tr_claims", completion: request.completion))
        #expect(!WebDataStorePolicy.isSessionCookie(named: "tr_claims", completion: .urlPrefix("https://x")))
    }
}

@Suite struct WebDataStorePayPalTests {
    /// The cookie names of the recording (`Fixtures/PayPal/endpoints.md`): the session leaves the
    /// web store although the login ends on a URL and most names say nothing.
    @Test func payPalKeepsOnlyDeviceCookies() {
        let request = WebLoginRequest(url: URL(string: "https://www.paypal.com/signin")!, completion: .urlPrefix("https://www.paypal.com/myaccount"), cookieDomains: ["paypal.com"], message: "")
        let names = ["nsid", "x-pp-s", "id_token", "rssk", "rmuc", "l7_az", "X-PP-ADS", "AV894Kt2TSumQQrJwe", "datadome", "d_id", "fn_dt", "ts", "ts_c", "LANG", "cookie_prefs"]
        let cookies = names.map { SessionCookie(name: $0, value: "v", domain: $0 == "nsid" ? "www.paypal.com" : ".paypal.com") }
        let deleted = WebDataStorePolicy.cookiesToDelete(cookies, after: request).map(\.name)
        #expect(deleted == ["nsid", "x-pp-s", "id_token", "rssk", "rmuc", "l7_az", "X-PP-ADS", "AV894Kt2TSumQQrJwe"])
        // Another site with the same names is judged by name fragments as before.
        #expect(!WebDataStorePolicy.isSessionCookie(named: "nsid", domain: "bank.example.invalid", completion: request.completion))
        #expect(!WebDataStorePolicy.isSessionCookie(named: "nsid", domain: "notpaypal.com", completion: request.completion))
    }
}

@Suite struct HeadlessLoginQRCodeTests {
    private func login() -> HeadlessLogin {
        var login = HeadlessLogin(automation: WebLoginAutomation(script: "", message: "Anmeldung …"))
        _ = login.pageLoaded()
        return login
    }

    @Test func showQRCodeSetsCodeAndStatus() {
        var login = login()
        #expect(login.handle(bridgeMessage: ["op": "showQRCode", "payload": "token-1", "message": "Mit der App scannen."]) == .reply)
        #expect(login.qrCode?.payload == "token-1")
        #expect(login.status == "Mit der App scannen.")
        // Rotation replaces the code.
        _ = login.handle(bridgeMessage: ["op": "showQRCode", "payload": "token-2", "message": ""])
        #expect(login.qrCode?.payload == "token-2")
    }

    @Test func statusAndCodeRequestHideTheQRCode() {
        var login = login()
        _ = login.handle(bridgeMessage: ["op": "showQRCode", "payload": "t", "message": "m"])
        _ = login.handle(bridgeMessage: ["op": "status", "text": "Code abgelaufen"])
        #expect(login.qrCode == nil)
        _ = login.handle(bridgeMessage: ["op": "showQRCode", "payload": "t", "message": "m"])
        _ = login.handle(bridgeMessage: ["op": "requestCode", "prompt": "6 Ziffern", "length": 6])
        #expect(login.qrCode == nil)
    }

    @Test func rejectsEmptyOrHugePayloadAndRedacts() {
        var login = login()
        #expect(login.handle(bridgeMessage: ["op": "showQRCode", "payload": ""]) == .reject("invalid message"))
        #expect(login.handle(bridgeMessage: ["op": "showQRCode", "payload": String(repeating: "x", count: 3000)]) == .reject("invalid message"))
        _ = login.handle(bridgeMessage: ["op": "showQRCode", "payload": "secret-token", "message": ""])
        #expect(!String(describing: login.qrCode).contains("secret-token"))
        #expect(!login.description.contains("secret-token"))
    }

    @Test func bridgeSourceDefinesShowQRCode() {
        #expect(HeadlessLogin.bridgeSource.contains("showQRCode"))
    }

    @Test func loggableReasonKeepsOnlyConnectorText() {
        #expect(HeadlessLogin.loggableReason(forScriptMessage: "Error: authFailed: easybank asks for a captcha") == "authFailed: easybank asks for a captcha")
        #expect(HeadlessLogin.loggableReason(forScriptMessage: "authFailed: code 123456 rejected") == nil)
        #expect(HeadlessLogin.loggableReason(forScriptMessage: "user alice@example.com unknown") == nil)
        #expect(HeadlessLogin.loggableReason(forScriptMessage: String(repeating: "a", count: 121)) == nil)
        #expect(HeadlessLogin.loggableReason(forScriptMessage: nil) == nil)
    }
}
