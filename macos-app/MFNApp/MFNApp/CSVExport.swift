import AppKit
import MFNCore
import UniformTypeIdentifiers

/// "Umsätze als CSV exportieren …" (⇧⌘E): writes what the transaction list shows (sidebar item,
/// search, filters, sort, Stornos on/off) as CSV. Format: `TransactionCSVExporter`.
/// Amounts are exported in full even with "Beträge ausblenden": the user asked for the file.
extension AppModel {
    /// The list the export covers; `nil` where no transaction list is shown (depot).
    var csvExportItem: SidebarItem? {
        guard !lock.isLocked else { return nil }
        switch selection {
        case nil, .overview?, .subscriptions?: return .allAccounts
        case let .account(id)?:
            return account(id)?.type == .depot ? nil : .account(id)
        case let item?: return item
        }
    }

    /// Read by the menu bar on every publish. Where no list is on screen (overview) it must not
    /// build the "Alle Konten" list just to count it: any transaction enables the command, and an
    /// export that turns out empty (search, filters) beeps.
    var canExportCSV: Bool {
        guard let item = csvExportItem else { return false }
        switch selection {
        case nil, .overview?, .subscriptions?: return !snapshot.transactions.isEmpty
        default: return ledgerContent(for: item).listedCount > 0
        }
    }

    func exportCSV() {
        guard let item = csvExportItem else { return }
        let ledger = ledgerContent(for: item)
        let scope = ledger.account.map(csvExportScope(of:)) ?? ledger.title
        export(ledger.ordered, scope: scope, accountName: ledger.accountName)
    }

    /// Sidebar context menu: the selected account exports what its list shows (like ⇧⌘E);
    /// any other account exports all its transactions, without the search and filters of the
    /// list on screen.
    func exportCSV(account id: AccountID) {
        guard !lock.isLocked, let account = account(id), account.type != .depot else { return }
        let item = SidebarItem.account(id)
        if selection == item {
            exportCSV()
            return
        }
        // The unfiltered list of one account, in list order (upcoming, then booked; no Stornos),
        // without building a whole `LedgerBase` (running balances, recurring, filter menus).
        // Not through `ledgerContent(for:)`, which would evict the visible list's cache.
        let ordered = unfilteredExportRows(of: id)
        let name = csvExportScope(of: account)
        export(ordered, scope: name, accountName: { _ in name })
    }

    /// "Bank Konto": the scope of the file name and the account column.
    func csvExportScope(of account: Account) -> String {
        "\(connectionName(account.connectionID)) \(account.name)"
    }

    /// All rows of one account in list order (upcoming, then booked; no Stornos), independent of
    /// the search and filters of the list on screen.
    func unfilteredExportRows(of id: AccountID) -> [MFNCore.Transaction] {
        let query = TransactionQuery()
        let source = snapshot.transactions(of: id)
        return query.sorted(source.filter(\.status.isUpcoming)) + query.sorted(source.filter { $0.status == .booked })
    }

    private func export(_ transactions: [MFNCore.Transaction], scope: String, accountName: (AccountID) -> String) {
        guard !transactions.isEmpty else {
            NSSound.beep()
            AccessibilityNotification.Announcement(String(localized: "Keine Umsätze zum Exportieren")).post()
            return
        }
        // Value snapshot of what the file needs, built off the main actor while the panel is open.
        let accountIDs = Set(transactions.map(\.accountID))
        let names = Dictionary(uniqueKeysWithValues: accountIDs.map { ($0, accountName($0)) })
        let ibans = Dictionary(uniqueKeysWithValues: accountIDs.compactMap { id in self.account(id)?.iban.map { (id, $0) } })
        let build = Task.detached(priority: .userInitiated) {
            TransactionCSVExporter.data(
                transactions,
                accountName: { names[$0] ?? $0.rawValue },
                accountIBAN: { ibans[$0] }
            )
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "Umsätze als CSV exportieren")
        panel.message = transactions.count == 1 ? String(localized: "1 Umsatz") : String(localized: "\(transactions.count) Umsätze")
        panel.prompt = String(localized: "Exportieren")
        panel.nameFieldStringValue = TransactionCSVExporter.fileName(scope: scope)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        csvExportPanel = panel
        let session = lockSession

        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if csvExportPanel === panel { csvExportPanel = nil }
            // Locked while the panel was open (`close()` cancels it): nothing is written.
            guard response == .OK, let url = panel.url, !isStale(session) else {
                build.cancel()
                return
            }
            Task { [weak self] in
                let data = await build.value
                guard let self, !isStale(session) else { return }
                do {
                    try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
                } catch {
                    // Never the content; the system's description may name the path, so it stays private.
                    Log.logger("export").error("CSV export failed: \(error.localizedDescription, privacy: .private)")
                    guard !isStale(session) else { return }
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Die CSV-Datei konnte nicht gesichert werden.")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }
}
