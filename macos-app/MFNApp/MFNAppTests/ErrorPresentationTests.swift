import Foundation
import MFNStore
import Testing
@testable import MFN

@MainActor @Suite struct ErrorPresentationTests {
    @Test func errorKindOfPlainEnumCase() {
        #expect(AppModel.errorKind(StoreError.cannotDecrypt) == "StoreError.cannotDecrypt")
        #expect(AppModel.errorKind(StoreError.closed) == "StoreError.closed")
    }

    @Test func errorKindDropsAssociatedValues() {
        let kind = AppModel.errorKind(StoreError.corruptRow("amount_cents"))
        #expect(kind == "StoreError.corruptRow")
        #expect(!kind.contains("amount_cents"))
        #expect(AppModel.errorKind(VaultError.file("/Volumes/Daten/ledger.db")) == "VaultError.file")
        #expect(AppModel.errorKind(StoreError.database("secret detail")) == "StoreError.database")
    }

    @Test func errorKindUnwrapsVaultStore() {
        #expect(AppModel.errorKind(VaultError.store(.cannotDecrypt)) == "VaultError.store(StoreError.cannotDecrypt)")
        let wrapped = AppModel.errorKind(VaultError.store(.corruptRow("iban")))
        #expect(wrapped == "VaultError.store(StoreError.corruptRow)")
        #expect(!wrapped.contains("iban"))
    }

    @Test func errorKindOfNonEnumIsTypeName() {
        struct Opaque: Error { let secret = "DE00 0000 0000 0000 0000 00" }
        let kind = AppModel.errorKind(Opaque())
        #expect(kind.contains("Opaque"))
        #expect(!kind.contains("DE00"))
    }

    @Test func newerSchemaProblemExplainsAndOffersUpdate() {
        let problem = AppModel.problem(for: StoreError.newerSchema(found: 9, supported: 7))
        #expect(problem.message == "Diese Datenbank stammt aus einer neueren Version von MFN.")
        #expect(problem.hint?.contains("Deine Daten sind unverändert") == true)
        #expect(problem.action == .update)
        let detail = problem.detail ?? ""
        #expect(detail.contains("Schema bis 7"))
        #expect(detail.contains("Schema 9"))
    }

    @Test func newerSchemaWrappedInVaultErrorIsTheSame() {
        let direct = AppModel.problem(for: StoreError.newerSchema(found: 9, supported: 7))
        let wrapped = AppModel.problem(for: VaultError.store(.newerSchema(found: 9, supported: 7)))
        #expect(direct == wrapped)
    }

    @Test func corruptRowShowsOnlyTheKind() {
        let problem = AppModel.problem(for: VaultError.store(.corruptRow("counterpart_name")))
        #expect(problem.message == "Die Datenbank konnte nicht geöffnet werden.")
        #expect(problem.detail == "VaultError.store(StoreError.corruptRow)")
        #expect(problem.action == nil)
        #expect(!(problem.detail ?? "").contains("counterpart_name"))
        #expect(!problem.message.contains("counterpart_name"))
        #expect(!(problem.hint ?? "").contains("counterpart_name"))
    }

    @Test func unknownErrorGivesGenericMessageAndKindOnly() {
        struct Boom: Error { let path = "/Volumes/Daten/Library/ledger.db" }
        let problem = AppModel.problem(for: Boom())
        #expect(problem.message == "Die Datenbank konnte nicht geöffnet werden.")
        #expect(problem.hint?.contains("Versuche es erneut") == true)
        #expect(problem.detail?.contains("Boom") == true)
        #expect(!(problem.detail ?? "").contains("/Volumes"))
        #expect(problem.action == nil)
    }

    @Test(arguments: [
        VaultError.wrongPassword, VaultError.weakPassword(minimumLength: 12), VaultError.keyUnrecoverable,
        VaultError.key(.authenticationCancelled), VaultError.key(.missingEntitlement), VaultError.store(.cannotDecrypt),
    ])
    func knownVaultErrorsGiveMessageWithoutDetail(error: VaultError) {
        let problem = AppModel.problem(for: error)
        #expect(!problem.message.isEmpty)
        #expect(problem.detail == nil)
        #expect(problem.hint == nil)
        #expect(problem.action == nil)
    }

    @Test func problemEquality() {
        let a = AppLock.Problem(message: "m", hint: "h", detail: "d", action: .update)
        #expect(a == AppLock.Problem(message: "m", hint: "h", detail: "d", action: .update))
        #expect(a != AppLock.Problem(message: "m", hint: "h", detail: "d", action: nil))
        #expect(a != AppLock.Problem(message: "other", hint: "h", detail: "d", action: .update))
        #expect(AppLock.Problem(message: "m") == AppLock.Problem(message: "m", hint: nil, detail: nil, action: nil))
    }

    @Test func lockProblemKeepsTheLockScreenErrorAndBlocksAutoPrompt() {
        let lock = AppLock()
        let problem = AppLock.Problem(message: "m")
        lock.lock(problem: problem)
        #expect(lock.isLocked)
        #expect(lock.lastError == problem)
        #expect(!lock.takeAutoPrompt())
    }

    @Test func bankSetupFinishErrorUsesOnlyTheKind() {
        let text = BankSetup.finishMessage(for: StoreError.corruptRow("DE00 0000 0000 0000 0000 00"))
        #expect(text == "Die Bank konnte nicht gespeichert werden (StoreError.corruptRow).")
        #expect(!text.contains("DE00"))
        #expect(BankSetup.finishMessage(for: VaultError.store(.closed))
            == "Die Bank konnte nicht gespeichert werden (VaultError.store(StoreError.closed)).")
    }
}
