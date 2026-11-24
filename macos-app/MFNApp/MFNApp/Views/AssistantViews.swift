import AppKit
import MFNCore
import MFNMCP
import SwiftUI

/// Settings → MCP: switch, account checklist, approved programs, setup help.
struct AssistantSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingEnable = false
    @State private var copied: String?

    private var access: AssistantAccess { model.assistantAccess }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { access.isEnabled }, set: { on in
                    if on { confirmingEnable = true } else { access.setEnabled(false) }
                })) {
                    Text("Zugang über MCP")
                    Text("Ein Programm mit MCP-Unterstützung, etwa ein Chat-Programm, ein Code-Editor oder ein lokales Modell, kann dann Salden und Umsätze lesen und Fragen dazu beantworten. Nur lesen: kein Abgleich, keine Änderungen, keine Überweisungen.")
                }
                .disabled(model.lock.isLocked)
                .accessibilityHint(model.lock.isLocked ? "MFN entsperren, um den Zugang zu ändern" : "")
                if model.lock.isLocked {
                    Text("MFN entsperren, um den Zugang zu ändern.")
                        .foregroundStyle(.secondary)
                }
                if let problem = access.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if access.isEnabled {
                    LabeledContent("Verbunden") {
                        Text(access.connectedClients.isEmpty ? "Kein Assistent" : access.connectedClients.map(\.displayName).joined(separator: ", "))
                    }
                }
            } header: {
                Text("MCP")
            } footer: {
                Text("Mit einem Cloud-Modell verlassen die Daten deinen Mac. Antworten gibt es nur, solange MFN entsperrt ist.")
                    .foregroundStyle(.secondary)
            }

            if !model.lock.isLocked {
                Section {
                    if model.ledger.accounts.isEmpty {
                        Text("Noch keine Konten.").foregroundStyle(.secondary)
                    }
                    ForEach(model.ledger.accounts) { account in
                        Toggle(isOn: Binding(get: { access.isShared(account.id) }, set: { access.setShared($0, account.id) })) {
                            Text(model.ledger.displayName(of: account))
                            Text(model.ledger.connections.first { $0.id == account.connectionID }?.displayName ?? "")
                        }
                    }
                } header: {
                    Text("Freigegebene Konten")
                } footer: {
                    Text("Nicht freigegebene Konten gibt es für den Assistenten nicht. Neue Konten sind freigegeben, bis du sie hier abwählst.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if access.approvedClients.isEmpty {
                    Text("Noch keine. Beim ersten Zugriff eines Programms fragt MFN nach.")
                        .foregroundStyle(.secondary)
                }
                ForEach(access.approvedClients) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name)
                            Text(client.key)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        Button("\(client.name) entfernen", systemImage: "trash") { access.removeApproval(client) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Erlaubnis entfernen: MFN fragt beim nächsten Zugriff wieder")
                            .accessibilityHint("MFN fragt beim nächsten Zugriff wieder")
                            .disabled(model.lock.isLocked)
                    }
                }
            } header: {
                Text("Immer erlaubt")
            }

            Section {
                SetupStep(number: 1, title: "Zugang oben einschalten und die Konten wählen, die der Assistent sehen darf.")
                VStack(alignment: .leading, spacing: 8) {
                    SetupStep(number: 2, title: "Am einfachsten: Diesen Satz in den Chat deines Assistenten einfügen. Assistenten, die ihre Einstellungen selbst ändern können (etwa in einem Code-Editor oder im Terminal), richten den Zugang damit selbst ein:")
                    CodeBlock(text: Self.agentPrompt, copyLabel: "Satz kopieren") { copy(Self.agentPrompt, as: "Satz") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SetupStep(number: 3, title: "Oder von Hand: In deinem Programm einen MCP-Server eintragen. Die meisten Programme haben dafür eine Konfigurationsdatei im JSON-Format; dort kommt dieser Block hinein:")
                    CodeBlock(text: Self.jsonFile, copyLabel: "JSON kopieren") { copy(Self.jsonFile, as: "JSON") }
                    Text("Steht in der Datei schon „mcpServers“, füge nur den Eintrag „moneyfornothing“ in die vorhandenen Klammern ein.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 28)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SetupStep(number: 4, title: "Fragt dein Programm stattdessen in einem Formular: Name „moneyfornothing“, Typ „stdio“ (lokaler Befehl), ohne Argumente, und als Befehl dieser Pfad:")
                    CodeBlock(text: AssistantAccess.helperPath, copyLabel: "Pfad kopieren") { copy(AssistantAccess.helperPath, as: "Pfad") }
                    Button("Helfer im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AssistantAccess.helperPath)])
                    }
                    .buttonStyle(.link)
                    .padding(.leading, 28)
                }
                SetupStep(number: 5, title: "Programm neu starten und eine Frage zu deinen Finanzen stellen. Beim ersten Zugriff fragt MFN, ob das Programm lesen darf.")
                if let copied {
                    Label("\(copied) in die Zwischenablage kopiert", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if !Self.isInApplications {
                    Label("MFN liegt nicht im Ordner „Programme“. Verschiebst du die App später, ändert sich der Pfad, und dein Programm findet den Helfer nicht mehr.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Einrichtung")
            }

            Section {
                LabeledContent {
                    Button("Öffnen …") { openWindow(id: AssistantLogView.windowID) }
                        .help("Protokoll der Zugriffe (⌥⌘A)")
                } label: {
                    Text("Protokoll der Zugriffe")
                    Text("Jeder Aufruf mit Zeit, Programm und Werkzeug, ohne Inhalte. ⌥⌘A")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Zugang über MCP einschalten?", isPresented: $confirmingEnable) {
            Button("Einschalten") { access.setEnabled(true) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(Self.warning)
        }
    }

    static let warning = """
    Ein Assistent, den du verbindest, kann Salden, Umsätze und die Namen von Gegenparteien der freigegebenen Konten lesen.

    Mit einem Cloud-Modell verlassen diese Daten deinen Mac und gehen an den Anbieter des Modells. Mit einem lokalen Modell bleiben sie auf dem Mac. MFN kann nicht erkennen, welches Modell verbunden ist.

    Verwendungszwecke und Namen in Umsätzen schreiben andere. Solche Texte könnten versuchen, einen Assistenten zu steuern, besonders wenn er auch im Web suchen oder Dateien ändern darf.
    """

    /// For assistants that can change their own configuration: one sentence that says exactly
    /// what to add (name, transport, command, no arguments).
    static var agentPrompt: String {
        "Richte bitte einen lokalen MCP-Server ein: Name „moneyfornothing“, Typ stdio, Befehl \"\(AssistantAccess.helperPath)\", ohne Argumente und ohne Umgebungsvariablen. Er gibt nur Lesezugriff auf meine Finanzdaten in MoneyForNothing."
    }

    /// A complete configuration file as most MCP programs read it (`mcpServers`).
    static var jsonFile: String {
        """
        {
          "mcpServers": {
            "moneyfornothing": {
              "command": "\(AssistantAccess.helperPath)"
            }
          }
        }
        """
    }

    static var isInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        AccessibilityNotification.Announcement("\(kind) kopiert").post()
        // The note goes away again, so a second copy shows up as new.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == kind { copied = nil }
        }
    }
}

/// "MCP-Zugriffe" window (⌥⌘A): time, program, tool, result, count. Never arguments or results.
struct AssistantLogView: View {
    static let windowID = "assistant-log"
    @Environment(AppModel.self) private var model

    var body: some View {
        let access = model.assistantAccess
        VStack(spacing: 0) {
            if access.activity.isEmpty {
                ContentUnavailableView("Noch keine Zugriffe", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Hier erscheint jeder Aufruf über MCP."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            Table(access.activity) {
                TableColumn("Zeit") { entry in
                    Text(entry.date.formatted(date: .numeric, time: .standard)).monospacedDigit()
                }
                .width(min: 130, ideal: 150)
                TableColumn("Programm", value: \.client)
                TableColumn("Werkzeug", value: \.tool)
                TableColumn("Ergebnis") { entry in
                    Label(Self.outcome(entry.outcome), systemImage: Self.symbol(entry.outcome))
                }
                TableColumn("Werte") { entry in
                    Text("\(entry.count)").monospacedDigit()
                        .accessibilityLabel(entry.count == 1 ? "1 Wert" : "\(entry.count) Werte")
                }
                .width(min: 50, ideal: 60)
            }
            .accessibilityLabel("Zugriffe über MCP")
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(access.isEnabled ? "Zugang eingeschaltet" : "Zugang ausgeschaltet")
                    Text("Bleibt nur, bis MFN beendet wird. Fragen und Antworten werden nicht gespeichert.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Leeren") { access.clearLog() }
                    .disabled(access.activity.isEmpty)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 560, minHeight: 280)
    }

    static func outcome(_ outcome: MCPActivity.Outcome) -> String {
        switch outcome {
        case .answered: "Beantwortet"
        case .toolError: "Fehlerhafte Anfrage"
        case .locked: "Gesperrt"
        case .refused: "Abgelehnt"
        case .rateLimited: "Zu viele Anfragen"
        case .failed: "Fehler"
        }
    }

    static func symbol(_ outcome: MCPActivity.Outcome) -> String {
        switch outcome {
        case .answered: "checkmark.circle"
        case .toolError: "questionmark.circle"
        case .locked: "lock"
        case .refused: "hand.raised"
        case .rateLimited: "hourglass"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// Menu item for the log window (every command has a menu item and a shortcut).
struct AssistantLogCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MCP-Zugriffe") { openWindow(id: AssistantLogView.windowID) }
            .keyboardShortcut("a", modifiers: [.command, .option])
    }
}

/// Menu bar panel: a quiet line while an assistant is connected.
struct AssistantIndicator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let clients = model.assistantAccess.connectedClients
        if model.assistantAccess.isEnabled, !clients.isEmpty {
            Button {
                openWindow(id: AssistantLogView.windowID)
            } label: {
                Label("MCP-Programm verbunden: \(clients.map(\.displayName).joined(separator: ", "))", systemImage: "point.3.connected.trianglepath.dotted")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.borderless)
            .help("Protokoll der Zugriffe öffnen (⌥⌘A)")
        }
    }
}

/// Toolbar of the main window while an assistant is connected: opens the log.
struct AssistantToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let names = model.assistantAccess.connectedClients.map(\.displayName).joined(separator: ", ")
        Button("MCP-Programm verbunden", systemImage: "point.3.connected.trianglepath.dotted") { openWindow(id: AssistantLogView.windowID) }
            .help("MCP-Programm verbunden: \(names). Protokoll öffnen (⌥⌘A)")
            .accessibilityLabel("MCP-Programm verbunden: \(names)")
    }
}

/// One numbered step of the setup.
private struct SetupStep: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text to copy into another program: monospaced, selectable, with its own copy button.
private struct CodeBlock: View {
    let text: String
    let copyLabel: String
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
            Button(copyLabel, systemImage: "doc.on.doc", action: copy)
                .labelStyle(.iconOnly)
                .help(copyLabel)
        }
        .padding(.leading, 28)
    }
}
