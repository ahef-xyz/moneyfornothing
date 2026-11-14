import Foundation

/// Merges a fresh connector result for one account into the stored transactions.
///
/// Rules (CLAUDE.md §4):
/// - Same `id` → incoming replaces stored; categorisation of the stored row is kept.
/// - A stored pending/planned transaction that the bank no longer reports is either
///   - replaced by the matching booked transaction (same merchant, same amount – ± 2 % for
///     foreign currency – and date ± 3 days):
///     the booked row inherits the categorisation, the pending row is deleted — never doubled, or
///   - deleted, if it lies inside the fetched window (reservation expired / order deleted).
/// - A pending transaction the bank reports together with its booking (some banks list the
///   reservation for a while after booking) is dropped the same way; here the reservation must
///   not be dated after the booking, so a later purchase at the same merchant stays.
///   Every booked transaction resolves at most one pending one.
/// - Stored booked transactions are never deleted: banks only return a limited history
///   (ING: 90 days), older bookings must survive.
public enum TransactionMerger {
    public struct Result: Sendable, Equatable {
        /// Transactions to insert or replace.
        public var upserts: [Transaction] = []
        /// IDs of stored transactions to delete.
        public var deletions: Set<TransactionID> = []
        /// Pending/planned ID → booked ID it was resolved into.
        public var resolved: [TransactionID: TransactionID] = [:]

        /// Nothing to write.
        public var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }
    }

    public static let matchWindowDays = 3

    public static func merge(stored: [Transaction], incoming: [Transaction], since: BankDay?) -> Result {
        var result = Result()
        let storedByID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(incoming.map(\.id))

        // Stored pending/planned rows that vanished from the bank's answer.
        var vanished = stored.filter { ($0.status == .pending || $0.status == .planned) && !incomingIDs.contains($0.id) }
        // Booked rows that already resolved a pending one.
        var claimed: Set<TransactionID> = []

        var upserts: [Transaction] = []
        for var transaction in incoming {
            if let existing = storedByID[transaction.id] {
                transaction.inheritCategory(from: existing)
            } else if transaction.status == .booked,
                      let index = vanished.firstIndex(where: { matches(pending: $0, booked: transaction) }) {
                let pending = vanished.remove(at: index)
                transaction.inheritCategory(from: pending)
                result.resolved[pending.id] = transaction.id
                result.deletions.insert(pending.id)
                claimed.insert(transaction.id)
            }
            upserts.append(transaction)
        }

        // Pending rows reported next to their booking.
        var dropped: Set<Int> = []
        for pendingIndex in upserts.indices where upserts[pendingIndex].status == .pending {
            let pending = upserts[pendingIndex]
            guard let bookedIndex = upserts.indices.first(where: {
                upserts[$0].status == .booked && !claimed.contains(upserts[$0].id) && resolves(pending: pending, booked: upserts[$0])
            }) else { continue }
            claimed.insert(upserts[bookedIndex].id)
            upserts[bookedIndex].inheritCategory(from: pending)
            result.resolved[pending.id] = upserts[bookedIndex].id
            if storedByID[pending.id] != nil { result.deletions.insert(pending.id) }
            dropped.insert(pendingIndex)
        }
        result.upserts = upserts.indices.filter { !dropped.contains($0) }.map { upserts[$0] }

        // Remaining vanished rows: delete if the fetch covered their date.
        for transaction in vanished where since.map({ transaction.effectiveDate >= $0 }) ?? true {
            result.deletions.insert(transaction.id)
        }
        return result
    }

    /// A pending transaction reported together with `booked` is its reservation: `matches` and
    /// not dated after the booking.
    public static func resolves(pending: Transaction, booked: Transaction) -> Bool {
        pending.effectiveDate <= booked.effectiveDate && matches(pending: pending, booked: booked)
    }

    /// Foreign-currency card payments are reserved at one rate and booked at another.
    public static let foreignCurrencyTolerance = 0.02

    /// Pending ↔ booked match: same account, same merchant, date within ± 3 days, same amount
    /// (± 2 % if either side carries an original foreign currency).
    public static func matches(pending: Transaction, booked: Transaction) -> Bool {
        guard pending.accountID == booked.accountID,
              abs(pending.effectiveDate.days(to: booked.effectiveDate)) <= matchWindowDays,
              sameAmount(pending, booked)
        else { return false }
        return sameMerchant(pending.counterpartName, booked.counterpartName)
    }

    static func sameAmount(_ pending: Transaction, _ booked: Transaction) -> Bool {
        if pending.amountCents == booked.amountCents { return true }
        let foreign = (pending.originalCurrency.map { $0 != pending.currency } ?? false)
            || (booked.originalCurrency.map { $0 != booked.currency } ?? false)
        guard foreign, pending.amountCents.signum() == booked.amountCents.signum(), booked.amountCents != 0 else { return false }
        let deviation = abs(Double(pending.amountCents - booked.amountCents)) / abs(Double(booked.amountCents))
        return deviation <= foreignCurrencyTolerance
    }

    /// Merchant names differ between reservation and booking ("REWE Markt" vs.
    /// "REWE MARKT GMBH SAGT DANKE"). Compare alphanumerics only; one must be a prefix of the other.
    static func sameMerchant(_ lhs: String, _ rhs: String) -> Bool {
        let a = merchantKey(lhs)
        let b = merchantKey(rhs)
        guard !a.isEmpty, !b.isEmpty else { return a == b }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    static func merchantKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension Transaction {
    mutating func inheritCategory(from other: Transaction) {
        guard categoryID == nil, other.categoryID != nil else { return }
        categoryID = other.categoryID
        categorySource = other.categorySource
        confidence = other.confidence
    }
}
