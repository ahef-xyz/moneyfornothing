import MFNCore
import SwiftUI

/// Approval for decoupled TAN, 2FA code, push confirmation and web login (visible or headless).
///
/// Shown as sheet for syncs, and inline in the setup assistant (`embedded`).
struct AuthChallengeSheet: View {
    let request: AuthSheetPresenter.Request
    var embedded = false
    @Environment(AppModel.self) private var model
    @State private var code = ""

    var body: some View {
        switch request.challenge {
        case let .webLogin(webLogin) where webLogin.automation != nil:
            HeadlessLoginView(request: request, webLogin: webLogin, showsHeader: !embedded)
                .id(request.id)
        case let .webLogin(webLogin):
            WebLoginView(request: request, webLogin: webLogin)
                .id(request.id)
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
            case let .decoupled(message, _), let .pushConfirm(message):
                Text(message)
                buttons(confirmTitle: "Ich habe bestätigt") { model.presenter.respond(to: request.id, .confirmed) }
            case let .code(prompt, length):
                Text(prompt)
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .monospacedDigit()
                    .onSubmit(submitCode)
                buttons(confirmTitle: "Bestätigen", disabled: code.count != length, action: submitCode)
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
        case let .decoupled(message, _), let .pushConfirm(message): "Freigabe für \(request.connectionName): \(message)"
        case let .code(prompt, _): "Freigabe für \(request.connectionName): \(prompt)"
        case .webLogin: "Freigabe für \(request.connectionName)"
        }
    }

    private func submitCode() {
        guard case let .code(_, length) = request.challenge, code.count == length else { return }
        let entered = code
        code = ""
        model.presenter.respond(to: request.id, .code(entered))
    }

    @ViewBuilder
    private func buttons(confirmTitle: String?, disabled: Bool = false, action: @escaping () -> Void) -> some View {
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
