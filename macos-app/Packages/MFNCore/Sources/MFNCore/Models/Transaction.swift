import Foundation

public enum TransactionStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Final booking.
    case booked
    /// Reserved/authorised, not yet booked ("vorgemerkt").
    case pending
    /// Future booking known to the bank (standing order, scheduled direct debit).
    case planned
    /// Reversed or voided.
    case cancelled
}

public enum CategorySource: String, Codable, Sendable, CaseIterable, Hashable {
    case rule
    case knn
    case llm
    case manual
}

/// One movement on an account.
///
/// Everything a connector delivers is immutable (`let`); only the categorisation fields are
/// written later by `MFNCore`. The `fingerprint` is computed once in the initialiser from the
/// connector-supplied fields (see `Fingerprint`).
public struct Transaction: Identifiable, Hashable, Codable, Sendable {
    public let id: TransactionID
    public let accountID: AccountID
    /// `nil` for pending and planned transactions.
    public let bookingDate: BankDay?
    public let valueDate: BankDay
    /// Signed amount in cents: negative = outflow, positive = inflow.
    public let amountCents: Int
    public let currency: String
    public let counterpartName: String
    public let counterpartIBAN: String?
    public let purpose: String
    public let eref: String?
    public let mref: String?
    public let creditorID: String?
    public let status: TransactionStatus
    /// Bank-side identifier, if the bank has one (Trade Republic timeline ID, C24 booking ID …).
    public let externalID: String?
    public let fingerprint: String
    /// Amount in the original currency for foreign-currency card transactions.
    public let originalAmountCents: Int?
    public let originalCurrency: String?
    /// Raw bank payload for this transaction, unchanged. Interpretation happens only in `MFNCore`.
    public let rawJSON: Data

    public var categoryID: CategoryID?
    public var categorySource: CategorySource?
    public var confidence: Double?

    public init(
        id: TransactionID? = nil,
        accountID: AccountID,
        bookingDate: BankDay?,
        valueDate: BankDay,
        amountCents: Int,
        currency: String = "EUR",
        counterpartName: String,
        counterpartIBAN: String? = nil,
        purpose: String,
        eref: String? = nil,
        mref: String? = nil,
        creditorID: String? = nil,
        status: TransactionStatus,
        externalID: String? = nil,
        originalAmountCents: Int? = nil,
        originalCurrency: String? = nil,
        rawJSON: Data = Data("{}".utf8),
        categoryID: CategoryID? = nil,
        categorySource: CategorySource? = nil,
        confidence: Double? = nil
    ) {
        let fingerprint = Fingerprint.make(
            accountID: accountID,
            bookingDate: bookingDate,
            amountCents: amountCents,
            purpose: purpose,
            counterpartIBAN: counterpartIBAN
        )
        self.id = id ?? TransactionID(externalID.map { "ext:\($0)" } ?? "fp:\(fingerprint)")
        self.accountID = accountID
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.amountCents = amountCents
        self.currency = currency
        self.counterpartName = counterpartName
        self.counterpartIBAN = counterpartIBAN
        self.purpose = purpose
        self.eref = eref
        self.mref = mref
        self.creditorID = creditorID
        self.status = status
        self.externalID = externalID
        self.fingerprint = fingerprint
        self.originalAmountCents = originalAmountCents
        self.originalCurrency = originalCurrency
        self.rawJSON = rawJSON
        self.categoryID = categoryID
        self.categorySource = categorySource
        self.confidence = confidence
    }

    /// The day the transaction belongs to for sorting, filtering and `since` checks.
    public var effectiveDate: BankDay { bookingDate ?? valueDate }

    public var isInflow: Bool { amountCents > 0 }
}

extension Transaction {
    /// Makes IDs unique within one connector result.
    ///
    /// Two genuinely identical bookings (two coffees, same day, same amount, same text) share a
    /// fingerprint. Connectors call this before returning so each gets a distinct, still
    /// deterministic ID (`…#2`, `…#3` in delivery order). The fingerprint itself stays unchanged.
    public static func uniquingIDs(_ transactions: [Transaction]) -> [Transaction] {
        var seen: [TransactionID: Int] = [:]
        return transactions.map { transaction in
            let count = (seen[transaction.id] ?? 0) + 1
            seen[transaction.id] = count
            guard count > 1 else { return transaction }
            return transaction.withID(TransactionID("\(transaction.id.rawValue)#\(count)"))
        }
    }

    func withID(_ newID: TransactionID) -> Transaction {
        Transaction(
            id: newID, accountID: accountID, bookingDate: bookingDate, valueDate: valueDate,
            amountCents: amountCents, currency: currency, counterpartName: counterpartName,
            counterpartIBAN: counterpartIBAN, purpose: purpose, eref: eref, mref: mref,
            creditorID: creditorID, status: status, externalID: externalID,
            originalAmountCents: originalAmountCents, originalCurrency: originalCurrency,
            rawJSON: rawJSON, categoryID: categoryID, categorySource: categorySource,
            confidence: confidence
        )
    }
}
