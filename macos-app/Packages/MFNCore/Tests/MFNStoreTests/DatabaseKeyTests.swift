import Foundation
import Security
import Testing
@testable import MFNStore

/// The keychain itself needs a signed app; these cover which attempts `save` makes and how
/// keychain statuses are reported.
@Suite struct DatabaseKeySaveTests {
    private typealias Attempt = KeychainDatabaseKey.Attempt

    /// Runs `add` with a fake keychain; returns the result and what was tried.
    private func run(_ status: (Attempt) -> OSStatus) -> (status: OSStatus, used: Attempt?, tried: [Attempt]) {
        var tried: [Attempt] = []
        let result = KeychainDatabaseKey.add(trying: Attempt.all) { attempt in
            tried.append(attempt)
            return status(attempt)
        }
        return (result.status, result.used, tried)
    }

    @Test func preferredAttemptIsUsedWhenTheKeychainAcceptsIt() {
        let result = run { _ in errSecSuccess }
        #expect(result.used == Attempt(protection: .biometryOrPasscode, usesContext: true))
        #expect(result.tried.count == 1)
    }

    @Test func refusedContextIsRetriedWithoutItBeforeWeakeningTheProtection() {
        let result = run { $0.usesContext ? errSecAuthFailed : errSecSuccess }
        #expect(result.used == Attempt(protection: .biometryOrPasscode, usesContext: false))
        #expect(result.status == errSecSuccess)
        #expect(result.tried.count == 2)
    }

    @Test func refusedProtectionFallsBackToPasscodeBeforeUserPresence() {
        let result = run { $0.protection == .biometryOrPasscode ? errSecAuthFailed : errSecSuccess }
        #expect(result.used == Attempt(protection: .passcode, usesContext: false))
        #expect(result.tried.map(\.protection) == [.biometryOrPasscode, .biometryOrPasscode, .passcode])
    }

    @Test func allRefusedReportsTheFirstStatus() {
        let result = run { $0.usesContext ? errSecAuthFailed : errSecParam }
        #expect(result.used == nil)
        #expect(result.status == errSecAuthFailed)
        #expect(result.tried == Attempt.all)
    }

    @Test(arguments: [errSecUserCanceled, errSecMissingEntitlement, errSecDuplicateItem, errSecInteractionNotAllowed, errSecNotAvailable])
    func otherStatusesEndTheAttempts(status: OSStatus) {
        let result = run { _ in status }
        #expect(result.used == nil)
        #expect(result.status == status)
        #expect(result.tried.count == 1)
    }

    @Test func userPresenceIsTheLastResort() {
        #expect(Attempt.all.first == Attempt(protection: .biometryOrPasscode, usesContext: true))
        #expect(Attempt.all.last?.protection == .userPresence)
    }

    @Test func refusalIsNotACancel() {
        #expect(KeychainDatabaseKey.map(errSecAuthFailed) == .keychain(errSecAuthFailed))
        #expect(KeychainDatabaseKey.map(errSecUserCanceled) == .authenticationCancelled)
        #expect(KeychainDatabaseKey.map(errSecMissingEntitlement) == .missingEntitlement)
    }
}
