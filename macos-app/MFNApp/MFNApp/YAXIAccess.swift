import Foundation
import MFNCore
import MFNYAXI
import Observation

/// The user's own YAXI key (Settings → Banken → YAXI) and the bank search of the assistant.
/// The key lives only in the Keychain; this type keeps no copy of the secret beyond a call.
@MainActor
@Observable
final class YAXIAccess {
    enum KeyState: Equatable {
        case none
        case stored(YAXIEnvironment)
        /// The Keychain could not be read.
        case unreadable
    }

    private(set) var keyState: KeyState = .none
    private(set) var isChecking = false
    /// Result of the last "Prüfen und sichern", plain text for the form.
    private(set) var checkMessage: String?
    private(set) var checkFailed = false
    /// Calls at YAXI this month (`YAXIUsage`), refreshed when the settings appear.
    private(set) var callsThisMonth = 0

    @ObservationIgnored private let store: any YAXIKeyStore

    init(store: any YAXIKeyStore = KeychainYAXIKeyStore()) {
        self.store = store
        reload()
    }

    var hasKey: Bool { if case .stored = keyState { true } else { false } }

    func refreshUsage() {
        callsThisMonth = YAXIUsage.shared.thisMonth
    }

    func reload() {
        refreshUsage()
        do {
            keyState = try store.key().map { .stored($0.environment) } ?? .none
        } catch {
            keyState = .unreadable
        }
    }

    /// Checks the key with one search call at YAXI, stores it only if YAXI accepts it.
    func checkAndSave(keyID: String, secret: String, environment: YAXIEnvironment) async {
        guard !isChecking else { return }
        checkMessage = nil
        checkFailed = false
        let key: YAXIAPIKey
        do {
            key = try YAXIAPIKey(keyID: keyID, base64Secret: secret, environment: environment)
        } catch .keyIDFormat {
            fail(String(localized: "Die Schlüssel-ID beginnt mit „api-key-“. Kopiere sie aus dem YAXI Hub."))
            return
        } catch {
            fail(String(localized: "Der geheime Schlüssel sieht nicht wie der aus dem YAXI Hub aus (Base64)."))
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            try await YAXIDirectory(key: key).check()
            try store.set(key)
            reload()
            refreshUsage()
            checkMessage = String(localized: "Gesichert. YAXI hat den Schlüssel angenommen.")
        } catch let error as ConnectorError {
            switch error {
            case .authFailed:
                fail(environment == .production
                     ? String(localized: "YAXI kennt diesen Schlüssel im Live-Betrieb nicht. Ist es ein Schlüssel für die Testumgebung?")
                     : String(localized: "YAXI kennt diesen Schlüssel in der Testumgebung nicht. Ist es ein Schlüssel für den Live-Betrieb?"))
            case .bankUnavailable:
                fail(String(localized: "YAXI ist gerade nicht erreichbar. Der Schlüssel wurde nicht gesichert."))
            default:
                fail(String(localized: "YAXI hat den Schlüssel nicht angenommen (\(error.description))."))
            }
        } catch {
            fail(String(localized: "Der Schlüssel konnte nicht im Schlüsselbund gesichert werden."))
        }
    }

    func remove() {
        do {
            try store.delete()
            checkMessage = nil
            checkFailed = false
        } catch {
            fail(String(localized: "Der Schlüssel konnte nicht aus dem Schlüsselbund entfernt werden."))
        }
        reload()
    }

    /// Bank search for the assistant (one call per search).
    func search(_ term: String) async throws(ConnectorError) -> [YAXIBank] {
        let key: YAXIAPIKey?
        do { key = try store.key() } catch { throw .formatChanged(detail: "yaxi key") }
        guard let key else { throw .formatChanged(detail: String(localized: "YAXI-Schlüssel fehlt (Einstellungen → Banken)")) }
        return try await YAXIDirectory(key: key).search(term)
    }

    private func fail(_ message: String) {
        checkMessage = message
        checkFailed = true
    }
}
