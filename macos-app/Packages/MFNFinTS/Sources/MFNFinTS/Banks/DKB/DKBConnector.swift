import Foundation
import MFNCore

/// DKB over FinTS 3.0 PIN/TAN with decoupled TAN (DKB-App, security function `942`).
///
/// Accounts from the UPD: Giro, Tagesgeld, Depot and the Visa credit card (own account in
/// `HIUPD`, `Account.type = .card`, `cardLast4` from the card number). Transactions via
/// `HKCAZ` (camt.052, booked + pending), fallback `HKKAZ` (MT940/MT942).
/// Balances via `HKSAL`, depot via `HKWPD` (MT535). SWIFT parsers: `DKBStatementParsers.standard`.
///
/// Every call runs one FinTS dialog; `HKEND` is always sent. Approvals the bank demands — on
/// dialog init, every 90 days, or for history older than 90 days — go through
/// `DecoupledTANHandler` and the `AuthChallengePresenter`, never silently dropped.
/// Calls are serialised: the DKB never sees two parallel dialogs from one connection.
public actor DKBConnector: BankConnector {
    public nonisolated let id: ConnectorID = .dkb
    public nonisolated let connectionID: ConnectionID

    public static let bank: FinTSBank = {
        guard let url = URL(string: "https://fints.dkb.de/fints") else {
            // Programming error: the literal above is a valid URL.
            fatalError("Invalid DKB FinTS URL literal")
        }
        return FinTSBank(url: url, blz: "12030000")
    }()

    /// Certificate pins (see `HTTPSFinTSTransport`): intermediate and root of the chain, so the
    /// server certificate renewal keeps working; a CA change fails closed. Read from the live
    /// chain on 2026-11-12: Sectigo Public Server Authentication CA EV E36 (until 2036-03), Sectigo
    /// Public Server Authentication Root E46 (until 2046-03).
    public static let pinnedKeyHashes: Set<String> = [
        "8TouHGz9Tit9U91wl1VTO/91vnfwG2Z+TvVmzB5rN7w=",
        "EdsvlytFf4a/O+hCPwBXFFi46RKXqivCAF+mO7s+5Ng=",
    ]

    /// DKB-App (decoupled).
    public static let securityFunction = "942"
    static let balanceVersions = [5, 6, 7]
    static let statementVersions = [5, 6, 7]
    static let camtVersions = [1]
    static let depotVersions = [5, 6, 7]
    static let defaultCAMTFormat = "urn:iso:std:iso:20022:tech:xsd:camt.052.001.02"

    private let credentials: FinTSCredentials
    private let product: FinTSProduct
    private let transport: any FinTSTransport
    private let presenter: (any AuthChallengePresenter)?
    private let stateStore: any DKBStateStore
    private let clock: any DecoupledClock
    private let parsers: DKBStatementParsers
    private let tanMedium: String?
    private let now: @Sendable () -> Date

    private var bpd: FinTSBPD?
    private var upd: FinTSUPD = .empty
    private var systemID: String?
    private var creditLimits: [AccountID: Int] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let log = Log.logger("dkb")

    /// - Parameters:
    ///   - credentials: Anmeldename (`userID`) + PIN; the customer ID stays empty.
    ///   - transport: defaults to HTTPS against `fints.dkb.de` with `pinnedKeyHashes`.
    ///   - stateStore: persists the system ID (`KeychainDKBStateStore` in the app).
    ///   - parsers: MT940/MT535 (fallback statement format, depot); default `.standard`.
    public init(
        connectionID: ConnectionID,
        credentials: FinTSCredentials,
        presenter: (any AuthChallengePresenter)?,
        transport: (any FinTSTransport)? = nil,
        product: FinTSProduct = .unregistered,
        stateStore: any DKBStateStore = InMemoryDKBStateStore(),
        clock: any DecoupledClock = SystemDecoupledClock(),
        parsers: DKBStatementParsers = .standard,
        tanMedium: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectionID = connectionID
        self.credentials = credentials
        self.presenter = presenter
        self.transport = transport ?? HTTPSFinTSTransport(url: Self.bank.url, pinnedKeyHashes: Self.pinnedKeyHashes)
        self.product = product
        self.stateStore = stateStore
        self.clock = clock
        self.parsers = parsers
        self.tanMedium = tanMedium
        self.now = now
    }

    // MARK: - BankConnector

    public func accounts() async throws -> [Account] {
        try await withDialog { _ throws(ConnectorError) in () }
        var seen: Set<AccountID> = []
        let accounts = upd.accounts.compactMap { fints -> Account? in
            let id = DKBMapping.accountID(fints)
            guard seen.insert(id).inserted else { return nil }
            return DKBMapping.account(fints, connectionID: connectionID, creditLimitCents: creditLimits[id])
        }
        Self.log.info("DKB: \(accounts.count, privacy: .public) Konten (\(self.upd.accounts.count, privacy: .public) in UPD)")
        return accounts
    }

    public func balance(for account: Account) async throws -> Balance {
        try check(account)
        let asOf = now()
        return try await withDialog { dialog throws(ConnectorError) in
            let fints = try self.fintsAccount(for: account)
            let bpd = await dialog.bpd
            let canQueryBalance = fints.allows("HKSAL") && bpd.bestVersion(of: "HKSAL", supported: Self.balanceVersions) != nil
            if account.type == .depot, !canQueryBalance || self.parsers.mt535 != nil {
                let positions = try await self.fetchSecurities(dialog: dialog, fints: fints, account: account, asOf: asOf)
                return Balance(bookedCents: positions.reduce(0) { $0 + $1.valueCents }, currency: account.currency, asOf: asOf)
            }
            guard canQueryBalance, let version = bpd.bestVersion(of: "HKSAL", supported: Self.balanceVersions) else {
                throw .unsupportedAccount
            }
            let response = try await dialog.send([FinTSSegments.balance(version: version, account: fints)])
            try Self.checkSegmentErrors(response)
            guard let hisal = response.segment("HISAL") else { throw .formatChanged(detail: "DKB: keine HISAL-Antwort") }
            return try DKBBalanceParser.parse(hisal, asOf: asOf)
        }
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        try check(account)
        guard account.type != .depot else { return [] }
        let sinceDay = since.map(BankDay.init)
        let today = BankDay(now())
        let transactions = try await withDialog { dialog throws(ConnectorError) in
            let fints = try self.fintsAccount(for: account)
            let bpd = await dialog.bpd
            if fints.allows("HKCAZ"), let version = bpd.bestVersion(of: "HKCAZ", supported: Self.camtVersions) {
                let from = sinceDay ?? Self.storagePeriod(bpd).map { today.adding(days: -$0) }
                return try await self.fetchCAMT(dialog: dialog, version: version, format: Self.camtFormat(bpd), fints: fints, account: account, from: from)
            }
            if let mt940 = self.parsers.mt940, fints.allows("HKKAZ"), let version = bpd.bestVersion(of: "HKKAZ", supported: Self.statementVersions) {
                return try await self.fetchMT940(dialog: dialog, version: version, parser: mt940, fints: fints, account: account, from: sinceDay)
            }
            throw .unsupportedAccount
        }
        let filtered = transactions.filter { transaction in
            guard let sinceDay, transaction.status != .pending else { return true }
            return transaction.effectiveDate >= sinceDay
        }
        Self.log.info("DKB: \(filtered.count, privacy: .public) Umsätze (\(filtered.filter { $0.status == .pending }.count, privacy: .public) vorgemerkt)")
        return Transaction.uniquingIDs(filtered)
    }

    /// FinTS has no card statements; the DKB offers them only as PDF in the web banking.
    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        try check(account)
        return []
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        try check(account)
        guard account.type == .depot else { return [] }
        let asOf = now()
        return try await withDialog { dialog throws(ConnectorError) in
            let fints = try self.fintsAccount(for: account)
            return try await self.fetchSecurities(dialog: dialog, fints: fints, account: account, asOf: asOf)
        }
    }

    // MARK: - Business transactions

    private func fetchCAMT(dialog: FinTSDialog, version: Int, format: String, fints: FinTSAccount, account: Account, from: BankDay?) async throws(ConnectorError) -> [Transaction] {
        let responses = try await dialog.sendAllPages { touchdown in
            FinTSSegments.statementCAMT(version: version, account: fints, format: format, from: from, to: nil, touchdown: touchdown)
        }
        var result: [Transaction] = []
        for response in responses {
            try Self.checkSegmentErrors(response)
            for hicaz in response.segments("HICAZ") {
                // 3: booked (one or more camt documents), 4: not yet booked.
                for (index, element) in hicaz.elements.enumerated() where index >= 2 {
                    for document in element.components.compactMap({ $0?.binary }) {
                        result += try CAMTParser.parse(document, accountID: account.id, defaultStatus: index == 2 ? .booked : .pending)
                    }
                }
            }
        }
        return result
    }

    private func fetchMT940(dialog: FinTSDialog, version: Int, parser: DKBStatementParsers.MT940, fints: FinTSAccount, account: Account, from: BankDay?) async throws(ConnectorError) -> [Transaction] {
        let responses = try await dialog.sendAllPages { touchdown in
            FinTSSegments.statementMT940(version: version, account: fints, from: from, to: nil, touchdown: touchdown)
        }
        var result: [Transaction] = []
        for response in responses {
            try Self.checkSegmentErrors(response)
            for hikaz in response.segments("HIKAZ") {
                guard let booked = hikaz[0].components.first??.binary else { continue }
                result += try parser(booked, hikaz[1].components.first??.binary, account.id)
            }
        }
        return result
    }

    private func fetchSecurities(dialog: FinTSDialog, fints: FinTSAccount, account: Account, asOf: Date) async throws(ConnectorError) -> [SecurityPosition] {
        guard let parser = parsers.mt535,
              fints.allows("HKWPD"),
              let version = await dialog.bpd.bestVersion(of: "HKWPD", supported: Self.depotVersions)
        else { throw .unsupportedAccount }
        let responses = try await dialog.sendAllPages { touchdown in
            FinTSSegments.depot(version: version, account: fints, touchdown: touchdown)
        }
        var result: [SecurityPosition] = []
        for response in responses {
            try Self.checkSegmentErrors(response)
            for hiwpd in response.segments("HIWPD") {
                guard let holdings = hiwpd[0].components.first??.binary else { continue }
                result += try parser(holdings, account.id, asOf)
            }
        }
        return result
    }

    // MARK: - Dialog

    /// Opens a dialog with the persisted system ID (or synchronises once), runs `body`, and
    /// always ends the dialog. Updates the cached BPD/UPD.
    private func withDialog<T: Sendable>(_ body: (FinTSDialog) async throws(ConnectorError) -> T) async throws(ConnectorError) -> T {
        await acquire()
        defer { release() }

        let bpd = try await currentBPD()
        let method: DecoupledTANParameters
        if let offered = DecoupledTANParameters.method(Self.securityFunction, in: bpd) {
            method = offered
        } else if bpd.parameters("HITANS").isEmpty {
            method = .fallback(securityFunction: Self.securityFunction)
        } else {
            throw .formatChanged(detail: "DKB: TAN-Verfahren 942 (DKB-App) nicht in HITANS")
        }

        if systemID == nil { systemID = await stateStore.loadSystemID() }
        let knownSystemID = systemID.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }

        let dialog = FinTSDialog(
            bank: Self.bank,
            credentials: credentials,
            product: product,
            mechanism: .twoStep(securityFunction: Self.securityFunction, hktanVersion: method.hktanVersion, tanMedium: tanMedium),
            transport: transport,
            systemID: knownSystemID ?? "0",
            bpd: bpd,
            upd: upd,
            tanHandler: DecoupledTANHandler(parameters: method, presenter: presenter, clock: clock),
            now: now
        )
        do {
            let initResponse = try await dialog.open(synchronize: knownSystemID == nil)
            try await adopt(dialog: dialog, initResponse: initResponse, synchronized: knownSystemID == nil)
            let result = try await body(dialog)
            await dialog.close()
            return result
        } catch {
            await dialog.close()
            throw error
        }
    }

    private func adopt(dialog: FinTSDialog, initResponse: FinTSResponse, synchronized: Bool) async throws(ConnectorError) {
        bpd = await dialog.bpd
        upd = await dialog.upd
        for hiupd in initResponse.segments("HIUPD") {
            let account = FinTSUPD.account(hiupd)
            if let limit = DKBMapping.creditLimit(hiupd) { creditLimits[DKBMapping.accountID(account)] = limit }
        }
        if synchronized {
            let newID = await dialog.systemID
            guard newID != "0", !newID.isEmpty else { throw .formatChanged(detail: "DKB: keine System-ID (HISYN)") }
            systemID = newID
            await stateStore.saveSystemID(newID)
            Self.log.info("DKB: neue System-ID gespeichert")
        }
    }

    private func currentBPD() async throws(ConnectorError) -> FinTSBPD {
        if let bpd { return bpd }
        let fetched = try await FinTSDialog.fetchBPD(bank: Self.bank, product: product, transport: transport, now: now())
        bpd = fetched
        return fetched
    }

    private func fintsAccount(for account: Account) throws(ConnectorError) -> FinTSAccount {
        guard let fints = upd.accounts.first(where: { DKBMapping.accountID($0) == account.id }) else {
            throw .unsupportedAccount
        }
        return fints
    }

    private func check(_ account: Account) throws(ConnectorError) {
        guard account.connectionID == connectionID, account.id.rawValue.hasPrefix("dkb-") else {
            throw .unsupportedAccount
        }
    }

    // MARK: - Serialisation

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Helpers

    /// Segment-level errors of business answers (`HIRMS 9xxx`). Codes only, never bank texts
    /// (they may contain account numbers).
    static func checkSegmentErrors(_ response: FinTSResponse) throws(ConnectorError) {
        let errors = response.segmentCodes.filter(\.isError)
        guard let first = errors.first else { return }
        if errors.contains(where: { $0.code == FinTSCode.pinWrong || $0.code == FinTSCode.pinBlocked || $0.code.hasPrefix("993") }) {
            throw .authFailed
        }
        throw .formatChanged(detail: "DKB FinTS \(first.code)")
    }

    /// `HICAZS` element 4: `Speicherzeitraum : alle Konten : <camt formats…>`. Newest camt.052 wins.
    static func camtFormat(_ bpd: FinTSBPD) -> String {
        let formats = bpd.parameters("HICAZS")
            .flatMap { $0.elements.flatMap { $0.components.compactMap { $0?.text } } }
            .filter { $0.contains("camt.052") }
        return formats.max() ?? defaultCAMTFormat
    }

    /// Days of history the bank keeps (`HICAZS` element 4, component 1).
    static func storagePeriod(_ bpd: FinTSBPD) -> Int? {
        bpd.parameters("HICAZS").compactMap { $0[3][0].flatMap(Int.init) }.filter { $0 > 0 }.max()
    }
}
