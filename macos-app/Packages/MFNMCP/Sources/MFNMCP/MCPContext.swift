import CryptoKit
import Foundation
import MFNCore

/// What a tool call may read: the ledger as the UI has it, limited to the accounts the user ticked
/// in Settings. Built by the app for every call while it is unlocked and the switch is on.
public struct MCPContext: Sendable {
    public var snapshot: LedgerSnapshot
    /// Accounts the client may see (Settings → MCP, account checklist).
    public var scope: Set<AccountID>
    /// Per-install random bytes for the opaque IDs (`MCPIdentifiers`).
    public var idSalt: Data
    public var today: BankDay
    /// Fixed costs the user hid in "Fixkosten" (by `RecurringPayment.id`).
    public var isRecurringHidden: @Sendable (String) -> Bool

    public init(snapshot: LedgerSnapshot, scope: Set<AccountID>, idSalt: Data, today: BankDay = .today,
                isRecurringHidden: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.snapshot = snapshot
        self.scope = scope
        self.idSalt = idSalt
        self.today = today
        self.isRecurringHidden = isRecurringHidden
    }
}

/// Opaque IDs for the client. Account and transaction IDs inside MFN can carry bank data
/// (transaction IDs are built from the bank's external ID or the fingerprint), so the client
/// only ever sees a salted hash. Stable for one install, meaningless outside it.
struct MCPIdentifiers: Sendable {
    let salt: Data

    func account(_ id: AccountID) -> String { "a_" + hash("account", id.rawValue, length: 6) }
    func transaction(_ id: TransactionID) -> String { "t_" + hash("transaction", id.rawValue, length: 9) }

    private func hash(_ kind: String, _ value: String, length: Int) -> String {
        var data = salt
        data.append(Data(kind.utf8))
        data.append(0)
        data.append(Data(value.utf8))
        return SHA256.hash(data: data).prefix(length).map { String(format: "%02x", $0) }.joined()
    }
}

/// The ledger as one tool call sees it: only accounts in scope, opaque IDs both ways.
struct ScopedLedger {
    let context: MCPContext
    let ids: MCPIdentifiers
    let accounts: [Account]
    let accountsByOpaqueID: [String: Account]
    /// Transactions of accounts in scope, newest first (snapshot order).
    let transactions: [Transaction]

    init(_ context: MCPContext) {
        self.context = context
        ids = MCPIdentifiers(salt: context.idSalt)
        // Stable order (the snapshot's follows the order of the last syncs): bank, type, name.
        let banks = Dictionary(context.snapshot.connections.map { ($0.id, $0.displayName.lowercased()) }, uniquingKeysWith: { a, _ in a })
        let typeOrder: [AccountType: Int] = [.giro: 0, .tagesgeld: 1, .card: 2, .depot: 3]
        accounts = context.snapshot.accounts.filter { context.scope.contains($0.id) }.sorted { a, b in
            let left = (banks[a.connectionID] ?? "", typeOrder[a.type] ?? 9, context.snapshot.displayName(of: a).lowercased(), a.id.rawValue)
            let right = (banks[b.connectionID] ?? "", typeOrder[b.type] ?? 9, context.snapshot.displayName(of: b).lowercased(), b.id.rawValue)
            return left < right
        }
        var byOpaque: [String: Account] = [:]
        for account in accounts { byOpaque[ids.account(account.id)] = account }
        accountsByOpaqueID = byOpaque
        let inScope = Set(accounts.map(\.id))
        // Every account shared (the default): no copy of the whole history per call.
        transactions = inScope.count == context.snapshot.accounts.count
            ? context.snapshot.transactions
            : context.snapshot.transactions.filter { inScope.contains($0.accountID) }
    }

    var snapshot: LedgerSnapshot { context.snapshot }

    /// IBANs of all the user's accounts (also unshared ones: a transfer there is still own money).
    var ownIBANs: Set<String> { Set(context.snapshot.accounts.compactMap(\.iban).filter { !$0.isEmpty }) }
    var today: BankDay { context.today }

    func transactions(of account: AccountID) -> [Transaction] {
        context.scope.contains(account) ? snapshot.transactions(of: account) : []
    }

    /// The transaction behind an opaque ID, if it belongs to an account in scope.
    func transaction(opaque: String) -> Transaction? {
        transactions.first { ids.transaction($0.id) == opaque }
    }

    func connection(of account: Account) -> Connection? {
        snapshot.connections.first { $0.id == account.connectionID }
    }

    /// Display name without card or account numbers.
    func name(of account: Account) -> String {
        FieldRules.scrubNumbers(snapshot.displayName(of: account))
    }
}

/// The field rules of docs/v0.6.0.md section 4 in one place. Every account and transaction that
/// leaves MFN goes through `account(_:)` and `transaction(_:)`.
enum FieldRules {
    /// Longest purpose text returned (third-party text, see `transaction(_:in:detail:)`).
    static let purposeLimit = 140
    /// Longest counterparty name returned.
    static let counterpartyLimit = 80

    static func account(_ account: Account, in ledger: ScopedLedger) -> JSONValue {
        [
            "id": .string(ledger.ids.account(account.id)),
            "name": .string(ledger.name(of: account)),
            "type": .string(accountType(account.type)),
            "currency": .string(account.currency),
            "bank": .string(ledger.connection(of: account).map { scrubNumbers($0.displayName) } ?? ""),
        ]
    }

    static func accountType(_ type: AccountType) -> String {
        switch type {
        case .giro: "giro"
        case .tagesgeld: "tagesgeld"
        case .depot: "depot"
        case .card: "card"
        }
    }

    /// A booking without IBANs, references, IDs from the bank, fingerprint or raw data.
    /// `detail` adds the (cut) purpose text.
    static func transaction(_ transaction: Transaction, in ledger: ScopedLedger, detail: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(ledger.ids.transaction(transaction.id)),
            "account_id": .string(ledger.ids.account(transaction.accountID)),
            "date": .string(transaction.effectiveDate.iso),
            "amount": .string(Money.decimal(transaction.amountCents)),
            "currency": .string(transaction.currency),
            "status": .string(status(transaction.status)),
            "counterparty_text_untrusted": .string(thirdParty(transaction.counterpartName, limit: counterpartyLimit)),
            "category_id": .optional(transaction.categoryID?.rawValue),
            "category": .optional(transaction.categoryID.map(CategoryCatalog.title)),
        ]
        if let source = transaction.categorySource, transaction.categoryID != nil {
            object["category_source"] = .string(categorySource(source))
        }
        if let original = transaction.originalAmountCents, let currency = transaction.originalCurrency {
            object["original_amount"] = .string(Money.decimal(original))
            object["original_currency"] = .string(currency)
        }
        if detail {
            object["purpose_text_untrusted"] = .string(thirdParty(transaction.purpose, limit: purposeLimit))
            object["value_date"] = .string(transaction.valueDate.iso)
            if let booking = transaction.bookingDate { object["booking_date"] = .string(booking.iso) }
        }
        return .object(object)
    }

    static func status(_ status: TransactionStatus) -> String {
        switch status {
        case .booked: "booked"
        case .pending: "pending"
        case .planned: "planned"
        case .cancelled: "cancelled"
        }
    }

    static func categorySource(_ source: CategorySource) -> String {
        switch source {
        case .manual: "manual"
        case .rule: "rule"
        case .knn: "similar"
        case .llm: "model"
        }
    }

    static func cut(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Text from a client or the helper for display in MFN's own UI: no control, line break or
    /// bidirectional formatting characters (they could fake lines in the approval prompt).
    static func displayText(_ text: String, limit: Int) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: false
            default: true
            }
        }))
        return cut(cleaned, to: limit)
    }

    /// Third-party text as the client sees it (and as `search_transactions` searches it).
    static func thirdParty(_ text: String, limit: Int) -> String {
        cut(scrubAccountNumbers(scrubIBANs(text)), to: limit)
    }

    /// Runs of 9 or more digits (account and card numbers; dates have 8) become "…".
    static func scrubAccountNumbers(_ text: String) -> String {
        text.replacing(/\d(?:[ .-]?\d){8,}/, with: "…")
    }

    /// Runs of 4 or more digits (card and account numbers in names) become "…".
    static func scrubNumbers(_ text: String) -> String {
        text.replacing(/\d[\d ]{2,}\d/, with: "…")
    }

    /// IBAN-like sequences in third-party text (purpose lines often repeat the payer's IBAN).
    static func scrubIBANs(_ text: String) -> String {
        text.replacing(/[A-Za-z]{2}\d{2}(?:[ .-]?[A-Za-z0-9]{4}){2,7}(?:[ .-]?[A-Za-z0-9]{1,3})?/.ignoresCase(), with: "[IBAN]")
    }
}

/// Amounts as decimal strings ("-412.37"), never floats.
enum Money {
    static func decimal(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let magnitude = cents.magnitude
        let fraction = magnitude % 100
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    static func amount(_ cents: Int, _ currency: String) -> JSONValue {
        ["amount": .string(decimal(cents)), "currency": .string(currency)]
    }

    /// "12.5", "-3", "4,99" → cents; `nil` for anything else (also more than 2 decimals, units,
    /// thousands separators).
    static func cents(_ value: JSONValue?) -> Int? {
        switch value {
        case let .string(text)?:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.wholeMatch(of: /-?[0-9]+([.,][0-9]{1,2})?/) != nil else { return nil }
            let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
            guard let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            return cents(decimal)
        case let .number(number)?:
            return cents(Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(number))
        default:
            return nil
        }
    }

    private static func cents(_ decimal: Decimal) -> Int? {
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled, abs(rounded) < 1_000_000_000_000 else { return nil }
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
