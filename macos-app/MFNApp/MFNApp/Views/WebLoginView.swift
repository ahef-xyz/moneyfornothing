import AppKit
import MFNCore
import MFNScrape
import SwiftUI
import WebKit

/// Interactive web login for scraping connectors (`AuthChallenge.webLogin` without automation).
///
/// Shows the bank's own login page; MFN never sees what the user types. Once
/// `WebLoginRequest.completion` is met the cookies of the requested domains and the requested
/// Web Storage entries go back to the connector as `.webSession`.
struct WebLoginView: View {
    let request: AuthSheetPresenter.Request
    let webLogin: WebLoginRequest
    @Environment(AppModel.self) private var model
    @State private var controller: WebLoginController?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Anmeldung bei \(request.connectionName)", systemImage: "globe")
                    .font(.headline)
                Text(webLogin.message)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            Group {
                if let controller {
                    WebViewContainer(webView: controller.webView)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 720, idealWidth: 920, minHeight: 480, idealHeight: 680)
            Divider()
            HStack(spacing: 8) {
                // The host is always visible so the user can see where they are typing.
                Label(controller?.host ?? webLogin.url.host() ?? "", systemImage: controller?.isSecure == false ? "lock.open" : "lock")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if controller?.loadFailed == true {
                    Label("Seite konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if controller?.isLoading == true {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Neu laden", systemImage: "arrow.clockwise") { controller?.reload() }
                    .labelStyle(.titleOnly)
                Button("Abbrechen", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onAppear {
            guard controller == nil else { return }
            let presenter = model.presenter
            let id = request.id
            let controller = WebLoginController(request: webLogin, connection: request.connection.id, credentials: nil) { result in
                // Only answers the request this view belongs to (locking cancels the queue).
                switch result {
                case let .success(cookies): presenter.respond(to: id, .webSession(cookies))
                case let .failure(error): presenter.fail(id, with: error)
                }
            }
            self.controller = controller
            controller.start()
        }
        .onDisappear { controller?.stop() }
    }

    private func cancel() {
        controller?.stop()
        model.presenter.cancel(request.id)
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Owns the `WKWebView` of one web login (visible or headless) and watches it until the login
/// is complete.
///
/// - Data store: persistent, one per connection (`WebDataStorePolicy.identifier`), so the bank
///   recognises the device. After a successful login the session-like cookies are deleted from
///   it again; the session lives only in the keychain (via the connector).
/// - Cookies come from `WKHTTPCookieStore.allCookies()`: the only source that includes HttpOnly
///   cookies and cookies set by scripts (`aws-waf-token`).
/// - Web Storage is read with `evaluateJavaScript` on a page of the key's domain.
/// - Headless (`automation != nil`): the web view sits in an off-screen window, the connector's
///   script runs after every main-frame load in an isolated content world with the bridge `mfn`;
///   `HeadlessLogin` (MFNScrape, unit-tested) decides what counts. No console or script output is
///   read or logged; credentials are passed only as an argument.
/// - Which values count and when the login is done is decided by `WebLoginCapture`.
@MainActor
@Observable
final class WebLoginController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var host: String
    private(set) var isSecure = true
    private(set) var isLoading = false
    private(set) var loadFailed = false
    /// Headless state for the UI (status line, code field); `nil` for a visible login.
    private(set) var headless: HeadlessLogin?
    /// Headless only: the user asked to see the page (captcha, unexpected step). The web view
    /// then lives in the sheet; the script keeps running.
    private(set) var isRevealed = false

    @ObservationIgnored private var capture: WebLoginCapture
    @ObservationIgnored private let credentials: BankCredentials?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var onFinish: ((Result<[SessionCookie], ConnectorError>) -> Void)?
    /// Polls granted to a single-page app to write its storage entry after completion.
    @ObservationIgnored private var storageGrace = 6
    @ObservationIgnored private var lastMissingCookies: [String]?
    @ObservationIgnored private var hiddenWindow: NSWindow?
    @ObservationIgnored private var codeReply: ((Any?, String?) -> Void)?
    @ObservationIgnored private let world = WKContentWorld.world(name: HeadlessLogin.contentWorldName)

    private static let pollInterval = Duration.milliseconds(500)
    /// `WebKitErrorDomain` / `WebKitErrorFrameLoadInterruptedByPolicyChange` (WebKit legacy constants,
    /// not exported to Swift): a navigation cancelled by `decidePolicyFor`.
    private static let webKitErrorDomain = "WebKitErrorDomain"
    private static let frameLoadInterruptedByPolicyChange = 102

    /// - Parameters:
    ///   - connection: selects the connection's persistent web data store.
    ///   - credentials: required for a headless login (`request.automation != nil`).
    init(request: WebLoginRequest, connection: ConnectionID, credentials: BankCredentials?, onFinish: @escaping (Result<[SessionCookie], ConnectorError>) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: WebDataStorePolicy.identifier(for: connection))
        // Without the Safari suffix some banks treat the web view as an unsupported browser.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let headless = request.automation.map { HeadlessLogin(automation: $0) }
        if headless != nil {
            // The bridge exists only in the login's own content world; the page never sees it.
            let world = WKContentWorld.world(name: HeadlessLogin.contentWorldName)
            configuration.userContentController.addUserScript(WKUserScript(source: HeadlessLogin.bridgeSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        capture = WebLoginCapture(request: request)
        host = request.url.host() ?? ""
        self.credentials = credentials
        self.headless = headless
        self.onFinish = onFinish
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if headless != nil {
            configuration.userContentController.addScriptMessageHandler(BridgeHandler(owner: self), contentWorld: world, name: HeadlessLogin.handlerName)
        }
    }

    var isHeadless: Bool { headless != nil }

    func start() {
        guard pollTask == nil, onFinish != nil else { return }
        if isHeadless {
            guard credentials != nil else { return finish(.failure(.authRequired(.webLogin(capture.request)))) }
            attachHiddenWindow()
        }
        webView.load(URLRequest(url: capture.request.url))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await !self.poll() else { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func reload() {
        loadFailed = false
        if webView.url == nil {
            webView.load(URLRequest(url: capture.request.url))
        } else {
            webView.reload()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        onFinish = nil
        codeReply?(nil, HeadlessLogin.cancelledMessage)
        codeReply = nil
        webView.stopLoading()
        if isHeadless {
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            hiddenWindow?.contentView = nil
            hiddenWindow?.close()
            hiddenWindow = nil
        }
    }

    /// User cancelled (sheet or assistant).
    func cancel() {
        headless?.fail(.cancelled)
        finish(.failure(.cancelled))
    }

    // MARK: Headless

    /// Moves the web view from the hidden window into the sheet (`HeadlessLoginView` embeds it).
    func reveal() {
        guard isHeadless, !isRevealed else { return }
        hiddenWindow?.contentView = nil
        hiddenWindow?.close()
        hiddenWindow = nil
        isRevealed = true
    }

    /// Back into the hidden window; the script keeps running. The sheet drops its container first
    /// (SwiftUI removes the web view from its superview when it tears the container down), so the
    /// hidden window takes the web view on the next run-loop turn.
    func conceal() {
        guard isHeadless, isRevealed, onFinish != nil else { return }
        isRevealed = false
        Task { @MainActor [weak self] in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !self.isRevealed, self.onFinish != nil, self.hiddenWindow == nil else { return }
            self.webView.removeFromSuperview()
            self.attachHiddenWindow()
        }
    }

    /// Off-screen, borderless, never key, not in the window list: the page loads and runs like
    /// in a real window, but the user never sees it. An off-screen window is occluded, and WebKit
    /// then reports `visibilityState = hidden` and throttles the page; some banks wait for a visible
    /// page (DKB: captcha, FingerprintJS before the push). Occlusion detection is therefore switched
    /// off for this web view (WebKit SPI, checked with `responds(to:)`; without it nothing changes).
    private func attachHiddenWindow() {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1024, height: 768), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Self.disableOcclusionDetection(webView)
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = webView
        window.orderFrontRegardless()
        hiddenWindow = window
    }

    private static func disableOcclusionDetection(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
    }


    private func runScript() {
        // Credentials only go to pages of the bank: the login URL's host or a cookie domain.
        guard WebLoginHostPolicy.mayRunScript(on: webView.url, request: capture.request) else {
            let path = webView.url?.path() ?? ""
            Log.logger("weblogin").info("Login-Skript nicht gestartet: fremder Host (Seite \(path, privacy: .private))")
            return
        }
        guard var login = headless, let credentials, let automation = capture.request.automation, let run = login.pageLoaded() else { return }
        headless = login
        let arguments = login.arguments(for: run, credentials: credentials, url: webView.url)
        Task { [weak self, world] in
            guard let webView = self?.webView else { return }
            do {
                let result = try await webView.callAsyncJavaScript(automation.script, arguments: arguments, in: nil, contentWorld: world)
                self?.headless?.scriptSucceeded(run, result: result)
            } catch {
                // The exception text decides authFailed vs. formatChanged. Only the connector's own
                // short reason texts are logged (`loggableReason` drops anything with data in it).
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                guard let self, let mapped = self.headless?.scriptFailed(run, message: message) else { return }
                let reason = HeadlessLogin.loggableReason(forScriptMessage: message) ?? "<nicht protokolliert>"
                Log.logger("weblogin").error("Login-Skript beendet: \(mapped.description, privacy: .public) – \(reason, privacy: .public)")
                self.finish(.failure(mapped))
            }
        }
    }

    fileprivate func handleBridge(_ body: Any, reply: @escaping (Any?, String?) -> Void) {
        guard headless != nil else { return reply(nil, HeadlessLogin.cancelledMessage) }
        switch headless?.handle(bridgeMessage: body) {
        case .reply?:
            reply(nil, nil)
        case .askForCode?:
            codeReply?(nil, HeadlessLogin.cancelledMessage)
            codeReply = reply
        case let .reject(message)?:
            reply(nil, message)
        case nil:
            reply(nil, HeadlessLogin.cancelledMessage)
        }
    }

    func accepts(code: String) -> Bool {
        headless?.accepts(code: code) ?? false
    }

    func submitCode(_ code: String) {
        guard accepts(code: code), let reply = codeReply else { return }
        codeReply = nil
        headless?.codeAnswered()
        reply(code.trimmingCharacters(in: .whitespaces), nil)
    }

    /// The user does not want to enter a code: the script decides (usually gives up).
    func cancelCode() {
        guard let reply = codeReply else { return }
        codeReply = nil
        headless?.codeAnswered()
        reply(nil, HeadlessLogin.cancelledMessage)
    }

    // MARK: Completion

    /// One poll: timeout, storage, cookies, completion. Returns `true` when finished.
    private func poll() async -> Bool {
        guard onFinish != nil else { return true }
        if let error = headless?.checkTimeout(now: Date()) {
            finish(.failure(error))
            return true
        }
        let page = webView.url
        host = page?.host() ?? host
        isSecure = page.map { $0.scheme == "https" } ?? true

        if let script = capture.storageScript(forPage: page), let result = await evaluate(script),
           webView.url?.host() == page?.host() {
            capture.recordStorage(scriptResult: result, page: page)
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .map(WebLoginCapture.sessionCookie)
        logMissingCompletionCookies(cookies)
        guard !Task.isCancelled, onFinish != nil, capture.isComplete(currentURL: webView.url, cookies: cookies) else { return false }
        if capture.isMissingStorage(forPage: webView.url), storageGrace > 0 {
            storageGrace -= 1
            return false
        }

        let session = capture.session(cookies: cookies)
        let storageCount = capture.storageEntries.count
        Log.logger("weblogin").info("Web-Login abgeschlossen: \(session.count - storageCount, privacy: .public) Cookies, \(storageCount, privacy: .public) Storage-Einträge")
        headless?.finish()
        finish(.success(session))
        return true
    }

    /// Names (never values) of the completion cookies still missing, logged when they change, so a
    /// login that never completes shows what it waits for.
    private func logMissingCompletionCookies(_ cookies: [SessionCookie]) {
        guard case let .cookiesPresent(required) = capture.request.completion else { return }
        let present = Set(capture.session(cookies: cookies).map(\.name))
        let missing = required.filter { !present.contains($0) }
        guard missing != lastMissingCookies else { return }
        lastMissingCookies = missing
        let path = webView.url?.path() ?? ""
        Log.logger("weblogin").info("Web-Login wartet auf Cookies: \(missing.isEmpty ? "–" : missing.joined(separator: ", "), privacy: .public) (Seite \(path, privacy: .private))")
    }

    /// Ends the login with any result (success, failure, cancel) and drops the session cookies
    /// from the persistent web store either way: a half-finished login leaves no session behind.
    private func finish(_ result: Result<[SessionCookie], ConnectorError>) {
        let callback = onFinish
        stop()
        callback?(result)
        // The store, not `self`: the sheet may release the controller right after the callback.
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let completion = capture.request.completion
        Task { await Self.removeSessionCookies(from: store, completion: completion) }
    }

    /// The session goes to the keychain only: drop session-like cookies from the persistent web
    /// store; device and fingerprint cookies (and `localStorage`) stay for the next login.
    private static func removeSessionCookies(from store: WKHTTPCookieStore, completion: WebLoginRequest.Completion) async {
        for cookie in await store.allCookies() where WebDataStorePolicy.isSessionCookie(named: cookie.name, completion: completion) {
            await store.deleteCookie(cookie)
        }
    }

    /// Runs a storage script. `nil` if the script could not run (page is navigating); the
    /// script itself always evaluates to a JSON string.
    private func evaluate(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: error == nil ? value as? String : nil)
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The login runs over HTTPS only and stays on the bank's hosts (login URL host and cookie
        // domains); app deep links, downgrades and main-frame hops to other sites are cancelled.
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return .allow }
        guard WebLoginHostPolicy.mayNavigate(to: navigationAction.request.url, request: capture.request) else {
            let path = navigationAction.request.url?.path() ?? ""
            Log.logger("weblogin").info("Navigation abgebrochen: fremder Host (Seite \(path, privacy: .private))")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
        loadFailed = false
        headless?.navigationStarted()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoading = false
        if isHeadless, onFinish != nil { runScript() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: any Error) {
        isLoading = false
        // Cancelled loads (redirects, our own policy) are not failures. A navigation the policy
        // cancelled ends as WebKitErrorDomain 102 ("Frame load interrupted").
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled,
              !(nsError.domain == Self.webKitErrorDomain && nsError.code == Self.frameLoadInterruptedByPolicyChange) else { return }
        loadFailed = true
        // Headless: nobody can press "Neu laden" – the bank is not reachable.
        if isHeadless, onFinish != nil {
            headless?.fail(.bankUnavailable)
            finish(.failure(.bankUnavailable))
        }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links that want a new window open in place; MFN shows exactly one web view.
        if navigationAction.request.url?.scheme?.lowercased() == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// Which main-frame pages a web login may show and run its script on: HTTPS pages whose host is
/// the login URL's host or lies within one of `cookieDomains` (exact or subdomain). Every connector
/// keeps its login inside those (ING `access.ing.de` ↔ `banking.ing.de` in `ing.de`, DKB `dkb.de`,
/// N26 `n26.com`, easybank `easybank.de`, C24 `c24.de`, Trade Republic `traderepublic.com`).
/// `about:` pages may load (blank frames); the script runs there only if the login URL itself is
/// `about:` (demo login of the mock).
enum WebLoginHostPolicy {
    static func mayNavigate(to url: URL?, request: WebLoginRequest) -> Bool {
        guard let url else { return true }
        switch url.scheme?.lowercased() {
        case "about"?: return true
        case "https"?: return isBankHost(url, request: request)
        default: return false
        }
    }

    static func mayRunScript(on url: URL?, request: WebLoginRequest) -> Bool {
        guard let url else { return false }
        switch url.scheme?.lowercased() {
        case "about"?: return request.url.scheme?.lowercased() == "about"
        case "https"?: return isBankHost(url, request: request)
        default: return false
        }
    }

    static func isBankHost(_ url: URL, request: WebLoginRequest) -> Bool {
        guard let host = normalized(url.host()) else { return false }
        let domains = ([request.url.host()] + request.cookieDomains.map(Optional.some)).compactMap(normalized)
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func normalized(_ host: String?) -> String? {
        guard var host = host?.lowercased() else { return nil }
        while host.hasPrefix(".") { host.removeFirst() }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

/// Weak bridge between `WKUserContentController` (which retains its handlers) and the controller.
private final class BridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: WebLoginController?

    init(owner: WebLoginController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let owner else { return replyHandler(nil, HeadlessLogin.cancelledMessage) }
        owner.handleBridge(message.body, reply: replyHandler)
    }
}

/// Removes a connection's persistent web data store ("Bank entfernen", cancelled setup).
@MainActor
enum WebDataStoreCleanup {
    /// `WKWebsiteDataStore.remove(forIdentifier:)` crashes (EXC_BAD_ACCESS in
    /// `removeDataStoreWithIdentifierImpl`) in a process that has not used WebKit yet: three times
    /// on 2026-11-12 (FinTS setups without a web view, a merge right after launch), reproduced in a
    /// bare app. Any WebKit object first avoids it; a non-persistent store touches nothing on disk.
    private static let webKit = WKWebsiteDataStore.nonPersistent()

    static func remove(_ connection: ConnectionID) async {
        _ = webKit
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: WebDataStorePolicy.identifier(for: connection))
        } catch {
            // Missing store is fine; one still in use is emptied instead.
            let store = WKWebsiteDataStore(forIdentifier: WebDataStorePolicy.identifier(for: connection))
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}
