import CryptoKit
import Foundation
import RoutexModels
import RoutexTickets

/// Issues tickets with the user's key, locally (docs/v0.7.0.md section 3).
///
/// **Read-only by construction**: only the accounts, balances and transactions services. MFN never
/// moves money, so this type has no way to issue a ticket for any other service, and
/// `ReadOnlyGuardTests` fails if one of those service names shows up anywhere in `Sources/MFNYAXI`.
struct YAXITickets: Sendable {
    private let issuer: RoutexTicketIssuer

    init(key: YAXIAPIKey) throws {
        issuer = try RoutexTicketIssuer(apiKeyID: key.keyID, base64Secret: key.base64Secret)
    }

    func accounts() throws -> AccountsTicket { try issuer.accounts() }
    func balances() throws -> BalancesTicket { try issuer.balances() }
    func transactions(account: AccountReference, from: ISODate) throws -> TransactionsTicket {
        try issuer.transactions(account: account, range: .period(from: from))
    }
}

/// Checks a result JWT of an interactive call: HS256 with the API secret (MFN holds it, so it is the
/// "trusted backend" of YAXI's docs) and the ticket ID of the call. Returns the verified `data` claim.
///
/// Results of the non-interactive client carry no JWT; they are protected by the sealed channel to
/// the attested enclave.
enum YAXIResultVerifier {
    enum Failure: Error, Equatable {
        case malformed
        case algorithm
        case signature
        case ticket
    }

    static func verifiedPayload(_ jwt: String, secret: Data, ticketID: UUID) throws(Failure) -> Data {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = base64URL(parts[0]), let payload = base64URL(parts[1]),
              let signature = base64URL(parts[2]) else { throw .malformed }
        guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "HS256" else { throw .algorithm }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: signed, using: SymmetricKey(data: secret)) else {
            throw .signature
        }
        guard let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let data = claims["data"] as? [String: Any], let ticket = data["ticketId"] as? String,
              UUID(uuidString: ticket) == ticketID,
              let inner = try? JSONSerialization.data(withJSONObject: data) else { throw .ticket }
        return inner
    }

    static func base64URL(_ text: Substring) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
}
