import AppKit
import CoreImage.CIFilterBuiltins
import MFNCore
import MFNScrape
import SwiftUI

/// Headless web login (`WebLoginRequest.automation`, protocol v4): no web view, only bank,
/// status line, progress, a code field when the script asks for one, and "Abbrechen".
///
/// Missing (or incomplete) credentials are asked for first with the connector's
/// `credentialFields`, saved to the keychain, and the login continues. Used in the approval
/// sheet and inline in the setup assistant (`showsHeader == false`, `onCancel` set).
struct HeadlessLoginView: View {
    let request: AuthSheetPresenter.Request
    let webLogin: WebLoginRequest
    var showsHeader = true
    @Environment(AppModel.self) private var model
    @State private var controller: WebLoginController?
    @State private var needsCredentials = false
    @State private var values: [String: String] = [:]
    @State private var code = ""
    @State private var error: String?

    private var connector: ConnectorID { request.connection.connectorID }

    private var statusText: String {
        controller?.headless?.status ?? webLogin.automation?.message ?? webLogin.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(spacing: 10) {
                    ConnectorBadge(connector: connector, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anmeldung bei \(request.connectionName)")
                            .font(.headline)
                        Text(webLogin.url.host() ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if needsCredentials {
                credentialsForm
            } else {
                progress
                if let controller, controller.isRevealed {
                    Text("Beantworte hier die Abfrage der Bank, z. B. „Ich bin ein Mensch“. MFN meldet sich danach selbst weiter an.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WebViewContainer(webView: controller.webView)
                        // Takes the width it is given (assistant or sheet), never more.
                        .frame(minWidth: 360, idealWidth: 520, maxWidth: .infinity, minHeight: 320, idealHeight: 400, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
                }
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button(needsCredentials ? "Abbrechen" : "Anmeldung abbrechen", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let controller, !needsCredentials {
                    if controller.isRevealed {
                        Button("Bankseite ausblenden") { controller.conceal() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .help("Blendet die Bankseite aus; MFN meldet sich weiter automatisch an.")
                    } else {
                        // Fallback when the login hangs: show the bank's page (e.g. click a captcha).
                        Button("Bankseite anzeigen") { controller.reveal() }
                            .help("Zeigt die Anmeldeseite der Bank, z. B. um eine Sicherheitsabfrage selbst zu beantworten.")
                    }
                }
                if needsCredentials {
                    Button("Anmelden", action: saveCredentials)
                        .keyboardShortcut(.defaultAction)
                        .disabled(CredentialForm.problem(CredentialForm.cleaned(values, for: connector).values, for: connector) != nil)
                } else if isWaitingForCode {
                    Button("Bestätigen", action: submitCode)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(controller?.accepts(code: code) ?? false))
                }
            }
        }
        .padding(showsHeader ? 20 : 0)
        .padding(.bottom, showsHeader ? 0 : 16)
        .frame(width: showsHeader ? (controller?.isRevealed == true ? 560 : 420) : nil)
        .onAppear(perform: begin)
        .onDisappear { controller?.stop() }
    }

    private var isWaitingForCode: Bool {
        if case .waitingForCode = controller?.headless?.phase { true } else { false }
    }

    @ViewBuilder
    private var progress: some View {
        if let qrCode = controller?.headless?.qrCode, let image = QRCodeImage.make(qrCode.payload) {
            // Protocol v5: drawn here from the payload, never an image from the page.
            HStack {
                Spacer()
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(.white)
                    .accessibilityLabel("QR-Code für die Anmeldung")
                Spacer()
            }
        }
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(statusText)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: statusText) { _, text in
                    AccessibilityNotification.Announcement(text).post()
                }
        }
        if case let .waitingForCode(prompt, length)? = controller?.headless?.phase {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt)
                TextField("Code", text: $code, prompt: Text(length > 0 ? String(repeating: "·", count: length) : "Code"))
                    .textContentType(.oneTimeCode)
                    .monospacedDigit()
                    .onSubmit(submitCode)
                    .frame(maxWidth: 200)
            }
        }
    }

    @ViewBuilder
    private var credentialsForm: some View {
        Text("Für die Anmeldung fehlen die Zugangsdaten. Sie werden einmal gespeichert und danach automatisch verwendet.")
            .fixedSize(horizontal: false, vertical: true)
        Form {
            CredentialForm(connector: connector, values: $values)
        }
        .formStyle(.columns)
        CredentialNote()
    }

    // MARK: Actions

    private func begin() {
        guard controller == nil, !needsCredentials else { return }
        let stored: BankCredentials?
        do {
            stored = try model.credentialStore.credentials(for: request.connection.id)
        } catch {
            stored = nil
            self.error = String(localized: "Zugangsdaten nicht lesbar: \(error.localizedDescription)")
        }
        if let credentials = HeadlessLogin.usableCredentials(stored, for: connector) {
            run(with: credentials)
        } else {
            values = stored?.values.filter { key, _ in !(connector.credentialFields.first { $0.key == key }?.isSecret ?? true) } ?? [:]
            needsCredentials = true
        }
    }

    private func saveCredentials() {
        let credentials = CredentialForm.cleaned(values, for: connector)
        guard credentials.isComplete(for: connector) else { return }
        do {
            try model.credentialStore.set(credentials, for: request.connection.id)
        } catch {
            self.error = String(localized: "Zugangsdaten konnten nicht gespeichert werden: \(error.localizedDescription)")
            return
        }
        values = [:]
        error = nil
        needsCredentials = false
        run(with: credentials)
    }

    private func run(with credentials: BankCredentials) {
        let presenter = model.presenter
        let id = request.id
        let controller = WebLoginController(request: webLogin, connection: request.connection.id, credentials: credentials) { result in
            switch result {
            case let .success(cookies): presenter.respond(to: id, .webSession(cookies))
            case let .failure(error): presenter.fail(id, with: error)
            }
        }
        self.controller = controller
        controller.start()
    }

    private func submitCode() {
        guard let controller, controller.accepts(code: code) else { return }
        let entered = code
        code = ""
        controller.submitCode(entered)
    }

    private func cancel() {
        if let controller {
            controller.cancel()
        } else {
            model.presenter.cancel(request.id)
        }
    }
}

/// QR code from a login token (protocol v5, `mfn.showQRCode`), error correction M.
enum QRCodeImage {
    static func make(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
