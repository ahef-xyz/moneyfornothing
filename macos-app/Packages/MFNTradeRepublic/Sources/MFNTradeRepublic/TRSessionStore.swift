import Foundation
import MFNCore
import Synchronization

/// Persists the cookies of the Trade Republic web session (`tr_session`, `tr_refresh`, `tr_claims`,
/// `aws-waf-token`, …) between syncs. Values are secrets: Keychain only, never logged.
public protocol TRSessionStore: Sendable {
    func load() throws -> [SessionCookie]
    func save(_ cookies: [SessionCookie]) throws
    func delete() throws
}

/// Production store: `MFNCore.Keychain` (`WhenUnlockedThisDeviceOnly`).
public struct KeychainTRSessionStore: TRSessionStore {
    public let keychain: Keychain
    public let key: String

    public init(connection: ConnectionID, keychain: Keychain = Keychain()) {
        self.keychain = keychain
        self.key = "tradeRepublic.session.\(connection.rawValue)"
    }

    public func load() throws -> [SessionCookie] {
        try keychain.value([SessionCookie].self, for: key) ?? []
    }

    public func save(_ cookies: [SessionCookie]) throws {
        try keychain.set(cookies, for: key)
    }

    public func delete() throws {
        try keychain.delete(key)
    }
}

/// Volatile store for tests and for `swift test`, where the keychain has no entitlement.
public final class InMemoryTRSessionStore: TRSessionStore {
    private let state: Mutex<[SessionCookie]>

    public init(_ cookies: [SessionCookie] = []) {
        state = Mutex(cookies)
    }

    public func load() throws -> [SessionCookie] { state.withLock { $0 } }
    public func save(_ cookies: [SessionCookie]) throws { state.withLock { $0 = cookies } }
    public func delete() throws { state.withLock { $0 = [] } }
}
