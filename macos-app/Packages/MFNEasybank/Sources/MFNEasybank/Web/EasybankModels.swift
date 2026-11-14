import Foundation
import MFNCore

// Tolerant DTOs for the easybank web-banking JSON (CLAUDE.md §6): unknown fields ignored,
// everything optional that the fixtures do not prove to be always present, enums with `unknown`.

/// `{"Item": …, "Result": {"IsSuccess": …}}` – every easybank answer.
struct EBEnvelope: Decodable, Sendable {
    struct Outcome: Decodable, Sendable {
        var isSuccess: Bool?

        enum CodingKeys: String, CodingKey {
            case isSuccess = "IsSuccess"
        }
    }

    var item: JSONValue?
    var result: Outcome?

    enum CodingKeys: String, CodingKey {
        case item = "Item"
        case result = "Result"
    }
}

struct EBMoney: Decodable, Hashable, Sendable {
    struct CurrencyCode: Decodable, Hashable, Sendable {
        var code: String?

        enum CodingKeys: String, CodingKey {
            case code = "Code"
        }
    }

    var value: Decimal?
    var currency: CurrencyCode?

    /// Cents, rounded half-up (the bank sends at most 2–3 decimals; JSON floats may be inexact).
    var cents: Int? {
        guard var value = self.value else { return nil }
        value *= 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        guard abs(number.doubleValue) < 9e15 else { return nil }
        return number.intValue
    }

    var currencyCode: String? {
        guard let code = currency?.code?.uppercased(), code.count == 3 else { return nil }
        return code
    }

    enum CodingKeys: String, CodingKey {
        case value = "Value"
        case currency = "Currency"
    }
}

enum EBAccountType: Decodable, Hashable, Sendable {
    case card
    case unknown(String)

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw.lowercased() == "card" ? .card : .unknown(raw)
    }
}

struct EBAccount: Decodable, Sendable {
    var number: String?
    var accountName: String?
    var productName: String?
    var accountType: EBAccountType?
    var currentBalance: EBMoney?
    var availableCreditLimit: EBMoney?
    var availableBalanceInLocalCurrency: EBMoney?
    var currentCreditLimit: EBMoney?

    enum CodingKeys: String, CodingKey {
        case number = "Number"
        case accountName = "AccountName"
        case productName = "ProductName"
        case accountType = "AccountType"
        case currentBalance = "CurrentBalance"
        case availableCreditLimit = "AvailableCreditLimit"
        case availableBalanceInLocalCurrency = "AvailableBalanceInLocalCurrency"
        case currentCreditLimit = "CurrentCreditLimit"
    }
}

struct EBAccountListResponse: Decodable, Sendable {
    var accountList: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case accountList = "AccountList"
    }
}

struct EBDashboardItem: Decodable, Sendable {
    struct DashboardTransaction: Decodable, Sendable {
        var maskedCardNumber: String?

        enum CodingKeys: String, CodingKey {
            case maskedCardNumber = "MaskedCardNumber"
        }
    }

    var accountNumber: String?
    var transactionItem: DashboardTransaction?

    enum CodingKeys: String, CodingKey {
        case accountNumber = "AccountNumber"
        case transactionItem = "TransactionItem"
    }
}

/// `Item` of the landing call that holds the accounts (`cards.json`).
struct EBLanding: Decodable, Sendable {
    var accountListResponse: EBAccountListResponse
    var dashboardTransactionItemList: [EBDashboardItem]?

    enum CodingKeys: String, CodingKey {
        case accountListResponse = "AccountListResponse"
        case dashboardTransactionItemList = "DashboardTransactionItemList"
    }
}

enum EBTransactionType: Decodable, Hashable, Sendable {
    /// On a past statement.
    case billed
    /// Booked, not yet on a statement.
    case unbilled
    /// Authorised, not booked ("vorgemerkt").
    case pending
    case unknown(String)

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "billed": self = .billed
        case "unbilled": self = .unbilled
        case "pending": self = .pending
        default: self = .unknown(raw)
        }
    }
}

enum EBNature: Decodable, Hashable, Sendable {
    case debit
    case credit
    case unknown(String)

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "debit": self = .debit
        case "credit": self = .credit
        default: self = .unknown(raw)
        }
    }
}

struct EBTransaction: Decodable, Sendable {
    var postingDate: String?
    var transactionDate: String?
    var valueDate: String?
    var statementDate: String?
    var description: String?
    var merchantName: String?
    var amount: EBMoney?
    var localCurrencyAmount: EBMoney?
    var transactionNature: EBNature?
    var transactionType: EBTransactionType?
    var isPending: Bool?

    enum CodingKeys: String, CodingKey {
        case postingDate = "PostingDate"
        case transactionDate = "TransactionDate"
        case valueDate = "ValueDate"
        case statementDate = "StatementDate"
        case description = "Description"
        case merchantName = "MerchantName"
        case amount = "Amount"
        case localCurrencyAmount = "LocalCurrencyAmount"
        case transactionNature = "TransactionNature"
        case transactionType = "TransactionType"
        case isPending = "IsPending"
    }
}

/// `Item` of `GetTransactions` and of the transaction list inside `AccountTransactionHistory`.
struct EBTransactionList: Decodable, Sendable {
    var transactions: [JSONValue]?
    var otpRequired: Bool?
    var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case transactions = "Transactions"
        case otpRequired = "OTPRequired"
        case hasMore = "HasMore"
    }
}

/// Statement summary inside `AccountTransactionHistory`.
struct EBCardSummary: Decodable, Sendable {
    var lastStatementDate: String?
    var lastStatementBalancePer: EBMoney?
    var paymentDueDate: String?
    var cycleStartDate: String?
    var nextStatementDate: String?
    var currentBalance: EBMoney?

    enum CodingKeys: String, CodingKey {
        case lastStatementDate = "LastStatementDate"
        case lastStatementBalancePer = "LastStatementBalancePer"
        case paymentDueDate = "PaymentDueDate"
        case cycleStartDate = "CycleStartDate"
        case nextStatementDate = "NextStatementDate"
        case currentBalance = "CurrentBalance"
    }
}

enum EBDate {
    /// Bank day of an easybank timestamp (`2026-11-09T16:19:47+00:00`, `…T22:12:40.1490547+00:00`,
    /// `…Z`) in Europe/Berlin. `0001-01-01…` (the bank's "no date") and garbage give `nil`.
    static func day(_ text: String?) -> BankDay? {
        guard let text, text.count >= 10 else { return nil }
        let dateText = String(text.prefix(10))
        guard let calendarDay = BankDay(iso: dateText), calendarDay.year >= 1900 else { return nil }
        guard text.count > 10 else { return calendarDay }

        let rest = text.dropFirst(11) // after "T"
        let timeText = rest.prefix(8)
        let parts = timeText.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return calendarDay }

        var offsetSeconds = 0
        if rest.hasSuffix("Z") {
            offsetSeconds = 0
        } else if let signIndex = rest.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let offset = rest[rest.index(after: signIndex)...].split(separator: ":").compactMap { Int($0) }
            guard offset.count == 2 else { return calendarDay }
            offsetSeconds = (offset[0] * 3600 + offset[1] * 60) * (rest[signIndex] == "-" ? -1 : 1)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let components = DateComponents(year: calendarDay.year, month: calendarDay.month, day: calendarDay.day, hour: parts[0], minute: parts[1], second: parts[2])
        guard let local = utc.date(from: components) else { return calendarDay }
        return BankDay(local.addingTimeInterval(TimeInterval(-offsetSeconds)))
    }
}
