import AppKit
import MFNCore
import SwiftUI

enum MainWindow {
    static let id = "main"
}

/// Panel of the menu bar icon, in sections: header with sync state, total, banks, overview lists
/// (click opens MFN there), actions. Locked: only "Entsperren" (the database is closed).
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var isLocked: Bool { model.lock.isLocked || model.vaultPrompt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLocked {
                locked
            } else {
                total
                Divider()
                banks
                Divider()
                lists
            }
            Divider()
            actions
        }
        .frame(width: 320)
        .environment(\.amountArea, .menuBar)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image(for: model.appIcon))
                .accessibilityHidden(true)
            Text("MoneyForNothing")
                .font(.headline)
            Spacer()
            if !isLocked {
                syncState
                Button {
                    model.syncAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isSyncing)
                .help("Alle Konten abgleichen (⌘R)")
                .accessibilityLabel("Alle Konten abgleichen")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var isSyncing: Bool {
        model.orderedConnections.contains { model.syncState($0.id).phase == .syncing }
    }

    @ViewBuilder
    private var syncState: some View {
        if isSyncing {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Abgleich läuft")
        } else if let last = model.lastCompleteSync {
            Text(DayFormat.shortSyncTime(last))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Letzter vollständiger Abgleich: \(DayFormat.syncTime(last))")
        }
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Gesperrt", systemImage: "lock.fill")
                .font(.title3.weight(.semibold))
            Text("Entsperren, um Salden und Banken zu sehen.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Entsperren") {
                if model.vaultPrompt != nil {
                    openMainWindow()
                } else {
                    Task { await model.lock.unlock() }
                }
            }
            .disabled(model.lock.isAuthenticating)
        }
        .padding(14)
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle("Gesamt")
            AmountText(cents: model.totalBalanceCents, colorsInflow: false)
                .font(.title.weight(.semibold))
            Text("\(model.snapshot.accounts.count) Konten bei \(model.orderedConnections.count) Banken")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var banks: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle("Banken")
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            if model.orderedConnections.isEmpty {
                Text("Noch keine Bank")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            ForEach(model.orderedConnections) { connection in
                PanelRow {
                    openMainWindow(selecting: model.orderedAccounts(of: connection.id).first.map { .account($0.id) })
                } content: {
                    BankLine(connection: connection)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle("Übersicht")
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            PanelRow {
                openMainWindow(selecting: .pending)
            } content: {
                RowIcon(systemName: "hourglass")
                Text("Vorgemerkt")
                Spacer()
                AmountText(cents: model.pendingTotalCents, colorsInflow: false)
                    .foregroundStyle(.secondary)
            }
            PanelRow {
                openMainWindow(selecting: .review)
            } content: {
                RowIcon(systemName: "checklist")
                Text("Zu prüfen")
                Spacer()
                if model.reviewCount > 0 {
                    AccentBadge(text: "\(model.reviewCount)")
                } else {
                    Text("nichts").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// One compact line: open MFN, then small icon buttons (tooltips name them).
    private var actions: some View {
        HStack(spacing: 6) {
            Button("MFN öffnen") { openMainWindow() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Spacer()
            Button {
                model.hideAmounts.toggle()
            } label: {
                Image(systemName: model.hideAmounts ? "eye" : "eye.slash")
            }
            .disabled(model.lock.isLocked)
            .help(model.hideAmounts ? "Beträge einblenden (⇧⌘H)" : "Beträge ausblenden (⇧⌘H)")
            .accessibilityLabel(model.hideAmounts ? "Beträge einblenden" : "Beträge ausblenden")
            // Without a Dock icon there is no app menu: Settings must be reachable from here.
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Einstellungen (⌘,)")
            .accessibilityLabel("Einstellungen")
            Button {
                AppDelegate.quitRequested = true
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("MFN beenden (auch in der Menüleiste)")
            .accessibilityLabel("MFN beenden")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openMainWindow(selecting item: SidebarItem? = nil) {
        // Back from ⌘Q (menu bar only): Dock icon again unless "Nur in der Menüleiste" is on.
        DockPresence.apply(force: true)
        if let item { model.selection = item }
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

/// Fixed-width symbol, as wide as the bank icons, so all row titles start on one line.
private struct RowIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Clickable row with a menu-like hover highlight.
private struct PanelRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

private struct BankLine: View {
    let connection: Connection
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.showBankIcons) private var showIcons = true

    var body: some View {
        let state = model.syncState(connection.id)
        if showIcons {
            BankBadge(connection: connection, size: 18)
        }
        Text(connection.displayName)
            .lineLimit(1)
        switch state.phase {
        case .syncing:
            ProgressView().controlSize(.mini).accessibilityLabel("Wird abgeglichen")
        case .waitingForApproval:
            Image(systemName: "person.badge.key").foregroundStyle(.orange).help("Anmeldung nötig")
                .accessibilityLabel("Anmeldung nötig")
        case let .failed(error):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Fehler: \(error.description)")
                .accessibilityLabel("Fehler: \(error.description)")
        case .storeFailed:
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
                .accessibilityLabel("Speichern fehlgeschlagen")
        case .idle:
            EmptyView()
        }
        Spacer(minLength: 8)
        AmountText(cents: model.totalBalanceCents(of: connection.id), colorsInflow: false, muted: true)
    }
}

/// The app icon (the chosen variant) at menu bar size, in colour, not as template.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    @MainActor
    static func image(for choice: AppIconChoice, style: MenuBarIconStyle = .appIcon) -> NSImage {
        // The pick asset is a template image (asset catalog): macOS draws it black or white.
        if style == .pick, let pick = NSImage(named: "MenuBarPick") {
            pick.size = size
            pick.isTemplate = true
            return pick
        }
        let source = NSImage(named: choice.imageName) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        // App icons keep ~10 % transparent margin per side (macOS icon grid): crop it, so the
        // artwork fills the menu bar slot.
        let margin = 0.1
        let crop = NSRect(origin: .zero, size: source.size)
            .insetBy(dx: source.size.width * margin, dy: source.size.height * margin)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}
