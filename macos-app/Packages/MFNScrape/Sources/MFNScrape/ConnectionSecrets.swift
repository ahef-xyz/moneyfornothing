import Foundation
import MFNCore

/// Everything secret a connection leaves in the keychain: its credentials (`CredentialStore`) and
/// the session of its connector. Used by "Bank entfernen" and by a cancelled setup.
///
/// Session keys follow the connectors' conventions: `WebLoginSession` keys `<connector>.<connection>`
/// in `KeychainSessionCookieStore`'s service (C24, easybank), Trade Republic keeps
/// `tradeRepublic.session.<connection>` in the default service. Both patterns are deleted for every
/// connector, so a new connector following either convention is covered; missing items are fine.
public enum ConnectionSecrets {
    public struct Item: Hashable, Sendable {
        public let service: String
        public let key: String
    }

    public static let sessionService = "xyz.ahef.mfn.sessions"
    public static let defaultService = Keychain().service

    /// Session items of `connection` (not the credentials).
    public static func sessionItems(connection: ConnectionID, connector: ConnectorID) -> [Item] {
        [
            Item(service: sessionService, key: "\(connector.rawValue).\(connection.rawValue)"),
            Item(service: defaultService, key: "\(connector.rawValue).session.\(connection.rawValue)"),
        ]
    }

    /// Deletes the session only (e.g. after changing credentials, so the next sync logs in anew).
    public static func deleteSession(connection: ConnectionID, connector: ConnectorID) throws {
        for item in sessionItems(connection: connection, connector: connector) {
            try Keychain(service: item.service).delete(item.key)
        }
    }

    /// Deletes credentials and session. Tries every item and throws the first failure afterwards.
    public static func deleteAll(connection: ConnectionID, connector: ConnectorID, credentials: CredentialStore = CredentialStore()) throws {
        var firstError: (any Error)?
        do { try credentials.delete(for: connection) } catch { firstError = error }
        for item in sessionItems(connection: connection, connector: connector) {
            do { try Keychain(service: item.service).delete(item.key) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
