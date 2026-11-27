import Foundation
import MFNCore

/// How a mock bank behaves. Lets UI, previews and tests exercise every path of a real connector.
public enum MockScenario: Sendable, Equatable {
    /// Delivers data without interaction (like ING).
    case ok
    /// Asks the presenter for approval first (decoupled TAN, 2FA code, push). Without a presenter
    /// the connector throws `ConnectorError.authRequired`.
    case requiresApproval(AuthChallenge)
    /// Every call throws this error.
    case failing(ConnectorError)
}

/// Which version of the mock world the connector serves.
public enum MockPhase: Sendable, Equatable {
    case current
    /// A few days later: every pending transaction has been booked.
    case afterBooking
}

/// `BankConnector` over a `MockDataset`. Stays in the project permanently: previews, UI tests,
/// conformance reference and demo mode use it.
public struct MockConnector: BankConnector {
    public let id: ConnectorID
    public let connectionID: ConnectionID
    public let dataset: MockDataset
    public var scenario: MockScenario
    public var phase: MockPhase
    public var presenter: (any AuthChallengePresenter)?
    public var latency: Duration
    /// Demo app only: syncs also deliver one or two bookings per giro/card account that the bank
    /// made today (one set per day, included in the balance), so "Neu seit dem Abgleich" has
    /// something to show.
    public var deliversFreshBookings = false

    private static let log = Log.logger("mock")

    public init(
        connection: ConnectionID,
        dataset: MockDataset,
        scenario: MockScenario = .ok,
        phase: MockPhase = .current,
        presenter: (any AuthChallengePresenter)? = nil,
        latency: Duration = .zero
    ) {
        self.connectionID = connection
        self.id = dataset.connections.first { $0.id == connection }?.connectorID ?? .mock
        self.dataset = dataset
        self.scenario = scenario
        self.phase = phase
        self.presenter = presenter
        self.latency = latency
    }

    public func accounts() async throws -> [Account] {
        try await gate(authenticate: true)
        return dataset.accounts(of: connectionID)
    }

    public func balance(for account: Account) async throws -> Balance {
        try await gate()
        try check(account)
        var balance = dataset.balance(for: account.id, afterBooking: phase == .afterBooking)
        if deliversFreshBookings {
            let fresh = Self.freshBookings(for: account, at: Date()).reduce(0) { $0 + $1.amountCents }
            balance.bookedCents += fresh
            balance.availableCents = balance.availableCents.map { $0 + fresh }
        }
        return balance
    }

    public func transactions(for account: Account, since: Date?) async throws -> [Transaction] {
        try await gate()
        try check(account)
        let source = phase == .afterBooking ? dataset.transactionsAfterBooking : dataset.transactions
        var all = source[account.id] ?? []
        if deliversFreshBookings { all += Self.freshBookings(for: account, at: Date()) }
        guard let since else { return all }
        let from = BankDay(since)
        return all.filter { $0.effectiveDate >= from }
    }

    public func cardStatements(for account: Account) async throws -> [CardStatement] {
        try await gate()
        try check(account)
        guard account.type == .card else { return [] }
        return dataset.cardStatements[account.id] ?? []
    }

    public func securities(for account: Account) async throws -> [SecurityPosition] {
        try await gate()
        try check(account)
        guard account.type == .depot else { return [] }
        return dataset.securities[account.id] ?? []
    }

    private static let freshMerchants: [(name: String, purpose: String, cents: Int)] = [
        ("Bäckerei Kornfeld", "Kartenzahlung", -385),
        ("REWE Markt", "Kartenzahlung Lebensmittel", -2_749),
        ("Aral Tankstelle", "Kartenzahlung", -6_120),
        ("Café Mokka", "Kartenzahlung", -560),
        ("Drogerie Blum", "Kartenzahlung", -1_295),
        ("Kiosk am Markt", "Kartenzahlung", -240),
    ]

    /// One or two bookings dated today for giro and card accounts, the same all day (later syncs
    /// that day bring nothing new), so the demo ledger grows by at most one set per day.
    static func freshBookings(for account: Account, at date: Date) -> [Transaction] {
        guard account.type == .giro || account.type == .card else { return [] }
        let today = BankDay(date)
        let slot = today.year * 10_000 + today.month * 100 + today.day
        var seed = UInt64(truncatingIfNeeded: slot) &* 0x9E37_79B9_7F4A_7C15 ^ account.id.rawValue.unicodeScalars.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1.value) }
        seed ^= seed >> 29
        let count = 1 + Int(seed % 2)
        return (0..<count).map { index in
            let pick = freshMerchants[Int((seed >> (8 * UInt64(index + 1))) % UInt64(freshMerchants.count))]
            return Transaction(
                accountID: account.id, bookingDate: today, valueDate: today, amountCents: pick.cents,
                counterpartName: pick.name, purpose: pick.purpose, status: .booked,
                externalID: "demo-fresh:\(account.id.rawValue):\(slot):\(index)"
            )
        }
    }

    // MARK: -

    private func gate(authenticate: Bool = false) async throws {
        if latency > .zero {
            do { try await Task.sleep(for: latency) } catch { throw ConnectorError.cancelled }
        }
        switch scenario {
        case .ok:
            return
        case let .failing(error):
            Self.log.notice("Mock \(connectionID.rawValue, privacy: .public) fails: \(error.description, privacy: .public)")
            throw error
        case let .requiresApproval(challenge):
            guard authenticate else { return }
            guard let presenter else { throw ConnectorError.authRequired(challenge) }
            let response: AuthResponse
            do {
                response = try await presenter.present(challenge)
            } catch let error as ConnectorError {
                throw error
            } catch {
                throw ConnectorError.cancelled
            }
            try validate(response, for: challenge)
        }
    }

    private func validate(_ response: AuthResponse, for challenge: AuthChallenge) throws {
        switch (challenge, response) {
        case let (.code(_, length), .code(code)), let (.imageCode(_, length, _), .code(code)), let (.secret(_, length), .code(code)):
            // Mock rule: any all-digit code of the right length (0 = any) is accepted, "0000…" is rejected.
            guard !code.isEmpty, length == 0 || code.count == length, code.allSatisfy(\.isNumber), Set(code) != ["0"] else {
                throw ConnectorError.authFailed
            }
        case let (.choice(_, options), .code(key)):
            guard options.contains(where: { $0.key == key }) else { throw ConnectorError.authFailed }
        case (.decoupled, .confirmed), (.pushConfirm, .confirmed), (.webLogin, .webSession):
            return
        default:
            throw ConnectorError.authFailed
        }
    }

    private func check(_ account: Account) throws {
        guard account.connectionID == connectionID,
              dataset.accounts.contains(where: { $0.id == account.id }) else {
            throw ConnectorError.unsupportedAccount
        }
    }
}

extension MockDataset {
    /// The default demo setup: one connector per bank, with approval flows like the real banks.
    public func demoConnectors(presenter: (any AuthChallengePresenter)?, latency: Duration = .milliseconds(400)) -> [(Connection, MockConnector)] {
        let scenarios: [ConnectionID: MockScenario] = [
            MockConnections.ing: .ok,
            MockConnections.dkb: .requiresApproval(.decoupled(message: "Bitte bestätigen Sie den Zugriff in der DKB-App.", pollInterval: 2)),
            MockConnections.tradeRepublic: .requiresApproval(.code(prompt: "Code aus der Trade-Republic-App", length: 4)),
            MockConnections.c24: .requiresApproval(.pushConfirm(message: "Bitte bestätigen Sie die Anmeldung in der C24-App.")),
            MockConnections.easybank: .ok,
        ].merging(Self.v12DialogScenarios) { _, v12 in v12 }
        return connections.map { connection in
            (connection, MockConnector(connection: connection.id, dataset: self, scenario: scenarios[connection.id] ?? .ok, presenter: presenter, latency: latency))
        }
    }

    /// Debug aid for the v12 dialogs: with `MFN_DEMO_V12_DIALOGS=1`, demo ING asks for a photoTAN and
    /// demo easybank for a choice of TAN method. Off by default (real ING and easybank ask neither).
    static var v12DialogScenarios: [ConnectionID: MockScenario] {
        guard ProcessInfo.processInfo.environment["MFN_DEMO_V12_DIALOGS"] == "1" else { return [:] }
        return [
            MockConnections.ing: .requiresApproval(.imageCode(prompt: "Scanne die Grafik mit der photoTAN-App und gib die TAN ein.", length: 6,
                                                              image: AuthImage(mimeType: "image/png", data: MockImages.photoTAN))),
            MockConnections.easybank: .requiresApproval(.choice(prompt: "Wie möchtest du freigeben?", options: [
                AuthOption(key: "app", label: "easybank App", detail: "Freigabe auf dem Smartphone"),
                AuthOption(key: "sms", label: "SMS an +49 ••• 12"),
            ])),
        ]
    }

    /// All data loaded into a snapshot, without running a sync. For previews.
    public func snapshot() -> LedgerSnapshot {
        var snapshot = LedgerSnapshot()
        snapshot.connections = connections
        snapshot.accounts = accounts
        snapshot.transactions = allTransactions.sorted { $0.effectiveDate > $1.effectiveDate }
        snapshot.cardStatements = cardStatements.values.flatMap { $0 }
        snapshot.securities = securities.values.flatMap { $0 }
        for account in accounts {
            snapshot.balances[account.id] = balance(for: account.id)
        }
        for connection in connections {
            snapshot.syncStates[connection.id] = SyncState(lastSuccess: now)
        }
        return snapshot
    }
}

/// Images for demo approvals, drawn in code (no assets, no real bank graphics).
enum MockImages {
    /// A black-and-white checker pattern standing in for a photoTAN mosaic.
    static let photoTAN: Data = {
        let size = 24
        let scale = 6
        let width = size * scale
        var pixels = [UInt8](repeating: 255, count: width * width)
        var seed: UInt32 = 0x9E37_79B9
        for cellY in 0..<size {
            for cellX in 0..<size {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let black = (seed >> 16) & 1 == 1 || cellX < 3 && cellY < 3 || cellX >= size - 3 && cellY < 3 || cellX < 3 && cellY >= size - 3
                guard black else { continue }
                for y in 0..<scale { for x in 0..<scale { pixels[(cellY * scale + y) * width + cellX * scale + x] = 0 } }
            }
        }
        return PNG.grayscale(width: width, height: width, pixels: pixels)
    }()
}

/// Minimal PNG writer (8-bit grayscale, stored deflate blocks): enough for a demo image.
enum PNG {
    static func grayscale(width: Int, height: Int, pixels: [UInt8]) -> Data {
        var raw = Data()
        for row in 0..<height {
            raw.append(0)
            raw.append(contentsOf: pixels[(row * width)..<((row + 1) * width)])
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(be32(UInt32(width)))
        header.append(be32(UInt32(height)))
        header.append(contentsOf: [8, 0, 0, 0, 0])
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let length = min(65_535, bytes.count - offset)
            let last: UInt8 = offset + length >= bytes.count ? 1 : 0
            out.append(last)
            out.append(UInt8(length & 0xFF)); out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF)); out.append(UInt8((~length >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        out.append(be32(b << 16 | a))
        return out
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var typed = Data(type.utf8)
        typed.append(body)
        var out = be32(UInt32(body.count))
        out.append(typed)
        out.append(be32(crc32(typed)))
        return out
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
