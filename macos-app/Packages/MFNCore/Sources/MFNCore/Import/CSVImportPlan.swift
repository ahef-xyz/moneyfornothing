import Foundation

/// Which imported rows are new and which the ledger already has.
///
/// - **Duplicate**: a stored transaction of the account has the same fingerprint (re-import of
///   the same file, or a sync that delivered the same booking with the same purpose and IBAN).
///   Counted per fingerprint: two identical coffees in the file and one stored → one new.
/// - **Likely duplicate**: no fingerprint match, but a stored booked transaction on the same
///   day with the same amount and merchant (a sync that writes the purpose differently than the
///   export). Skipped unless the user includes them.
/// - Everything else is **new**.
public struct CSVImportPlan: Sendable, Hashable {
    public var new: [Transaction] = []
    public var duplicates: [Transaction] = []
    public var likelyDuplicates: [Transaction] = []

    public init(new: [Transaction] = [], duplicates: [Transaction] = [], likelyDuplicates: [Transaction] = []) {
        self.new = new
        self.duplicates = duplicates
        self.likelyDuplicates = likelyDuplicates
    }

    /// `stored`: the account's transactions in the ledger (all statuses).
    public static func make(incoming: [Transaction], stored: [Transaction]) -> CSVImportPlan {
        var plan = CSVImportPlan()
        // Stored rows per fingerprint; keys stay at 0 once used up, so the keys are also the set
        // of stored fingerprints.
        var remaining: [String: Int] = [:]
        for transaction in stored { remaining[transaction.fingerprint, default: 0] += 1 }

        // Booked rows without fingerprint twin, by (account, day, amount), for the fuzzy check.
        var candidates: [FuzzyKey: [Transaction]] = [:]
        let incomingFingerprints = Set(incoming.map(\.fingerprint))
        for transaction in stored where transaction.status == .booked && !incomingFingerprints.contains(transaction.fingerprint) {
            candidates[FuzzyKey(transaction), default: []].append(transaction)
        }

        for transaction in incoming {
            let fingerprint = transaction.fingerprint
            if let count = remaining[fingerprint] {
                if count > 0 {
                    remaining[fingerprint] = count - 1
                    plan.duplicates.append(transaction)
                } else {
                    plan.new.append(transaction)
                }
                continue
            }
            let key = FuzzyKey(transaction)
            if let index = candidates[key]?.firstIndex(where: { sameBooking(transaction, $0) }) {
                candidates[key]?.remove(at: index)
                plan.likelyDuplicates.append(transaction)
            } else {
                plan.new.append(transaction)
            }
        }
        return plan
    }

    public func transactionsToImport(includingLikelyDuplicates: Bool) -> [Transaction] {
        includingLikelyDuplicates ? new + likelyDuplicates : new
    }

    /// The write for `LedgerStore.apply(_:)`: the shared `TransactionMerger`, so an imported
    /// booking resolves a stored pending one (category inherited, pending row deleted).
    ///
    /// Unlike a sync, an import says nothing about pending rows it does not contain: only
    /// pending rows a booking resolved are deleted. Rows whose ID is already taken by a stored
    /// transaction (another fingerprint can never produce it, but a `#n` suffix can) get the
    /// next free suffix, so nothing stored is replaced.
    public static func merge(_ transactions: [Transaction], into stored: [Transaction]) -> TransactionMerger.Result {
        var taken = Set(stored.map(\.id))
        var unique: [Transaction] = []
        for transaction in transactions {
            var candidate = transaction
            var suffix = 2
            let base = transaction.id.rawValue.split(separator: "#").first.map(String.init) ?? transaction.id.rawValue
            while taken.contains(candidate.id) {
                candidate = transaction.withID(TransactionID("\(base)#\(suffix)"))
                suffix += 1
            }
            taken.insert(candidate.id)
            unique.append(candidate)
        }
        var result = TransactionMerger.merge(stored: stored, incoming: unique, since: nil)
        result.deletions = result.deletions.intersection(result.resolved.keys)
        return result
    }

    private struct FuzzyKey: Hashable {
        var account: AccountID
        var day: BankDay
        var amount: Int
        init(_ transaction: Transaction) {
            account = transaction.accountID
            day = transaction.effectiveDate
            amount = transaction.amountCents
        }
    }

    /// Same merchant (prefix match like pending → booked) or, without names, the same purpose start.
    static func sameBooking(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        let a = TransactionMerger.merchantKey(lhs.counterpartName)
        let b = TransactionMerger.merchantKey(rhs.counterpartName)
        if !a.isEmpty, !b.isEmpty { return a.hasPrefix(b) || b.hasPrefix(a) }
        let p = Fingerprint.normalize(purpose: lhs.purpose)
        let q = Fingerprint.normalize(purpose: rhs.purpose)
        guard !p.isEmpty, !q.isEmpty else { return false }
        return p.hasPrefix(q) || q.hasPrefix(p)
    }
}
