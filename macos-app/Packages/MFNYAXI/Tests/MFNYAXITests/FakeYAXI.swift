import Foundation
import MFNCore
import RoutexModels
@testable import MFNYAXI

/// Synthetic values only (DE00… IBANs never validate). Nothing from a real account.
enum TestValues {
    static let connection: MFNCore.ConnectionID = "yaxi-test1234"
    static let bank = "connection-00000000-0000-4000-8000-000000000001"
    static let giroIBAN = "DE00123456780000000001"
    static let savingsIBAN = "DE00123456780000000002"
    static let counterpartIBAN = "DE00987654320000000003"
    static let password = "Geheim-Passwort-7"
    static let userID = "anmeldename-test"
    static let consentA = Data("consent-a-0123456789".utf8)
    static let consentB = Data("consent-b-9876543210".utf8)
    static let tan = "482913"
    /// Must never reach a log line.
    static var secrets: [String] {
        [password, userID, giroIBAN, savingsIBAN, counterpartIBAN, tan,
         String(decoding: consentA, as: UTF8.self), String(decoding: consentB, as: UTF8.self)]
    }

    static func day(_ daysAgo: Int, from now: Date = Date()) -> String {
        BankDay(now).adding(days: -daysAgo).iso
    }
}

/// In-memory stand-in for the Keychain.
final class MemoryStateStore: YAXIStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [MFNCore.ConnectionID: YAXIConnectionState] = [:]

    init(_ initial: YAXIConnectionState? = nil) {
        if let initial { states[TestValues.connection] = initial }
    }

    func state(for connection: MFNCore.ConnectionID) throws -> YAXIConnectionState? { lock.withLock { states[connection] } }
    func set(_ state: YAXIConnectionState, for connection: MFNCore.ConnectionID) throws { lock.withLock { states[connection] = state } }
    func delete(for connection: MFNCore.ConnectionID) throws { _ = lock.withLock { states.removeValue(forKey: connection) } }

    var current: YAXIConnectionState? { lock.withLock { states[TestValues.connection] } }
}

/// A scripted YAXI: accounts, balances and transactions of a pretend bank, plus faults.
final class FakeBackend: YAXIBackend, @unchecked Sendable {
    enum Fault: Sendable {
        case none
        case consentExpiredOnAccounts
        case consentExpiredOnTransactions
        case invalidCredentials
        case accessExceeded
        case periodOutOfBoundsBeyond(days: Int)
        case providerDown
        case attestation
    }

    enum ConsentScript: Sendable {
        /// Decoupled approval: `pending` polls, then done.
        case decoupled(pending: Int)
        /// TAN entry of 6 digits.
        case tan
        /// A choice between two TAN methods (v12).
        case choice
        /// photoTAN image + code of any length (v12).
        case photoTAN
        /// chipTAN optic GIF (v12).
        case flicker
        /// The bank asks for its PIN in a dialog (secret field).
        case pin
        /// Decoupled approval where the user taps "bestätigt" before the bank has seen it.
        case earlyConfirm
        /// PSD2 redirect.
        case redirect
    }

    private let lock = NSLock()
    var fault: Fault
    var consentScript: ConsentScript
    var transactionsByIBAN: [String: [RXTransaction]]
    private(set) var calls: [String] = []
    private(set) var userInSession: [Bool] = []
    private(set) var receivedLogin: YAXILogin?
    private(set) var receivedAnswers: [YAXIAnswer] = []
    /// Consent handed out by the next call (rotation).
    var nextConsent: Data? = TestValues.consentB

    init(fault: Fault = .none, consentScript: ConsentScript = .decoupled(pending: 2), transactions: [String: [RXTransaction]] = FakeBackend.standardTransactions()) {
        self.fault = fault
        self.consentScript = consentScript
        transactionsByIBAN = transactions
    }

    private func record(_ call: String, _ inSession: Bool) {
        lock.withLock {
            calls.append(call)
            userInSession.append(inSession)
        }
    }

    static let accounts: [RXAccount] = [
        RXAccount(iban: TestValues.giroIBAN, currency: "EUR", productName: "Girokonto", type: .current),
        RXAccount(iban: TestValues.savingsIBAN, currency: "EUR", productName: "Tagesgeld", type: .callMoney),
        RXAccount(iban: nil, number: "123456", currency: "EUR", productName: "Depot", type: .securities),
    ]

    static func transaction(_ amount: String, daysAgo: Int, status: RoutexModels.TransactionStatus = .booked, name: String = "Supermarkt", purpose: String = "Einkauf", now: Date = Date()) -> RXTransaction {
        let date = try? ISODate(TestValues.day(daysAgo, from: now))
        let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        let party = RoutexModels.Party(name: name, iban: TestValues.counterpartIBAN)
        return RXTransaction(
            bookingDate: status == .pending ? nil : date, valueDate: date, status: status,
            amount: Amount(amount: value, currency: "EUR"),
            creditor: value < 0 ? party : RoutexModels.Party(name: "Ich"), debtor: value < 0 ? RoutexModels.Party(name: "Ich") : party,
            remittanceInformation: [purpose]
        )
    }

    static func standardTransactions() -> [String: [RXTransaction]] {
        [
            TestValues.giroIBAN: [
                transaction("-12.34", daysAgo: 2),
                transaction("-45.00", daysAgo: 10, name: "Stromanbieter", purpose: "Abschlag"),
                transaction("2500.00", daysAgo: 20, name: "Arbeitgeber", purpose: "Gehalt"),
                transaction("-9.99", daysAgo: 40, name: "Streaming", purpose: "Abo"),
            ],
            TestValues.savingsIBAN: [
                transaction("100.00", daysAgo: 5, name: "Ich", purpose: "Sparen"),
                transaction("0.42", daysAgo: 35, name: "Bank", purpose: "Zinsen"),
            ],
        ]
    }

    // MARK: YAXIBackend

    func accounts(consent: Data, session: Data?, userInSession: Bool) async throws -> YAXIOutcome<[RXAccount]> {
        record("accounts", userInSession)
        if case .consentExpiredOnAccounts = fault { throw RoutexError.interruptError }
        try commonFaults()
        return YAXIOutcome(payload: Self.accounts, consent: nextConsent, session: Data("s1".utf8))
    }

    func balances(consent: Data, accounts: [AccountReference], session: Data?, userInSession: Bool) async throws -> YAXIOutcome<RXBalances> {
        record("balances", userInSession)
        try commonFaults()
        let entries = accounts.map { reference in
            AccountBalances(account: reference, balances: [
                RoutexModels.Balance(amount: Decimal(string: "1234.56") ?? 0, currency: "EUR", balanceType: .booked),
                RoutexModels.Balance(amount: Decimal(string: "1200.00") ?? 0, currency: "EUR", balanceType: .available),
            ])
        }
        return YAXIOutcome(payload: RXBalances(balances: entries), consent: nil, session: Data("s2".utf8))
    }

    func transactions(consent: Data, account: AccountReference, from: BankDay, session: Data?, userInSession: Bool) async throws -> YAXIOutcome<[RXTransaction]> {
        record("transactions", userInSession)
        if case .consentExpiredOnTransactions = fault { throw RoutexError.interruptError }
        if case let .periodOutOfBoundsBeyond(days) = fault, from < BankDay(Date()).adding(days: -days) {
            throw RoutexError.periodOutOfBounds(userMessage: nil)
        }
        try commonFaults()
        guard case let .iban(iban) = account.id else { return YAXIOutcome(payload: [], consent: nil, session: nil) }
        let all = transactionsByIBAN[iban] ?? []
        let inRange = all.filter { item in
            guard let raw = (item.bookingDate ?? item.valueDate)?.rawValue, let day = BankDay(iso: raw) else { return true }
            return day >= from
        }
        return YAXIOutcome(payload: inRange, consent: nil, session: nil)
    }

    func consent(bank: String, login: YAXILogin) async throws -> YAXIStep<[RXAccount]> {
        record("consent", true)
        lock.withLock { receivedLogin = login }
        if case .invalidCredentials = fault { throw RoutexError.invalidCredentials(userMessage: nil) }
        try commonFaults()
        let done = YAXIStep<[RXAccount]>.done(YAXIOutcome(payload: Self.accounts, consent: TestValues.consentA, session: nil))
        switch consentScript {
        case let .decoupled(pending):
            return pollStep(remaining: pending, done: done)
        case .tan:
            return .dialog(YAXIDialog(message: "Bitte TAN eingeben", image: nil, input: .field(secret: false, minLength: 6, maxLength: 6))) { [self] answer in
                lock.withLock { receivedAnswers.append(answer) }
                return done
            }
        case .choice:
            return .dialog(YAXIDialog(message: "Verfahren wählen", image: nil, input: .selection([.init(key: "a", label: "App"), .init(key: "b", label: "SMS")]))) { [self] answer in
                lock.withLock { receivedAnswers.append(answer) }
                return done
            }
        case .pin:
            return .dialog(YAXIDialog(message: "PIN eingeben", image: nil, input: .field(secret: true, minLength: nil, maxLength: nil))) { [self] answer in
                lock.withLock { receivedAnswers.append(answer) }
                return done
            }
        case .earlyConfirm:
            return pollStep(remaining: 2, done: done)
        case .photoTAN, .flicker:
            let image = YAXIDialog.Image(mimeType: consentScript.isFlicker ? "image/gif" : "image/png", data: Data([1, 2, 3]), isFlicker: consentScript.isFlicker)
            return .dialog(YAXIDialog(message: nil, image: image, input: .field(secret: false, minLength: nil, maxLength: nil))) { [self] answer in
                lock.withLock { receivedAnswers.append(answer) }
                return done
            }
        case .redirect:
            return .dialog(YAXIDialog(message: nil, image: nil, input: .redirect(URL(string: "https://bank.example/consent")!))) { _ in done }
        }
    }

    private func pollStep(remaining: Int, done: YAXIStep<[RXAccount]>) -> YAXIStep<[RXAccount]> {
        .dialog(YAXIDialog(message: nil, image: nil, input: .poll(delay: 1))) { [self] answer in
            lock.withLock {
                calls.append("confirm")
                receivedAnswers.append(answer)
            }
            return remaining > 0 ? pollStep(remaining: remaining - 1, done: done) : done
        }
    }

    private func commonFaults() throws {
        switch fault {
        case .accessExceeded: throw RoutexError.accessExceeded(userMessage: "Zu viele Abrufe")
        case .providerDown: throw RoutexError.providerError(code: nil, userMessage: nil)
        case .attestation: throw ConnectorError.formatChanged(detail: "yaxi attestation")
        default: break
        }
    }
}

/// Presenter that answers like a user would, and records what it was asked.
final class ScriptedPresenter: AuthChallengePresenter, @unchecked Sendable {
    enum Behaviour { case approve, cancel, confirmAtOnce }

    private let lock = NSLock()
    private let behaviour: Behaviour
    private(set) var challenges: [AuthChallenge] = []

    init(_ behaviour: Behaviour = .approve) {
        self.behaviour = behaviour
    }

    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        lock.withLock { challenges.append(challenge) }
        guard behaviour != .cancel else { throw ConnectorError.cancelled }
        switch challenge {
        case .decoupled:
            if behaviour == .confirmAtOnce { return .confirmed }
            // Stays open until MFN closes it (the bank answered); never confirms by itself.
            try await Task.sleep(for: .seconds(60))
            return .confirmed
        case .code, .imageCode, .secret: return .code(TestValues.tan)
        case let .choice(_, options): return .code(options.last?.key ?? "")
        case .pushConfirm: return .confirmed
        case .webLogin: return .webSession([])
        }
    }
}

struct Harness {
    let backend: FakeBackend
    let states: MemoryStateStore
    let presenter: ScriptedPresenter?
    let connector: YAXIConnector
    let usage: YAXIUsage

    init(backend: FakeBackend = FakeBackend(), consent: Data? = TestValues.consentA, accounts: [YAXIConnectionState.KnownAccount] = [],
         fetchedAt: Date? = nil, presenter: ScriptedPresenter? = ScriptedPresenter(), login: YAXILogin? = YAXILogin(userID: TestValues.userID, password: TestValues.password),
         usedCalls: Int = 0) {
        self.backend = backend
        let usage = YAXIUsage(defaults: UserDefaults(suiteName: "yaxi-tests-\(UUID().uuidString)") ?? .standard)
        usage.record(usedCalls)
        self.usage = usage
        states = MemoryStateStore(YAXIConnectionState(bank: TestValues.bank, bankName: "Testbank", consent: consent, accounts: accounts, accountsFetchedAt: fetchedAt))
        self.presenter = presenter
        connector = YAXIConnector(
            connectionID: TestValues.connection,
            presenter: presenter,
            states: states,
            login: { login },
            backend: { backend },
            sleep: { _ in await Task.yield() },
            usage: usage
        )
    }
}

extension FakeBackend.ConsentScript {
    var isFlicker: Bool { if case .flicker = self { true } else { false } }
}
