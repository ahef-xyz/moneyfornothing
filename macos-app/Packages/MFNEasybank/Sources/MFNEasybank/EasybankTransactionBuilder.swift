import Foundation
import MFNCore

/// The single place where easybank card data becomes a `Transaction`.
///
/// Both import paths – the web-banking JSON (`EasybankConnector`) and the CSV export
/// (`EasybankCSVImporter`) – go through here, so the same booking gets the same purpose text,
/// the same counterpart and therefore the same `Fingerprint` (CLAUDE.md §4).
enum EasybankTransactionBuilder {
    struct Input: Sendable {
        var accountID: AccountID
        var status: TransactionStatus
        /// Booking day; ignored for pending/planned (they never carry a booking date).
        var bookingDate: BankDay?
        /// Transaction (authorisation) day.
        var transactionDate: BankDay
        var amountCents: Int
        var currency: String
        /// Merchant as the bank shows it.
        var merchant: String
        /// Additional description, if the source has one separate from the merchant.
        var details: String?
        var originalAmountCents: Int?
        var originalCurrency: String?
        var externalID: String?
        var rawJSON: Data
    }

    static func make(_ input: Input) -> Transaction {
        let merchant = collapse(input.merchant)
        let details = input.details.map(collapse) ?? ""
        let purpose: String = if details.isEmpty || details == merchant { merchant } else { "\(merchant) \(details)" }

        let isDated = input.status == .booked || input.status == .cancelled
        let bookingDate = isDated ? (input.bookingDate ?? input.transactionDate) : nil

        // Original amount only together with a currency and only if it differs from the account currency.
        var originalAmount: Int?
        var originalCurrency: String?
        if let amount = input.originalAmountCents, let currency = input.originalCurrency?.uppercased(),
           currency.count == 3, currency != input.currency.uppercased() {
            // Exports often show the foreign amount unsigned; align with the booked sign.
            originalAmount = input.amountCents < 0 ? -abs(amount) : abs(amount)
            originalCurrency = currency
        }

        return Transaction(
            accountID: input.accountID,
            bookingDate: bookingDate,
            valueDate: input.transactionDate,
            amountCents: input.amountCents,
            currency: input.currency.uppercased(),
            counterpartName: merchant,
            counterpartIBAN: nil,
            purpose: purpose,
            status: input.status,
            externalID: input.externalID,
            originalAmountCents: originalAmount,
            originalCurrency: originalCurrency,
            rawJSON: input.rawJSON
        )
    }

    /// Single spaces, no surrounding whitespace.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Keeps transactions on or after the bank day of `since`; pending ones are always kept
    /// (`BankConnector` contract).
    static func filter(_ transactions: [Transaction], since: Date?) -> [Transaction] {
        guard let since else { return transactions }
        let cut = BankDay(since)
        return transactions.filter { $0.status == .pending || $0.effectiveDate >= cut }
    }
}
