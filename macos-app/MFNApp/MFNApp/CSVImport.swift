import AppKit
import MFNCore
import Observation
import UniformTypeIdentifiers

/// One open "Umsätze aus CSV importieren" sheet: the file, the chosen account and mapping, and
/// the preview (parsed rows, new vs. already stored). Parsing lives in `MFNCore` (`CSVDocument`)
/// and runs off the main actor (`refresh`); the sheet shows `isRefreshing` meanwhile.
@MainActor
@Observable
final class CSVImportSession: Identifiable {
    let id = UUID()
    let fileName: String
    /// Accounts that can take transactions (no depots), in sidebar order.
    let accounts: [Account]
    private(set) var document: CSVDocument
    var accountID: AccountID? {
        didSet { if accountID != oldValue { refresh() } }
    }
    var includeLikelyDuplicates = false
    var isImporting = false
    var error: String?
    private(set) var result = CSVParseResult()
    private(set) var plan = CSVImportPlan()
    /// The first rows with their state, computed once per refresh (not per body pass).
    private(set) var previewRows: [CSVPreviewRow] = []
    /// A parse or plan is running; `result`, `plan` and `previewRows` are from the previous one.
    private(set) var isRefreshing = false

    @ObservationIgnored private let data: Data
    @ObservationIgnored private let stored: @MainActor (AccountID) -> [MFNCore.Transaction]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Splitting the file again (`setDelimiter`); it recomputes the preview when done, so a
    /// refresh meanwhile must not cancel it.
    @ObservationIgnored private var reparseTask: Task<Void, Never>?
    /// The user chose the decimal separator: a later column change does not detect it again.
    @ObservationIgnored private var decimalSeparatorChosen = false

    static let previewLimit = 50
    /// Mapping changes come in bursts (several pickers): parse once they settle.
    static let mappingDebounce: Duration = .milliseconds(150)

    init(fileName: String, data: Data, document: CSVDocument, accounts: [Account], accountID: AccountID?,
         stored: @escaping @MainActor (AccountID) -> [MFNCore.Transaction]) {
        self.fileName = fileName
        self.data = data
        self.document = document
        self.accounts = accounts
        self.accountID = accountID
        self.stored = stored
        refresh()
    }

    var account: Account? { accounts.first { $0.id == accountID } }

    var importCount: Int {
        plan.new.count + (includeLikelyDuplicates ? plan.likelyDuplicates.count : 0)
    }

    var problems: [CSVSkippedRow] { result.skipped.filter { $0.reason.isProblem } }

    /// Sheet closed or MFN locked: no work for a preview nobody sees.
    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        reparseTask?.cancel()
        reparseTask = nil
        isRefreshing = false
    }

    // MARK: Changes from the sheet

    func setColumn(_ column: Int?, for field: CSVField) {
        var mapping = document.mapping
        // One column holds one field.
        if let column, let other = mapping.field(at: column), other != field { mapping[other] = nil }
        mapping[field] = column
        // A signed amount and Soll/Haben exclude each other.
        if column != nil {
            switch field {
            case .amount: mapping[.debit] = nil; mapping[.credit] = nil
            case .debit, .credit: mapping[.amount] = nil
            default: break
            }
        }
        document.mapping = mapping
        // Only the amount columns decide the separator, and never over the user's own choice.
        if Self.amountFields.contains(field), !decimalSeparatorChosen {
            document.decimalSeparator = document.detectDecimalSeparator()
        }
        if mapping[.account] == nil { document.accountFilter = nil }
        refresh(after: Self.mappingDebounce)
    }

    static let amountFields: Set<CSVField> = [.amount, .debit, .credit]

    func setDecimalSeparator(_ separator: CSVDecimalSeparator) {
        decimalSeparatorChosen = true
        document.decimalSeparator = separator
        refresh()
    }

    func setAccountFilter(_ value: String?) {
        document.accountFilter = value
        refresh()
    }

    /// Splits the file again with another delimiter (off the main actor); header, mapping and
    /// decimal separator are detected anew.
    func setDelimiter(_ delimiter: CSVDelimiter) {
        guard delimiter != document.table.delimiter else { return }
        refreshTask?.cancel()
        reparseTask?.cancel()
        isRefreshing = true
        let data = self.data
        reparseTask = Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) { () -> Result<CSVDocument, CSVImportError> in
                do throws(CSVImportError) { return .success(try CSVDocument(data: data, delimiter: delimiter)) } catch { return .failure(error) }
            }.value
            guard let self, !Task.isCancelled else { return }
            reparseTask = nil
            switch parsed {
            case let .success(document):
                self.document = document
                decimalSeparatorChosen = false
                error = nil
            case let .failure(error):
                self.error = error.message
            }
            refresh()
        }
    }

    /// Parses for the chosen account and plans against its stored rows, off the main actor. A
    /// newer change cancels the running one; `delay` debounces bursts.
    private func refresh(after delay: Duration = .zero) {
        // The new split recomputes with whatever account and mapping are current then.
        guard reparseTask == nil else { return }
        refreshTask?.cancel()
        guard account != nil else {
            refreshTask = nil
            isRefreshing = false
            result = CSVParseResult()
            plan = CSVImportPlan()
            previewRows = []
            return
        }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.recompute()
        }
    }

    private func recompute() async {
        guard let account else {
            isRefreshing = false
            return
        }
        let document = self.document
        // Value copy of the stored rows; the plan runs on it off the main actor.
        let stored = self.stored(account.id)
        let limit = Self.previewLimit
        let output = await Task.detached(priority: .userInitiated) {
            let result = document.transactions(for: account)
            let plan = CSVImportPlan.make(incoming: result.transactions, stored: stored)
            return (result, plan, Self.previewRows(result: result, plan: plan, limit: limit))
        }.value
        guard !Task.isCancelled else { return }
        (result, plan, previewRows) = output
        isRefreshing = false
    }

    /// First rows for the preview with their state.
    nonisolated static func previewRows(result: CSVParseResult, plan: CSVImportPlan, limit: Int) -> [CSVPreviewRow] {
        let duplicates = Set(plan.duplicates.map(\.id))
        let likely = Set(plan.likelyDuplicates.map(\.id))
        return result.transactions.prefix(limit).map { transaction in
            let state: CSVPreviewRow.State = duplicates.contains(transaction.id) ? .duplicate
                : likely.contains(transaction.id) ? .likelyDuplicate : .new
            return CSVPreviewRow(transaction: transaction, state: state)
        }
    }
}

struct CSVPreviewRow: Identifiable, Sendable {
    enum State: Sendable {
        case new, duplicate, likelyDuplicate

        var title: String {
            switch self {
            case .new: "Neu"
            case .duplicate: "Vorhanden"
            case .likelyDuplicate: "Wohl vorhanden"
            }
        }
    }

    let transaction: MFNCore.Transaction
    let state: State
    var id: TransactionID { transaction.id }
}

extension AppModel {
    /// Largest file the importer reads (a decade of bookings is a few MB).
    nonisolated static let maxCSVImportBytes = 50 * 1_024 * 1_024

    /// Accounts that can take imported transactions (no depots), in sidebar order.
    var csvImportAccounts: [Account] {
        orderedConnections.flatMap { orderedAccounts(of: $0.id) }.filter { $0.type != .depot }
    }

    /// "Bank · Konto" for the account picker.
    func csvImportLabel(for account: Account) -> String {
        let bank = snapshot.connections.first { $0.id == account.connectionID }?.displayName
        return [bank, displayName(of: account)].compactMap(\.self).joined(separator: " · ")
    }

    /// ⇧⌘I, context menu, empty account: pick a file, then the preview sheet.
    /// `account` preselects the target; otherwise the selected account (or the first one).
    func beginCSVImport(for account: AccountID? = nil) {
        guard canImportCSV else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Wähle die CSV-Datei mit den Umsätzen aus dem Online-Banking."
        panel.prompt = "Auswählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Locked while the panel was open.
        guard canImportCSV else { return }

        // Reading and splitting a large file takes a moment: off the main actor.
        isOpeningCSV = true
        let session = lockSession
        let fileName = url.lastPathComponent
        Task { [weak self] in
            let opened = await Task.detached(priority: .userInitiated) { Self.openCSV(at: url) }.value
            guard let self, !isStale(session) else { return }
            isOpeningCSV = false
            let data: Data
            let document: CSVDocument
            switch opened {
            case let .failure(failure):
                csvImportFailure = failure.message
                return
            case let .success(opened):
                (data, document) = opened
            }
            guard canImportCSV else { return }
            let accounts = csvImportAccounts
            let preselected = [account, selectedAccountID].compactMap(\.self).first { id in accounts.contains { $0.id == id } }
                ?? accounts.first?.id
            csvImport = CSVImportSession(
                fileName: fileName, data: data, document: document, accounts: accounts, accountID: preselected,
                stored: { [weak self] id in self?.ledger.transactions(of: id) ?? [] }
            )
        }
    }

    /// Reads at most `maxCSVImportBytes + 1` bytes (a missing or wrong file size cannot let a
    /// huge file through) and splits it. The message is for the alert.
    nonisolated static func openCSV(at url: URL) -> Result<(Data, CSVDocument), CSVOpenFailure> {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                do { try handle.close() } catch {
                    Log.logger("import").error("CSV-Datei nicht geschlossen: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
            data = try handle.read(upToCount: maxCSVImportBytes + 1) ?? Data()
        } catch {
            Log.logger("import").error("CSV-Datei nicht gelesen: \(String(describing: type(of: error)), privacy: .public)")
            return .failure(CSVOpenFailure(message: "Die Datei konnte nicht gelesen werden."))
        }
        guard data.count <= maxCSVImportBytes else {
            return .failure(CSVOpenFailure(message: "Die Datei ist zu groß (mehr als 50 MB)."))
        }
        do {
            return .success((data, try CSVDocument(data: data)))
        } catch {
            return .failure(CSVOpenFailure(message: error.message))
        }
    }
}

struct CSVOpenFailure: Error {
    let message: String
}
