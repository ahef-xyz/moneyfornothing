import CryptoKit
import Foundation
import MFNCore

/// ING Deutschland over FinTS 3.0 PIN/TAN – read-only, no TAN.
///
/// - Login: Zugangsnummer (last 10 digits of the IBAN) + Internetbanking-PIN, Kunden-ID empty.
/// - Single-step security function `999` under security profile `PIN:1`, no `HKTAN` (ING rejects
///   `PIN:2` with `999` as `9010 Ungültiger Signaturaufbau`, live 2026-11-12).
/// - Transactions as MT940 (`HKKAZ`, no camt at ING), balance `HKSAL`, depot `HKWPD` (MT535).
/// - History: at most 90 days (`HIKAZS` storage period); older `since` is capped, not an error.
/// - Account without any booking answers `9010` → `ConnectorError.unsupportedAccount`.
///
/// Calls in quick succession (one sync) share one FinTS dialog; it ends with `HKEND` once no call
/// came for `idleTimeout`, after a failed call, or on `endDialog()`. Getting a new system ID
/// (`HKSYN`) is a dialog of its own, ended right away, as FinTS requires. Calls are serialised:
/// the bank never sees two parallel dialogs of the same user. BPD, UPD and the customer system
/// ID are cached between calls; persist `systemID` and pass it in next time.
public actor INGConnector: BankConnector {
    public nonisolated let id: ConnectorID = .ing
    public nonisolated let connectionID: ConnectionID

    public static let blz = "50010517"
    public static let bic = "INGDDEFFXXX"
    // The literal is a valid URL; the fallback only exists to avoid a force unwrap.
    public static let url = URL(string: "https://fints.ing.de/fints/") ?? URL(filePath: "/")
    public static let bank = FinTSBank(url: url, blz: blz)
    /// Certificate pins (see `HTTPSFinTSTransport`): intermediate and root of the chain, so the
    /// yearly server certificate renewal keeps working; a CA change fails closed. Read from the
    /// live chain on 2026-11-12: HydrantID Server CA O1 (until 2029-12), IdenTrust Commercial
    /// Root CA 1 (until 2034-01).
    public static let pinnedKeyHashes: Set<String> = [
        "/cBAj4ZKejGpprYY6JQ/qK6U2VD7WfR/PTyWLuK6pSI=",
        "MYQYUk+THuRY6C95D8Ec6sYqK9a/D6XqPdvrScWZRNk=",
    ]
    /// ING keeps 90 days of transactions for FinTS; used if `HIKAZS` has no storage period.
    public static let defaultHistoryDays = 90

    static let balanceVersions = [5, 6, 7]
    static let statementVersions = [5, 6, 7]
    static let depotVersions = [5, 6, 7]

    private let credentials: FinTSCredentials
    private let transport: any FinTSTransport
    private let product: FinTSProduct
    private let now: @Sendable () -> Date

    /// Customer system ID from `HKSYN` (`0` until the first dialog). Persist it per connection.
    public private(set) var systemID: String
    private var bpd: FinTSBPD = .empty
    private var upd: FinTSUPD = .empty

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Open dialog shared by consecutive calls, ended after `idleTimeout` without a call.
    private var shared: FinTSDialog?
    private var idleTask: Task<Void, Never>?
    /// Bumped by every call: an idle end scheduled before a later call is outdated.
    private var idleGeneration = 0
    private let idleTimeout: Duration

    private static let log = Log.logger("ing")

    /// - Parameters:
    ///   - userID: Zugangsnummer (last 10 digits of the ING IBAN).
    ///   - pin: Internetbanking-PIN. Never logged.
    ///   - transport: defaults to HTTPS against `fints.ing.de` (with `pinnedKeyHashes`).
    public init(
        connectionID: ConnectionID,
        userID: String,
        pin: String,
        transport: (any FinTSTransport)? = nil,
        pinnedKeyHashes: Set<String> = INGConnector.pinnedKeyHashes,
        product: FinTSProduct = .unregistered,
        systemID: String = "0",
        idleTimeout: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectionID = connectionID
        self.credentials = FinTSCredentials(userID: userID, customerID: "", pin: pin)
        self.transport = transport ?? HTTPSFinTSTransport(url: Self.url, pinnedKeyHashes: pinnedKeyHashes)
        self.product = product
        self.systemID = systemID.isEmpty ? "0" : systemID
        self.idleTimeout = idleTimeout
        self.now = now
    }

    // MARK: - BankConnector

    public func accounts() async throws(ConnectorError) -> [Account] {
        let upd = try await currentUPD()
        let accounts = upd.accounts.compactMap { INGMapping.account($0, connectionID: connectionID) }
        Self.log.info("ING: \(accounts.count, privacy: .public) Konten aus UPD (\(upd.accounts.count, privacy: .public) gesamt)")
        return accounts
    }

    public func balance(for account: Account) async throws(ConnectorError) -> Balance {
        let target = try await resolve(account)
        let now = now()
        if INGMapping.accountType(target) == .depot {
            let statements = try await depotStatements(target)
            let positions = statements.flatMap { INGMapping.positions($0, accountID: account.id, currency: account.currency, now: now) }
            let total = statements.count == 1 ? statements[0].totalValueCents : nil
            return Balance(
                bookedCents: total ?? positions.reduce(0) { $0 + $1.valueCents },
                currency: statements.first?.totalCurrency ?? account.currency,
                asOf: now
            )
        }
        return try await withDialog { dialog throws(ConnectorError) in
            guard target.allows("HKSAL"),
                  let version = await dialog.bpd.bestVersion(of: "HKSAL", supported: Self.balanceVersions)
            else { throw .unsupportedAccount }
            let response = try await dialog.send([FinTSSegments.balance(version: version, account: target)])
            try INGMapping.checkSegmentErrors(response)
            guard let hisal = response.segment("HISAL") else { throw .formatChanged(detail: "ING: HISAL fehlt") }
            return try INGMapping.balance(hisal, fallbackCurrency: account.currency, asOf: now)
        }.value
    }

    public func transactions(for account: Account, since: Date?) async throws(ConnectorError) -> [Transaction] {
        let target = try await resolve(account)
        guard INGMapping.accountType(target) != .depot else { return [] }

        let today = BankDay(now())
        let pages = try await withDialog { dialog throws(ConnectorError) in
            let bpd = await dialog.bpd
            guard target.allows("HKKAZ"),
                  let version = bpd.bestVersion(of: "HKKAZ", supported: Self.statementVersions)
            else { throw .unsupportedAccount }
            let from = INGMapping.statementStart(since: since, today: today, storageDays: INGMapping.storageDays(bpd, version: version))
            do throws(ConnectorError) {
                return try await dialog.sendAllPages(acceptedSegmentErrors: [INGMapping.noTransactions]) { touchdown in
                    FinTSSegments.statementMT940(version: version, account: target, from: from, to: nil, touchdown: touchdown)
                }
            } catch {
                // Some servers report 9010 on message level: then the dialog throws formatChanged.
                if case let .formatChanged(detail) = error, detail.hasPrefix("FinTS \(INGMapping.noTransactions)") {
                    throw .unsupportedAccount
                }
                throw error
            }
        }.value

        var booked = Data()
        var pending = Data()
        for response in pages {
            try INGMapping.checkSegmentErrors(response)
            for hikaz in response.segments("HIKAZ") {
                if let data = hikaz[0].components.first??.binary { booked.append(data + Data("\r\n".utf8)) }
                if let data = hikaz[1].components.first??.binary { pending.append(data + Data("\r\n".utf8)) }
            }
        }

        let sinceDay = since.map(BankDay.init)
        var result: [Transaction] = []
        do {
            for statement in try MT940Parser.parse(booked) {
                let currency = statement.currency ?? account.currency
                result += statement.entries
                    .map { INGMapping.transaction($0, accountID: account.id, currency: currency, status: .booked) }
                    .filter { transaction in sinceDay.map { transaction.effectiveDate >= $0 } ?? true }
            }
            for statement in try MT940Parser.parse(pending) {
                let currency = statement.currency ?? account.currency
                result += statement.entries.map { INGMapping.transaction($0, accountID: account.id, currency: currency, status: .pending) }
            }
        } catch {
            throw error.connectorError
        }
        Self.log.info("ING: \(result.count, privacy: .public) Umsätze aus \(pages.count, privacy: .public) Seite(n)")
        return Transaction.uniquingIDs(result)
    }

    public func cardStatements(for account: Account) async throws(ConnectorError) -> [CardStatement] {
        _ = try await resolve(account)
        return []
    }

    public func securities(for account: Account) async throws(ConnectorError) -> [SecurityPosition] {
        let target = try await resolve(account)
        guard INGMapping.accountType(target) == .depot else { return [] }
        let now = now()
        let positions = try await depotStatements(target).flatMap {
            INGMapping.positions($0, accountID: account.id, currency: account.currency, now: now)
        }
        Self.log.info("ING: \(positions.count, privacy: .public) Depotpositionen")
        return positions
    }

    // MARK: - Internals

    private func depotStatements(_ target: FinTSAccount) async throws(ConnectorError) -> [MT535Statement] {
        let pages = try await withDialog { dialog throws(ConnectorError) in
            guard target.allows("HKWPD"),
                  let version = await dialog.bpd.bestVersion(of: "HKWPD", supported: Self.depotVersions)
            else { throw .unsupportedAccount }
            return try await dialog.sendAllPages { touchdown in
                FinTSSegments.depot(version: version, account: target, touchdown: touchdown)
            }
        }.value
        var statements: [MT535Statement] = []
        for response in pages {
            try INGMapping.checkSegmentErrors(response)
            for hiwpd in response.segments("HIWPD") {
                guard let data = hiwpd[0].components.first??.binary else { continue }
                do {
                    statements.append(try MT535Parser.parse(data))
                } catch {
                    throw error.connectorError
                }
            }
        }
        return statements
    }

    /// The FinTS account behind `account`. Accounts this connection never delivered are rejected
    /// with `unsupportedAccount` – without a dialog if the UPD is already known.
    private func resolve(_ account: Account) async throws(ConnectorError) -> FinTSAccount {
        guard account.connectionID == connectionID else { throw .unsupportedAccount }
        if upd.accounts.isEmpty {
            _ = try await currentUPD()
        }
        guard let match = upd.accounts.first(where: { INGMapping.accountID($0, connectionID: connectionID) == account.id }),
              INGMapping.accountType(match) != nil
        else { throw .unsupportedAccount }
        return match
    }

    /// Fresh UPD (accounts) from a dialog init: the synchronisation dialog if there is no system
    /// ID yet, else the shared dialog, which then stays open for the calls that follow (one sync).
    private func currentUPD() async throws(ConnectorError) -> FinTSUPD {
        await acquire()
        defer { release() }
        cancelIdleEnd()
        if systemID == "0" {
            try await synchronize()
            return upd
        }
        if shared == nil { try await openShared() }
        scheduleIdleEnd()
        return upd
    }

    /// Runs `body` in the shared dialog (opened on demand), serialised with all other calls, and
    /// caches BPD, UPD and system ID afterwards. A failed call ends the dialog: after an error the
    /// bank may have aborted it.
    private func withDialog<T: Sendable>(
        _ body: @Sendable (FinTSDialog) async throws(ConnectorError) -> T
    ) async throws(ConnectorError) -> (value: T, upd: FinTSUPD) {
        await acquire()
        defer { release() }
        cancelIdleEnd()
        if systemID == "0" { try await synchronize() }
        if shared == nil { try await openShared() }
        guard let dialog = shared else { throw .bankUnavailable }

        do {
            let value = try await body(dialog)
            await absorb(dialog)
            scheduleIdleEnd()
            return (value, upd)
        } catch {
            await absorb(dialog)
            await endShared()
            throw error
        }
    }

    /// `HKSYN` in a dialog of its own, ended right away (FinTS: a new system ID needs a new dialog).
    private func synchronize() async throws(ConnectorError) {
        await endShared()
        let sync = makeDialog()
        do {
            try await FinTSDialog.run(sync, synchronize: true) { _ throws(ConnectorError) in () }
            await absorb(sync)
        } catch {
            await absorb(sync)
            throw error
        }
    }

    private func openShared() async throws(ConnectorError) {
        let dialog = makeDialog()
        do {
            _ = try await dialog.open()
        } catch {
            await dialog.close()
            await absorb(dialog)
            throw error
        }
        await absorb(dialog)
        shared = dialog
    }

    /// Ends the shared dialog now (`HKEND`). Later calls open a new one.
    public func endDialog() async {
        await acquire()
        defer { release() }
        cancelIdleEnd()
        await endShared()
    }

    private func makeDialog() -> FinTSDialog {
        FinTSDialog(
            bank: Self.bank,
            credentials: credentials,
            product: product,
            mechanism: .oneStep,
            transport: transport,
            systemID: systemID,
            bpd: bpd,
            upd: upd,
            now: now
        )
    }

    /// Keeps what the bank told us, also after a failed business part.
    private func absorb(_ dialog: FinTSDialog) async {
        let newSystemID = await dialog.systemID
        if newSystemID != "0" { systemID = newSystemID }
        bpd = await dialog.bpd
        upd = await dialog.upd
    }

    private func endShared() async {
        guard let dialog = shared else { return }
        shared = nil
        await dialog.close()
    }

    private func cancelIdleEnd() {
        idleGeneration += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleEnd() {
        cancelIdleEnd()
        let generation = idleGeneration
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.endIdle(generation)
        }
    }

    private func endIdle(_ generation: Int) async {
        await acquire()
        defer { release() }
        // A call that came meanwhile owns the dialog now; it schedules its own end.
        guard generation == idleGeneration else { return }
        idleTask = nil
        await endShared()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the lock directly to the next waiter (busy stays true).
            waiters.removeFirst().resume()
        }
    }
}
