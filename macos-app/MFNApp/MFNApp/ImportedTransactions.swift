import MFNCore
import SwiftUI

/// Rows a CSV import added (`Transaction.importID`, protocol v10): marked in the list and the
/// inspector, filterable ("Nur importierte Umsätze") and removable. Bank data is never removed;
/// the store refuses it too (`TransactionRemovalError`).

/// How many imported rows the visible snapshot has, by account and batch. Built in one pass over
/// the transactions, without decoding any JSON. Counts only: the ID lists for a removal are built
/// when one is requested (`importedIDs`), not for every snapshot.
struct ImportIndex {
    var byAccount: [AccountID: Int] = [:]
    var byBatch: [ImportBatchID: Int] = [:]
    private(set) var count = 0

    init(snapshot: LedgerSnapshot = LedgerSnapshot()) {
        for transaction in snapshot.transactions {
            guard let batch = transaction.importID else { continue }
            byAccount[transaction.accountID, default: 0] += 1
            byBatch[batch, default: 0] += 1
            count += 1
        }
    }
}

/// One confirmation: what goes and how it is described.
struct ImportRemovalRequest: Identifiable {
    let id = UUID()
    let ids: Set<TransactionID>
    /// "aus „Giro“", "dieses Imports"; completes the message.
    let scope: String?

    var title: String {
        ids.count == 1 ? "1 importierten Umsatz entfernen?" : "\(ids.count) importierte Umsätze entfernen?"
    }

    var message: String {
        let what = ids.count == 1 ? "Der Umsatz wird" : "Die Umsätze werden"
        let scopeText = scope.map { " \($0)" } ?? ""
        return "\(what)\(scopeText) aus MFN gelöscht. Umsätze aus dem Abgleich mit der Bank bleiben unverändert. "
            + "Ein erneuter Import der Datei bringt sie zurück."
    }
}

extension AppModel {
    var importIndex: ImportIndex {
        if let cache = importIndexCache, cache.revision == snapshotRevision { return cache.index }
        let index = ImportIndex(snapshot: snapshot)
        importIndexCache = (snapshotRevision, index)
        return index
    }

    func importedCount(of account: AccountID) -> Int {
        importIndex.byAccount[account] ?? 0
    }

    /// Imported rows of one import still stored.
    func importedCount(ofImport batch: ImportBatchID) -> Int {
        importIndex.byBatch[batch] ?? 0
    }

    /// Every ID is an imported row (an unknown or bank row makes it `false`).
    func areAllImported(_ ids: Set<TransactionID>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { index.transactionsByID[$0]?.importID != nil }
    }

    private var canRemoveImports: Bool { !lock.isLocked && canWriteStore && importRemoval == nil }

    /// ⌘⌫, ⌫ in the list, context menu: only when every selected row is imported.
    var canRemoveSelectedImports: Bool {
        canRemoveImports && areAllImported(selectedTransactionIDs)
    }

    /// The account of the current list (⌥⌘⌫), if it has imported rows.
    var importRemovalAccount: AccountID? {
        guard canRemoveImports, let account = selectedAccountID, importedCount(of: account) > 0 else { return nil }
        return account
    }

    func requestRemoveImports(_ ids: Set<TransactionID>) {
        guard canRemoveImports, areAllImported(ids) else { return }
        importRemoval = ImportRemovalRequest(ids: ids, scope: nil)
    }

    func requestRemoveSelectedImports() {
        requestRemoveImports(selectedTransactionIDs)
    }

    /// All imported rows of one account (sidebar context menu, ⌥⌘⌫).
    func requestRemoveImports(of account: AccountID) {
        guard canRemoveImports, importedCount(of: account) > 0 else { return }
        let ids = snapshot.transactions.lazy.filter { $0.accountID == account && $0.importID != nil }.map(\.id)
        let name = self.account(account).map { "aus „\($0.name)“" }
        importRemoval = ImportRemovalRequest(ids: Set(ids), scope: name)
    }

    /// The rows of one import still stored (inspector "Diesen Import entfernen").
    func requestRemoveImport(_ batch: ImportBatchID) {
        guard canRemoveImports, importedCount(ofImport: batch) > 0 else { return }
        let ids = snapshot.transactions.lazy.filter { $0.importID == batch }.map(\.id)
        importRemoval = ImportRemovalRequest(ids: Set(ids), scope: "dieses Imports")
    }

    /// The confirmed removal: one store write, then the hook for dependent figures.
    func confirmImportRemoval(_ request: ImportRemovalRequest) async {
        importRemoval = nil
        // The alert's task may run after a lock (or a lock and a new unlock): only rows that are
        // still stored and still imported, and only for the session that asked.
        guard !lock.isLocked, canWriteStore, areAllImported(request.ids) else { return }
        let session = lockSession
        do {
            let removal = try await removeImportedTransactions(request.ids)
            guard !isStale(session) else { return }
            selectedTransactionIDs.subtract(removal.transactions)
            // Counts only, never contents.
            Log.logger("import").info("Importierte Umsätze entfernt: \(removal.transactions.count, privacy: .public), Importe geleert: \(removal.emptiedBatches.count, privacy: .public)")
            AccessibilityNotification.Announcement(
                removal.transactions.count == 1 ? "1 Umsatz entfernt" : "\(removal.transactions.count) Umsätze entfernt"
            ).post()
            await transactionsRemoved(accounts: removal.accounts)
        } catch let error as TransactionRemovalError {
            guard !isStale(session) else { return }
            switch error {
            case .notImported:
                importRemovalFailure = "Die Auswahl enthält Umsätze aus dem Abgleich mit der Bank. Entfernt werden können nur importierte Umsätze."
            }
        } catch {
            Log.logger("import").error("Entfernen fehlgeschlagen: \(String(describing: type(of: error)), privacy: .public)")
            guard !isStale(session) else { return }
            importRemovalFailure = "Die Umsätze konnten nicht entfernt werden."
        }
    }

    /// Called after imported rows of these accounts were removed. Hook for figures that are
    /// derived from the rows, e.g. the balance of an account without a bank connection.
    func transactionsRemoved(accounts: Set<AccountID>) async {
        await recomputeManualBalances(accounts)
    }

    /// "Nur importierte Umsätze" (⌃⌘I). The overview and depots have no list: switches to
    /// "Alle Konten" first, like ⌘F.
    func toggleImportedFilter() {
        guard !lock.isLocked else { return }
        let isDepot = if case let .account(id)? = selection { account(id)?.type == .depot } else { false }
        if !ledgerQuery.onlyImported, selection == .overview || selection == .subscriptions || selection == nil || isDepot {
            selection = .allAccounts
        }
        ledgerQuery.onlyImported.toggle()
    }
}

extension ImportBatch {
    /// "CSV-Import (ING)", "CSV-Import" for generic detection.
    var sourceTitle: String {
        formatName.map { "CSV-Import (\($0))" } ?? "CSV-Import"
    }
}

/// Small marker in the list row: symbol plus tooltip; VoiceOver reads "importiert" from the
/// row's label (not colour, not the symbol alone).
struct ImportedMarker: View {
    var body: some View {
        Image(systemName: "square.and.arrow.down")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help("Aus CSV-Import")
            .accessibilityLabel("Importiert")
    }
}

/// Confirmation and failure alerts for removals, attached once to the main window.
struct ImportRemovalAlerts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert(
                model.importRemoval?.title ?? "",
                isPresented: Binding(get: { model.importRemoval != nil }, set: { if !$0 { model.importRemoval = nil } }),
                presenting: model.importRemoval
            ) { request in
                Button("Entfernen", role: .destructive) {
                    Task { await model.confirmImportRemoval(request) }
                }
                Button("Abbrechen", role: .cancel) { model.importRemoval = nil }
            } message: { request in
                Text(request.message)
            }
            .alert("Entfernen nicht möglich", isPresented: Binding(
                get: { model.importRemovalFailure != nil }, set: { if !$0 { model.importRemovalFailure = nil } }
            )) {
                Button("OK") { model.importRemovalFailure = nil }
            } message: {
                Text(model.importRemovalFailure ?? "")
            }
    }
}
