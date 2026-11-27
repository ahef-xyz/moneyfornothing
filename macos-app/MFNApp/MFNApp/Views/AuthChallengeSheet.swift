import AuthenticationServices
import MFNCore
import SwiftUI

/// Approval for decoupled TAN, 2FA code, push confirmation, web login (visible or headless) and, v12,
/// a choice between the bank's options or a code read off an image (photoTAN, chipTAN optic).
///
/// Shown as sheet for syncs, and inline in the setup assistant (`embedded`).
struct AuthChallengeSheet: View {
    let request: AuthSheetPresenter.Request
    var embedded = false
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var choice: String?

    var body: some View {
        switch request.challenge {
        case let .webLogin(webLogin) where SystemLogin.callbackScheme(of: webLogin) != nil:
            SystemLogin(request: request, webLogin: webLogin, embedded: embedded)
                .id(request.id)
        case let .webLogin(webLogin) where webLogin.automation != nil:
            HeadlessLoginView(request: request, webLogin: webLogin, showsHeader: !embedded)
                .id(request.id)
        case let .webLogin(webLogin):
            WebLoginView(request: request, webLogin: webLogin)
                .id(request.id)
        case let .decoupled(message, _):
            AppApproval(request: request, message: message, waits: true, embedded: embedded)
        case let .pushConfirm(message):
            AppApproval(request: request, message: message, waits: false, embedded: embedded)
        default:
            approval
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                Label("Freigabe für \(request.connectionName)", systemImage: "hand.raised")
                    .font(.headline)
            }

            switch request.challenge {
            case .decoupled, .pushConfirm:
                EmptyView() // see `body`
            case let .code(prompt, length):
                Text(prompt)
                codeField
                buttons(confirmTitle: "Bestätigen", disabled: !Self.isComplete(code, length: length), action: submitCode)
            case let .secret(prompt, length):
                Text(prompt)
                SecureField("PIN oder Passwort", text: $code)
                    .onSubmit(submitCode)
                buttons(confirmTitle: "Bestätigen", disabled: !Self.isComplete(code, length: length), action: submitCode)
            case let .imageCode(prompt, length, image):
                Text(prompt)
                BankImage(image: image, prompt: prompt)
                    .frame(maxWidth: .infinity)
                codeField
                buttons(confirmTitle: "Bestätigen", disabled: !Self.isComplete(code, length: length), action: submitCode)
            case let .choice(prompt, options):
                Text(prompt)
                Picker(prompt, selection: $choice) {
                    ForEach(options) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                            if let detail = option.detail {
                                Text(detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .tag(Optional(option.key))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onAppear { if choice == nil { choice = options.first?.key } }
                buttons(confirmTitle: "Weiter", disabled: choice == nil) {
                    guard let choice, options.contains(where: { $0.key == choice }) else { return }
                    model.presenter.respond(to: request.id, .code(choice))
                }
            case .webLogin:
                EmptyView() // see `body`
            }
        }
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 380)
        .onAppear { AccessibilityNotification.Announcement(announcement).post() }
    }

    private var announcement: String {
        switch request.challenge {
        case let .decoupled(message, _), let .pushConfirm(message): String(localized: "Freigabe für \(request.connectionName): \(message)")
        case let .code(prompt, _), let .imageCode(prompt, _, _), let .choice(prompt, _), let .secret(prompt, _): String(localized: "Freigabe für \(request.connectionName): \(prompt)")
        case .webLogin: String(localized: "Freigabe für \(request.connectionName)")
        }
    }

    private var codeField: some View {
        TextField("Code", text: $code)
            .textContentType(.oneTimeCode)
            .monospacedDigit()
            .onSubmit(submitCode)
    }

    /// v12: length 0 = any length.
    static func isComplete(_ code: String, length: Int) -> Bool {
        !code.isEmpty && (length == 0 || code.count == length)
    }

    private func submitCode() {
        let length: Int
        switch request.challenge {
        case let .code(_, value), let .imageCode(_, value, _), let .secret(_, value): length = value
        default: return
        }
        guard Self.isComplete(code, length: length) else { return }
        let entered = code
        code = ""
        model.presenter.respond(to: request.id, .code(entered))
    }

    @ViewBuilder
    private func buttons(confirmTitle: LocalizedStringKey?, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Abbrechen", role: .cancel) { model.presenter.cancel(request.id) }
                .keyboardShortcut(.cancelAction)
            if let confirmTitle {
                Button(confirmTitle, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
        }
    }
}

/// The bank's image for a TAN (v12): photoTAN mosaic or animated chipTAN optic GIF. Only PNG, JPEG
/// and GIF up to `AuthImage.maximumBytes`, decoded by AppKit; anything else is not shown.
struct BankImage: View {
    let image: AuthImage
    /// The bank's prompt: the image itself cannot be described, its purpose can.
    var prompt: String = ""

    private static let allowedTypes: Set<String> = ["image/png", "image/jpeg", "image/gif"]

    private var decoded: NSImage? {
        guard Self.allowedTypes.contains(image.mimeType.lowercased()), image.data.count <= AuthImage.maximumBytes else { return nil }
        return NSImage(data: image.data)
    }

    var body: some View {
        if let decoded {
            let size = displaySize(of: decoded)
            AnimatedImage(image: decoded, animates: image.physicalWidthMM != nil || !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                .frame(width: size.width, height: size.height)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityLabel("Grafik deiner Bank für die TAN")
                .accessibilityAddTraits(.isImage)
                .accessibilityHint("Nur sichtbar lesbar. Bei Bedarf in der App deiner Bank ein anderes Verfahren wählen.")
        } else {
            Label("Die Grafik deiner Bank kann MFN nicht anzeigen.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    /// Natural size up to 320 pt; with `physicalWidthMM` the real width on the main screen (chipTAN).
    private func displaySize(of image: NSImage) -> CGSize {
        let natural = image.size.width > 0 ? image.size : CGSize(width: 200, height: 200)
        var width = min(natural.width, 320)
        if let millimetres = self.image.physicalWidthMM, let pointsPerMM = Self.pointsPerMillimetre() {
            width = millimetres * pointsPerMM
        }
        return CGSize(width: width, height: width * natural.height / natural.width)
    }

    private static func pointsPerMillimetre() -> Double? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let physical = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        guard physical.width > 0 else { return nil }
        return screen.frame.width / physical.width
    }
}

/// `NSImageView` so animated GIFs play (SwiftUI's `Image` shows the first frame only).
private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    /// A chipTAN graphic must flicker to be read by the TAN generator (essential motion); any other
    /// animated image respects Reduce Motion.
    var animates = true

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = animates
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
    }
}

/// Approval in the bank's app (decoupled TAN, push): a calm, centred panel instead of a line of text.
/// `waits`: MFN asks the bank by itself until it answers, so the user only has to approve.
private struct AppApproval: View {
    let request: AuthSheetPresenter.Request
    let message: String
    let waits: Bool
    let embedded: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 46
    /// What the user did here; without it the sheet ended by itself (approved in the bank's app, timed out or cancelled elsewhere).
    @State private var outcome: Outcome?
    private enum Outcome { case confirmed, cancelled }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: symbolSize, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeat(3), isActive: waits && !reduceMotion)
                .accessibilityHidden(true)
                .padding(.top, embedded ? 24 : 4)
            VStack(spacing: 6) {
                if !embedded {
                    Text("Freigabe für \(request.connectionName)")
                        .font(.headline)
                }
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if waits {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("MFN wartet auf deine Freigabe …")
                        .foregroundStyle(.secondary)
                }
                Text("Keine Nachricht bekommen? Öffne die App deiner Bank, die Freigabe wartet dort meist schon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Bestätige in der App deiner Bank und klicke danach auf „Ich habe bestätigt“.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Abbrechen", role: .cancel) { outcome = .cancelled; model.presenter.cancel(request.id) }
                    .keyboardShortcut(.cancelAction)
                Button("Ich habe bestätigt") { outcome = .confirmed; model.presenter.respond(to: request.id, .confirmed) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 420)
        .onAppear { AccessibilityNotification.Announcement(String(localized: "Freigabe für \(request.connectionName): \(message)")).post() }
        .onDisappear {
            let text: String = switch outcome {
            case .confirmed: String(localized: "Freigabe für \(request.connectionName) bestätigt.")
            case .cancelled: String(localized: "Freigabe für \(request.connectionName) abgebrochen.")
            case nil: String(localized: "Freigabe für \(request.connectionName) beendet.")
            }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// A bank's own login page for a redirect (PSD2 over YAXI, v12): opened in the system's login window
/// (`ASWebAuthenticationSession`, no cookies kept), which ends when the page returns to MFN's own
/// scheme. MFN sees neither the page nor what is typed there; it only learns that the login ended.
struct SystemLogin: View {
    let request: AuthSheetPresenter.Request
    let webLogin: WebLoginRequest
    let embedded: Bool
    @Environment(AppModel.self) private var model
    @State private var session: ASWebAuthenticationSession?
    @State private var anchor = WindowAnchor()
    /// Which login window is the current one: a window MFN closes itself (reopen, view gone) must
    /// not cancel the consent through its callback.
    @State private var generation = Generation()
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 44

    /// The custom scheme of a completion like `mfn-yaxi://done`; `nil` for ordinary web logins.
    static func callbackScheme(of request: WebLoginRequest) -> String? {
        guard case let .urlPrefix(prefix) = request.completion, let scheme = URL(string: prefix)?.scheme?.lowercased(),
              scheme == "mfn-yaxi" else { return nil }
        return scheme
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key")
                .font(.system(size: symbolSize, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.top, embedded ? 24 : 4)
            VStack(spacing: 6) {
                if !embedded {
                    Text("Anmeldung für \(request.connectionName)")
                        .font(.headline)
                }
                Text("Melde dich im Anmeldefenster auf der Seite deiner Bank an.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("MFN wartet, bis die Anmeldung fertig ist …")
                    .foregroundStyle(.secondary)
            }
            Text(webLogin.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Abbrechen", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Fenster erneut öffnen") { start() }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 420)
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "Anmeldung für \(request.connectionName): Ein Anmeldefenster deiner Bank öffnet sich.")).post()
            if !webLogin.message.isEmpty { AccessibilityNotification.Announcement(webLogin.message).post() }
            start()
        }
        .onDisappear {
            generation.value += 1
            session?.cancel()
        }
    }

    private func start() {
        guard webLogin.url.scheme?.lowercased() == "https", let scheme = Self.callbackScheme(of: webLogin),
              case let .urlPrefix(prefix) = webLogin.completion else {
            model.presenter.fail(request.id, with: .formatChanged(detail: "login url"))
            return
        }
        // The window being replaced must not report its own end as "cancelled".
        generation.value += 1
        let mine = generation.value
        let tracker = generation
        session?.cancel()
        let id = request.id
        let presenter = model.presenter
        // The system calls this on a background queue: not main-actor isolated (crashed otherwise).
        let login = ASWebAuthenticationSession(url: webLogin.url, callback: .customScheme(scheme)) { @Sendable url, error in
            Task { @MainActor in
                guard tracker.value == mine else { return }
                if let url, url.absoluteString.hasPrefix(prefix) {
                    presenter.respond(to: id, .webSession([]))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    presenter.cancel(id)
                } else if error != nil {
                    presenter.fail(id, with: .cancelled)
                }
            }
        }
        login.prefersEphemeralWebBrowserSession = true
        login.presentationContextProvider = anchor
        session = login
        if !login.start() { presenter.fail(id, with: .cancelled) }
    }

    private func cancel() {
        generation.value += 1
        session?.cancel()
        model.presenter.cancel(request.id)
    }
}

/// Counter shared between the view and the login window's callback (main actor only).
@MainActor
private final class Generation {
    var value = 0
}

/// The window the system's login window attaches to.
private final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}
