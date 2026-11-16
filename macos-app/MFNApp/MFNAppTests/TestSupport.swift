import Foundation
import MFNCore
@testable import MFN

/// Synthetic data only (fake names, DE00 IBANs). Never opens the database, the Keychain or Touch ID.
enum Fixture {
    static let bank = Connection(id: "c-bank", connectorID: .mock, displayName: "Testbank")
    static let giro = Account(id: "a-giro", connectionID: "c-bank", iban: "DE00 0000 0000 0000 0000 00", type: .giro, name: "Giro")
    static let other = Account(id: "a-other", connectionID: "c-bank", type: .tagesgeld, name: "Rücklage")
    static let day = BankDay(year: 2026, month: 3, day: 14) ?? .today

    static func transaction(
        _ id: String, account: Account = giro, cents: Int = -1_000, status: TransactionStatus = .booked,
        importID: ImportBatchID? = nil, original: (cents: Int, currency: String)? = nil, purpose: String = "Test"
    ) -> MFNCore.Transaction {
        MFNCore.Transaction(
            id: TransactionID(id), accountID: account.id, bookingDate: status == .booked ? day : nil, valueDate: day,
            amountCents: cents, counterpartName: "Erika Mustermann", purpose: purpose, status: status,
            originalAmountCents: original?.cents, originalCurrency: original?.currency, importID: importID
        )
    }

    static func snapshot(transactions: [MFNCore.Transaction] = [], batches: [ImportBatch] = []) -> LedgerSnapshot {
        var snapshot = LedgerSnapshot()
        snapshot.connections = [bank]
        snapshot.accounts = [giro, other]
        snapshot.transactions = transactions
        snapshot.importBatches = batches
        return snapshot
    }

    /// A model that never touches the live database: it is locked and has no store.
    @MainActor
    static func model(ledger: LedgerSnapshot = snapshot()) -> AppModel {
        let model = AppModel(
            databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("mfn-tests-\(UUID().uuidString).db"),
            keyAccount: "mfn.tests.never-used",
            isDemo: false,
            registerConnectors: { _, _, _ in }
        )
        #if DEBUG
        model.applyLedgerForTesting(ledger)
        #endif
        return model
    }
}
