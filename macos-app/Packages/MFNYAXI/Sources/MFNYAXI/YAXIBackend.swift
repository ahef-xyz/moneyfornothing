import Foundation
import MFNCore
import RoutexClient
import RoutexModels
import RoutexRefresh

/// One question of the bank during a consent (docs/v0.7.0.md section 5), already free of YAXI types.
struct YAXIDialog: Sendable, Equatable {
    struct Option: Sendable, Equatable {
        var key: String
        var label: String
        var detail: String?
    }

    struct Image: Sendable, Equatable {
        var mimeType: String
        var data: Data
        /// chipTAN optic: an animated GIF for a TAN generator, shown 62.5 mm wide (YAXI's `hhdUcData`).
        var isFlicker = false
    }

    enum Input: Sendable, Equatable {
        /// Decoupled approval (bank app): MFN confirms again after the delay until the bank answers.
        case poll(delay: TimeInterval?)
        /// The user confirms once.
        case confirm
        /// TAN or other text; `secret` = a password or PIN, masked input.
        case field(secret: Bool, minLength: Int?, maxLength: Int?)
        case selection([Option])
        /// PSD2 redirect: the bank's page, done when it navigates to `YAXIBackend.redirectURI`.
        case redirect(URL)
    }

    var message: String?
    var image: Image?
    var input: Input
}

enum YAXIAnswer: Sendable, Equatable {
    case confirmed
    case text(String)
}

/// What a service call leaves behind besides its payload.
struct YAXIOutcome<Payload: Sendable>: Sendable {
    var payload: Payload
    /// Newest consent, if the call returned one (store it, it replaces the old one).
    var consent: Data?
    /// Short-lived session for the next call of the same sync.
    var session: Data?
}

/// A service call with credentials: either done or a bank question with its continuation.
enum YAXIStep<Payload: Sendable>: Sendable {
    case done(YAXIOutcome<Payload>)
    case dialog(YAXIDialog, next: @Sendable (YAXIAnswer) async throws -> YAXIStep<Payload>)
}

/// The calls the connector needs, without YAXI's client types. The live implementation is
/// `RoutexBackend`; tests replace it.
protocol YAXIBackend: Sendable {
    /// With the stored consent, no user interaction (`RoutexRefreshClient`). `userInSession`: the user
    /// started the sync, which lifts the bank's limit on background access.
    func accounts(consent: Data, session: Data?, userInSession: Bool) async throws -> YAXIOutcome<[RXAccount]>
    func balances(consent: Data, accounts: [AccountReference], session: Data?, userInSession: Bool) async throws -> YAXIOutcome<RXBalances>
    func transactions(consent: Data, account: AccountReference, from: BankDay, session: Data?, userInSession: Bool) async throws -> YAXIOutcome<[RXTransaction]>

    /// A new consent: the accounts service with the bank login and `recurringConsents`.
    func consent(bank: String, login: YAXILogin) async throws -> YAXIStep<[RXAccount]>
}

extension YAXIBackend {
    /// Where the bank's redirect page sends the user back to. A scheme only MFN listens to: the app
    /// opens the bank's page in the system's login window (`ASWebAuthenticationSession`), which ends
    /// when the page navigates there. YAXI's own example uses such a URI (`myapp://callback`).
    static var redirectScheme: String { "mfn-yaxi" }
    static var redirectURI: String { "\(redirectScheme)://done" }
}

/// `YAXIBackend` over `routex-client-swift`: attested, sealed, tickets issued locally.
struct RoutexBackend: YAXIBackend {
    private let key: YAXIAPIKey
    private let tickets: YAXITickets
    private let client: RoutexClient
    private let usage: YAXIUsage

    init(key: YAXIAPIKey, usage: YAXIUsage = .shared) throws {
        self.key = key
        self.usage = usage
        tickets = try YAXITickets(key: key)
        client = RoutexClient(baseURL: key.environment.baseURL)
    }

    private func refresh(_ userInSession: Bool) -> RoutexRefreshClient {
        RoutexRefreshClient(baseURL: key.environment.baseURL, userInSession: userInSession ? .onThisConnection : nil)
    }

    static let accountFields: [AccountField] = [.iban, .number, .maskedPan, .currency, .name, .displayName, .productName, .status, .type]

    func accounts(consent: Data, session: Data?, userInSession: Bool) async throws -> YAXIOutcome<[RXAccount]> {
        usage.record()
        let response = try await refresh(userInSession).accounts(
            ticket: try tickets.accounts(), connectionData: ConnectionData(consent), fields: Self.accountFields,
            session: session.map(Session.init))
        return YAXIOutcome(payload: response.result, consent: response.connectionData?.bytes, session: response.session?.bytes)
    }

    func balances(consent: Data, accounts: [AccountReference], session: Data?, userInSession: Bool) async throws -> YAXIOutcome<RXBalances> {
        usage.record()
        let response = try await refresh(userInSession).balances(
            ticket: try tickets.balances(), connectionData: ConnectionData(consent), accounts: accounts,
            session: session.map(Session.init))
        return YAXIOutcome(payload: response.result, consent: response.connectionData?.bytes, session: response.session?.bytes)
    }

    func transactions(consent: Data, account: AccountReference, from: BankDay, session: Data?, userInSession: Bool) async throws -> YAXIOutcome<[RXTransaction]> {
        let ticket = try tickets.transactions(account: account, from: try ISODate(from.iso))
        usage.record()
        let response = try await refresh(userInSession).transactions(
            ticket: ticket, connectionData: ConnectionData(consent), session: session.map(Session.init))
        return YAXIOutcome(payload: response.result ?? [], consent: response.connectionData?.bytes, session: response.session?.bytes)
    }

    func consent(bank: String, login: YAXILogin) async throws -> YAXIStep<[RXAccount]> {
        let ticket = try tickets.accounts()
        let credentials = Credentials(connectionID: try RoutexModels.ConnectionID(bank), userID: login.userID, password: login.password)
        usage.record()
        let first = try await client.accounts(ticket: ticket, credentials: credentials, fields: Self.accountFields, recurringConsents: true)
        return try await step(first, ticket: ticket)
    }

    private func step(_ response: Response<AccountsResult>, ticket: AccountsTicket) async throws -> YAXIStep<[RXAccount]> {
        let client = self.client
        let secret = key.secret
        let usage = self.usage
        switch response {
        case let .result(result):
            let payload = try YAXIResultVerifier.verifiedPayload(result.authenticated.jwt, secret: secret, ticketID: ticket.id)
            let accounts = try JSONDecoder().decode(AccountsResult.self, from: payload)
            return .done(YAXIOutcome(payload: accounts.data, consent: result.connectionData?.bytes, session: result.session?.bytes))
        case let .dialog(dialog):
            let mapped = Self.dialog(dialog)
            return .dialog(mapped) { answer in
                switch dialog.input {
                case let .confirmation(context, _):
                    // Each answer is a call to the service; whether YAXI bills it is open (O1).
                    usage.record()
                    return try await step(try await client.confirmAccounts(ticket: ticket, context: context), ticket: ticket)
                case let .field(_, _, _, _, context), let .selection(_, context):
                    guard case let .text(text) = answer else { throw ConnectorError.cancelled }
                    usage.record()
                    return try await step(try await client.respondAccounts(ticket: ticket, context: context, response: text), ticket: ticket)
                }
            }
        case let .redirect(redirect):
            return .dialog(YAXIDialog(message: nil, image: nil, input: .redirect(redirect.url))) { _ in
                usage.record()
                return try await step(try await client.confirmAccounts(ticket: ticket, context: redirect.context), ticket: ticket)
            }
        case let .redirectHandle(handle):
            // No default redirect URI is set: register MFN's own for this redirect (one call).
            usage.record()
            let url = try await client.registerRedirectURI(ticket: ticket, handle: handle.handle, redirectURI: Self.redirectURI)
            return .dialog(YAXIDialog(message: nil, image: nil, input: .redirect(url))) { _ in
                usage.record()
                return try await step(try await client.confirmAccounts(ticket: ticket, context: handle.context), ticket: ticket)
            }
        }
    }

    static func dialog(_ dialog: Dialog) -> YAXIDialog {
        let image = dialog.image.map { YAXIDialog.Image(mimeType: $0.mimeType, data: $0.data, isFlicker: $0.hhdUCData != nil) }
        let input: YAXIDialog.Input = switch dialog.input {
        case let .confirmation(_, delay): delay == nil ? .confirm : .poll(delay: delay)
        // Only a password or PIN is masked; a one-time TAN (`otp`) stays readable while typing it.
        case let .field(_, secrecy, minLength, maxLength, _): .field(secret: secrecy == .password, minLength: minLength, maxLength: maxLength)
        case let .selection(options, _): .selection(options.map { .init(key: $0.key, label: $0.label, detail: $0.explanation) })
        }
        return YAXIDialog(message: dialog.message, image: image, input: input)
    }
}
