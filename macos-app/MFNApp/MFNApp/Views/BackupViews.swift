import AppKit
import MFNStore
import SwiftUI

/// Settings → Sicherung.
struct BackupSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var auto = model.autoBackup
        Form {
            Section {
                Button("Sicherung erstellen …") { model.createBackup() }
                    .disabled(!model.canBackUp)
                Button("Aus Sicherung wiederherstellen …") { model.chooseBackupToRestore() }
                    .disabled(!model.canRestoreBackup)
            } header: {
                Text("Sicherung")
            } footer: {
                Text("Eine Sicherung ist eine einzelne verschlüsselte Datei mit allen Konten, Umsätzen, Kategorien und Regeln. Zum Wiederherstellen brauchst du das Datenbank-Passwort, das beim Erstellen galt. Bankzugänge bleiben im Schlüsselbund dieses Macs und sind nicht enthalten.")
            }
            Section {
                Toggle("Automatisch sichern", isOn: $auto.isEnabled)
                    .onChange(of: auto.isEnabled) { model.runAutoBackupIfDue() }
                LabeledContent("Ordner") {
                    HStack {
                        Text(auto.folderPath ?? String(localized: "Nicht gewählt"))
                            .foregroundStyle(auto.folderPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Wählen …") { model.chooseAutoBackupFolder() }
                    }
                }
                Picker("Häufigkeit", selection: $auto.frequency) {
                    ForEach(AutoBackup.Frequency.allCases) { Text($0.title).tag($0) }
                }
                Picker("Aufbewahren", selection: $auto.keep) {
                    ForEach(AutoBackup.keepChoices, id: \.self) { Text("Die letzten \($0)").tag($0) }
                }
                LabeledContent("Letzte Sicherung") {
                    HStack(spacing: 8) {
                        if auto.isRunning {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Sicherung läuft")
                        }
                        Text(auto.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Noch keine"))
                            .foregroundStyle(.secondary)
                        Button("Jetzt sichern") { model.runAutoBackupIfDue(force: true) }
                            .disabled(!auto.hasFolder || auto.isRunning || !model.canBackUp || model.isDemo)
                    }
                }
                // What appears here without a click (a failure, a finished run) is also said.
                .onChange(of: auto.lastError) { _, error in
                    if let error { AccessibilityNotification.Announcement(error).post() }
                }
                .onChange(of: auto.lastSuccess) { _, date in
                    if date != nil { AccessibilityNotification.Announcement(String(localized: "Sicherung erstellt")).post() }
                }
                if let error = auto.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Automatische Sicherung")
            } footer: {
                Text(model.isDemo
                     ? "Die Demo wird nicht automatisch gesichert."
                     : "MFN sichert nach dem Entsperren und nach einem Abgleich, sobald die letzte Sicherung alt genug ist, und löscht im Ordner nur ältere eigene Sicherungen. Liegt der Ordner in iCloud Drive oder auf einem Netzlaufwerk, verlässt die verschlüsselte Datei diesen Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Password for a picked backup, and what restoring does.
struct RestoreBackupSheet: View {
    let request: RestoreRequest
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focusesPassword: Bool

    private var replacesData: Bool { model.backupStore != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aus Sicherung wiederherstellen")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Form {
                LabeledContent("Datei", value: request.url.lastPathComponent)
                LabeledContent("Erstellt", value: request.info.createdAt.formatted(date: .long, time: .shortened))
                LabeledContent("Version", value: "MFN \(request.info.appVersion)")
                LabeledContent("Größe", value: ByteCountFormatter.string(fromByteCount: Int64(request.info.databaseBytes), countStyle: .file))
                SecureField("Datenbank-Passwort", text: $password)
                    .textContentType(.password)
                    .focused($focusesPassword)
                    .onSubmit(submit)
            }
            Text(error ?? explanation)
                .font(.callout)
                .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isBackingUp {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Wiederherstellung läuft")
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { model.restoreRequest = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBackingUp)
                Button(replacesData ? "Daten ersetzen" : "Wiederherstellen", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.isBackingUp)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focusesPassword = true }
        .onChange(of: model.isBackingUp) { _, running in
            if running { AccessibilityNotification.Announcement(String(localized: "Die Sicherung wird geprüft und wiederhergestellt")).post() }
        }
        .onChange(of: error) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    private var explanation: String {
        replacesData
            ? String(localized: "Gib das Passwort ein, das beim Erstellen der Sicherung galt. Die Sicherung ersetzt deine jetzigen Daten; diese bleiben als verschlüsselte Kopie im Datenordner. Danach sperrt MFN.")
            : String(localized: "Gib das Passwort ein, das beim Erstellen der Sicherung galt. Es bleibt das Passwort deiner Datenbank.")
    }

    private func submit() {
        guard !password.isEmpty, !model.isBackingUp else { return }
        let entered = password
        Task {
            error = await model.restoreBackup(request, password: entered)
            if error == nil { password = "" }
        }
    }
}

/// Sheet and alert of the backup commands; on the root so they also show over the lock and
/// setup screens.
struct BackupPresentation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.restoreRequest) { request in
                RestoreBackupSheet(request: request)
            }
            .alert(model.backupNotice?.title ?? "", isPresented: Binding(
                get: { model.backupNotice != nil }, set: { if !$0 { model.backupNotice = nil } }
            ), presenting: model.backupNotice) { notice in
                if let previous = notice.previous {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([previous])
                        model.backupNotice = nil
                    }
                }
                Button("OK") { model.backupNotice = nil }
                    .keyboardShortcut(.defaultAction)
            } message: { notice in
                Text(notice.message)
            }
    }
}
