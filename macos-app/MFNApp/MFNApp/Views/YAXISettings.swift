import MFNYAXI
import SwiftUI

/// Settings → Banken → YAXI: the user's own YAXI key (docs/v0.7.0.md section 7).
struct YAXIKeySettings: View {
    @Environment(AppModel.self) private var model
    @State private var keyID = ""
    @State private var secret = ""
    @State private var environment: YAXIEnvironment = .production
    @State private var confirmingRemoval = false

    // A literal URL; a failure here is a programming error any launch of Settings would show.
    private static let hubURL = URL(string: "https://hub.yaxi.tech/sign-in")!

    private var access: YAXIAccess { model.yaxiAccess }

    var body: some View {
        Section {
            switch access.keyState {
            case let .stored(environment):
                LabeledContent("Schlüssel") {
                    HStack {
                        Text(environment == .production ? "gesichert, Live-Betrieb" : "gesichert, Testumgebung")
                            .foregroundStyle(.secondary)
                        Button("Entfernen …", role: .destructive) { confirmingRemoval = true }
                    }
                }
            case .unreadable:
                Text("Der Schlüssel im Schlüsselbund lässt sich nicht lesen.")
                    .foregroundStyle(.red)
            case .none:
                EmptyView()
            }
            if access.hasKey || access.callsThisMonth > 0 {
                LabeledContent("Aufrufe diesen Monat") {
                    Text("\(access.callsThisMonth.formatted()) von \(YAXIUsage.freeCalls.formatted()) frei")
                        .monospacedDigit()
                        .foregroundStyle(access.callsThisMonth >= YAXIUsage.freeCalls ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                if access.callsThisMonth >= YAXIUsage.freeCalls {
                    Label("Kontingent aufgebraucht. Was YAXI mit weiteren Aufrufen macht, zeigt dein YAXI Hub.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if Double(access.callsThisMonth) >= Double(YAXIUsage.freeCalls) * YAXIUsage.pauseShare {
                    Label("Der automatische Abgleich über YAXI pausiert bis zum Monatsende. Abgleichen von Hand geht weiter und kann über das freie Kontingent hinausgehen.", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Schlüssel-ID", text: $keyID, prompt: Text("api-key-…"))
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Geheimer Schlüssel", text: $secret)
            Picker("Umgebung", selection: $environment) {
                Text("Live-Betrieb").tag(YAXIEnvironment.production)
                Text("Testumgebung").tag(YAXIEnvironment.integration)
            }
            HStack {
                if let message = access.checkMessage {
                    Label(message, systemImage: access.checkFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(access.checkFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if access.isChecking { ProgressView().controlSize(.small).accessibilityLabel("Schlüssel wird geprüft") }
                Button(access.hasKey ? "Ersetzen" : "Prüfen und sichern") {
                    let id = keyID, value = secret, environment = environment
                    Task {
                        await access.checkAndSave(keyID: id, secret: value, environment: environment)
                        if !access.checkFailed {
                            keyID = ""
                            secret = ""
                        }
                    }
                }
                .disabled(keyID.isEmpty || secret.isEmpty || access.isChecking)
            }
        } header: {
            HStack(spacing: 6) {
                Text("YAXI")
                BetaBadge()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Mit einem eigenen Zugang bei YAXI erreicht MFN über tausend weitere Banken („Andere Bank über YAXI …“ im Assistenten). YAXI meldet sich in einer geprüften, verschlüsselten Umgebung bei der Bank an und kann deine Daten dabei nicht lesen. Diese Verbindungen laufen über YAXI statt direkt von deinem Mac zur Bank.")
                Text("Die Anbindung über YAXI ist neu und noch im Beta-Stadium.")
                Text("Der Schlüssel liegt nur im Schlüsselbund dieses Macs und ist nie Teil einer Sicherung. MFN stellt damit nur Abrufe von Konten, Salden und Umsätzen aus; die Prüfung kostet einen Aufruf. MFN zählt die Aufrufe auf diesem Mac und gleicht Banken über YAXI automatisch höchstens alle 4 Stunden ab.")
                Link("Zugang im YAXI Hub anlegen", destination: Self.hubURL)
            }
        }
        .onAppear { access.refreshUsage() }
        .onChange(of: access.checkMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .confirmationDialog("YAXI-Schlüssel entfernen?", isPresented: $confirmingRemoval) {
            Button("Entfernen", role: .destructive) { access.remove() }
        } message: {
            Text("Banken über YAXI gleichen dann nicht mehr ab, bis du wieder einen Schlüssel sicherst. Ihre Konten und Umsätze bleiben.")
        }
    }
}
