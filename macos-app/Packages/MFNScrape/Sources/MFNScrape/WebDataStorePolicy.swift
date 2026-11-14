import CryptoKit
import Foundation
import MFNCore

/// Rules for the persistent web data store of a connection (WebKit-free, tested).
///
/// Each connection gets its own `WKWebsiteDataStore(forIdentifier:)`, so the bank recognises the
/// device (no device approval on every login). The session itself lives only in the keychain:
/// after a successful login every session-like cookie is deleted from the web store; device and
/// fingerprint cookies and `localStorage` stay.
public enum WebDataStorePolicy {
    /// Name fragments (case-insensitive) that mark a cookie as part of the session.
    public static let sessionFragments = ["session", "token", "refresh", "auth"]

    /// Stable data store identifier of a connection: name-based UUID (version 5 layout) from
    /// SHA-256 of the connection ID, so it needs no bookkeeping and survives reinstalls.
    public static func identifier(for connection: ConnectionID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("xyz.ahef.mfn.webdata.\(connection.rawValue)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether a cookie named `name` must leave the web store after a successful login: its name is
    /// required by `completion` (`.cookiesPresent`) or contains one of `sessionFragments`.
    public static func isSessionCookie(named name: String, completion: WebLoginRequest.Completion) -> Bool {
        if case let .cookiesPresent(required) = completion, required.contains(name) { return true }
        let lowered = name.lowercased()
        return sessionFragments.contains { lowered.contains($0) }
    }

    /// The cookies of `cookies` to delete after a successful login.
    public static func cookiesToDelete(_ cookies: [SessionCookie], after request: WebLoginRequest) -> [SessionCookie] {
        cookies.filter { isSessionCookie(named: $0.name, completion: request.completion) }
    }
}
