import AppKit
import MFNStore
import SwiftUI

/// Choose the password on first start, or enter it once for a database whose key is not on this Mac.
struct VaultPasswordView: View {
    let prompt: AppModel.VaultPrompt
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var focusesPassword: Bool

    private var isSetup: Bool { prompt == .setup }

    private var canSubmit: Bool {
        guard !model.isWorking, !password.isEmpty else { return false }
        if isSetup {
            return password.count >= LedgerVault.minimumPasswordLength && password == confirmation
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Image(nsImage: model.appIcon.image)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(isSetup ? "Willkommen bei MoneyForNothing" : "Passwort eingeben")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(isSetup
                         ? "Lege ein Passwort für deine Daten fest."
                         : "Der Schlüssel zu dieser Datenbank ist noch nicht auf diesem Mac. Gib einmal das Passwort ein; danach genügt \(AppLock.biometryAvailable ? "Touch ID" : "das Passwort deines Macs").")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isSetup {
                    VStack(alignment: .leading, spacing: 10) {
                        Fact(symbol: "lock.shield", text: "Deine Daten liegen verschlüsselt auf diesem Mac, nie in einer Cloud.")
                        Fact(symbol: AppLock.biometryAvailable ? "touchid" : "lock.open",
                             text: AppLock.biometryAvailable
                                ? "Im Alltag entsperrst du mit Touch ID oder dem Passwort deines Macs."
                                : "Im Alltag entsperrst du mit dem Passwort deines Macs.")
                        Fact(symbol: "key", text: "Dieses Passwort brauchst du nur, um die Daten auf einem anderen Mac zu öffnen. Ohne es sind sie dort nicht lesbar – bewahre es sicher auf.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Passwort", text: $password)
                        .textContentType(isSetup ? .newPassword : .password)
                        .focused($focusesPassword)
                        .onSubmit(submit)
                    if isSetup {
                        SecureField("Passwort wiederholen", text: $confirmation)
                            .textContentType(.newPassword)
                            .onSubmit(submit)
                        VStack(alignment: .leading, spacing: 4) {
                            Requirement(met: password.count >= LedgerVault.minimumPasswordLength,
                                        text: "Mindestens \(LedgerVault.minimumPasswordLength) Zeichen – ein Satz aus mehreren Wörtern ist gut")
                            Requirement(met: !confirmation.isEmpty && password == confirmation,
                                        text: "Beide Eingaben stimmen überein")
                        }
                        .padding(.top, 2)
                    }
                    if let error = model.vaultError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)

                HStack(spacing: 12) {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    if isSetup {
                        // A new Mac, or starting over: the data comes from a backup file.
                        Button("Aus Sicherung wiederherstellen …") { model.chooseBackupToRestore() }
                            .buttonStyle(.link)
                            .disabled(!model.canRestoreBackup)
                    }
                    Spacer()
                    Button("Abbrechen", role: .cancel) { model.cancelPasswordPrompt() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                    Button(isSetup ? "Passwort festlegen" : "Öffnen", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSubmit)
                }
            }
            .frame(maxWidth: 420)
            Spacer()
            LockFooter()
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focusesPassword = true }
        .onChange(of: model.vaultError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let entered = password
        Task {
            await model.submitPassword(entered)
            if model.vaultPrompt == nil {
                password = ""
                confirmation = ""
            }
        }
    }
}

/// One line of the explanation on the setup screen.
private struct Fact: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Password rule with a live check mark (symbol and text, not colour alone).
private struct Requirement: View {
    let met: Bool
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(met ? "erfüllt" : "noch nicht erfüllt")
    }
}
