import CryptoKit
import Foundation
import MFNCore

/// easybank JSON → MFN models. Pure functions, tested directly against the fixtures.
enum EasybankMapper {
    static let log = Log.logger("easybank")

    struct CardAccount: Sendable {
        var account: Account
        /// The bank's own account object; `AccountTransactionHistory` wants it echoed back.
        var raw: JSONValue
        var dto: EBAccount
    }

    struct History: Sendable {
        var transactions: [JSONValue]
        var summary: EBCardSummary?
    }

    // MARK: - Accounts

    /// Stable, non-reversible account ID: the card account number never appears in IDs or logs.
    static func accountID(number: String) -> AccountID {
        let digest = SHA256.hash(data: Data("easybank|\(number)".utf8))
        return AccountID("easybank:" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    /// Finds the landing `Item` (`AccountListResponse` + dashboard) in the `RetailLanding` answer.
    static func landing(in item: JSONValue) throws(ConnectorError) -> EBLanding {
        if item["AccountListResponse"] != nil {
            return try item.decode(EBLanding.self, context: "RetailLanding")
        }
        for call in item["InitialCallResponses"]?.arrayValue ?? [] {
            if let inner = call["Response"]?["Item"], inner["AccountListResponse"] != nil {
                return try inner.decode(EBLanding.self, context: "RetailLanding")
            }
        }
        throw .formatChanged(detail: "RetailLanding: AccountListResponse fehlt")
    }

    static func accounts(_ landing: EBLanding, connectionID: ConnectionID) throws(ConnectorError) -> [CardAccount] {
        let list = landing.accountListResponse.accountList ?? []
        // A customer always has at least one account: an empty list means the answer changed.
        guard !list.isEmpty else { throw .formatChanged(detail: "RetailLanding: AccountList leer") }

        var result: [CardAccount] = []
        for (index, raw) in list.enumerated() {
            let dto = try raw.decode(EBAccount.self, context: "AccountList[\(index)]")
            guard let number = dto.number, !number.isEmpty else {
                throw .formatChanged(detail: "AccountList[\(index)]: Feld fehlt Number")
            }
            switch dto.accountType {
            case .card:
                break
            case let .unknown(type):
                log.info("easybank: Kontotyp \(type, privacy: .public) wird übersprungen")
                continue
            case nil:
                throw .formatChanged(detail: "AccountList[\(index)]: Feld fehlt AccountType")
            }
            let account = Account(
                id: accountID(number: number),
                connectionID: connectionID,
                iban: nil, // card account: the IBAN in the answer is only the account for paying in
                type: .card,
                currency: dto.currentBalance?.currencyCode ?? "EUR",
                name: dto.accountName ?? dto.productName ?? "easybank Kreditkarte",
                cardLast4: cardLast4(number: number, dashboard: landing.dashboardTransactionItemList ?? []),
                creditLimitCents: dto.currentCreditLimit?.cents
            )
            result.append(CardAccount(account: account, raw: raw, dto: dto))
        }
        // Only non-card products (e.g. a future Tagesgeld layout): nothing we can read yet.
        guard !result.isEmpty else { throw .unsupportedAccount }
        return result
    }

    /// The card's last four digits, if the dashboard shows exactly one card for this account.
    /// Partner cards book into the same card account; with several cards there is no single number.
    static func cardLast4(number: String, dashboard: [EBDashboardItem]) -> String? {
        let masked = Set(dashboard.filter { $0.accountNumber == number }.compactMap { $0.transactionItem?.maskedCardNumber })
        guard masked.count == 1, let card = masked.first else { return nil }
        let digits = String(card.suffix(4))
        return digits.count == 4 && digits.allSatisfy(\.isNumber) ? digits : nil
    }

    static func balance(_ dto: EBAccount, account: Account, asOf: Date) throws(ConnectorError) -> Balance {
        guard let booked = dto.currentBalance?.cents else { throw .formatChanged(detail: "AccountList: Feld fehlt CurrentBalance") }
        return Balance(
            bookedCents: booked,
            availableCents: dto.availableCreditLimit?.cents ?? dto.availableBalanceInLocalCurrency?.cents,
            currency: dto.currentBalance?.currencyCode ?? account.currency,
            asOf: asOf
        )
    }

    // MARK: - History

    /// Splits the `AccountTransactionHistory` answer into transaction list and statement summary.
    static func history(in item: JSONValue) throws(ConnectorError) -> History {
        var list: EBTransactionList?
        var summary: EBCardSummary?
        for (index, call) in (item["InitialCallResponses"]?.arrayValue ?? []).enumerated() {
            guard let inner = call["Response"]?["Item"] else { continue }
            if inner["Transactions"] != nil {
                list = try inner.decode(EBTransactionList.self, context: "AccountTransactionHistory.InitialCallResponses[\(index)]")
            } else if inner["LastStatementDate"] != nil {
                summary = try inner.decode(EBCardSummary.self, context: "AccountTransactionHistory.InitialCallResponses[\(index)]")
            }
        }
        guard let list else { throw .formatChanged(detail: "AccountTransactionHistory: Transactions fehlt") }
        if list.otpRequired == true {
            // Not seen for this call in the fixtures; the OTP flow is not implemented (STATUS.md).
            throw .formatChanged(detail: "AccountTransactionHistory: OTP verlangt (nicht unterstützt)")
        }
        guard let transactions = list.transactions else { throw .formatChanged(detail: "AccountTransactionHistory: Transactions fehlt") }
        return History(transactions: transactions, summary: summary)
    }

    // MARK: - Transactions

    static func transactions(_ items: [JSONValue], account: Account) throws(ConnectorError) -> [Transaction] {
        var result: [Transaction] = []
        for (index, item) in items.enumerated() {
            let context = "Transactions[\(index)]"
            let dto = try item.decode(EBTransaction.self, context: context)

            guard let local = dto.localCurrencyAmount, let magnitude = local.cents.map(abs) else {
                throw .formatChanged(detail: "\(context): Feld fehlt LocalCurrencyAmount")
            }
            let amount: Int
            switch dto.transactionNature {
            case .debit: amount = -magnitude
            case .credit: amount = magnitude
            case .unknown, nil: throw .formatChanged(detail: "\(context): TransactionNature unbekannt")
            }
            guard let transactionDate = EBDate.day(dto.transactionDate) ?? EBDate.day(dto.valueDate) else {
                throw .formatChanged(detail: "\(context): Feld fehlt TransactionDate")
            }
            let postingDate = EBDate.day(dto.postingDate)

            // `IsPending` is not reliable (false for pending items in the list, true on the
            // dashboard); `TransactionType` carries the status.
            let status: TransactionStatus
            switch dto.transactionType {
            case .pending: status = .pending
            case .billed, .unbilled: status = .booked
            case let .unknown(type):
                log.info("easybank: TransactionType \(type, privacy: .public) unbekannt, Status aus Buchungsdatum")
                status = postingDate == nil ? .pending : .booked
            case nil:
                throw .formatChanged(detail: "\(context): Feld fehlt TransactionType")
            }

            let currency = local.currencyCode ?? account.currency
            var originalAmount: Int?
            var originalCurrency: String?
            if let foreign = dto.amount, let code = foreign.currencyCode, code != currency, let cents = foreign.cents {
                originalAmount = cents
                originalCurrency = code
            }

            result.append(EasybankTransactionBuilder.make(.init(
                accountID: account.id,
                status: status,
                bookingDate: postingDate,
                transactionDate: transactionDate,
                amountCents: amount,
                currency: currency,
                merchant: dto.merchantName ?? dto.description ?? "",
                details: dto.description,
                originalAmountCents: originalAmount,
                originalCurrency: originalCurrency,
                // InternalID changes with every request; ReferenceNumber is not unique. The ID is the
                // fingerprint (same as the CSV import).
                externalID: nil,
                rawJSON: item.data
            )))
        }
        return Transaction.uniquingIDs(result)
    }

    // MARK: - Statements

    /// The latest statement from the history summary.
    ///
    /// The bank delivers balance, statement date and due date only for the last statement; older
    /// statements need the (not recorded) statement list. Period: ends the day before the current
    /// cycle starts; starts after the previous statement date seen on billed transactions, else one
    /// month earlier (statement dates vary between the 17th and 18th, so this is approximate).
    static func latestStatement(_ summary: EBCardSummary, transactions: [JSONValue], account: Account) throws(ConnectorError) -> CardStatement? {
        guard let statementDate = EBDate.day(summary.lastStatementDate) else { return nil }
        guard let amount = summary.lastStatementBalancePer?.cents else {
            throw .formatChanged(detail: "AccountTransactionHistory: Feld fehlt LastStatementBalancePer")
        }
        let periodEnd = (EBDate.day(summary.cycleStartDate) ?? statementDate).adding(days: -1)
        let earlierStatements = transactions
            .compactMap { try? $0.decode(EBTransaction.self, context: "") }
            .compactMap { EBDate.day($0.statementDate) }
            .filter { $0 < periodEnd }
        let periodStart = earlierStatements.max()?.adding(days: 1) ?? periodEnd.adding(months: -1).adding(days: 1)
        let dueDate = EBDate.day(summary.paymentDueDate).flatMap { $0 > periodEnd ? $0 : nil }
        return CardStatement(
            accountID: account.id,
            periodStart: periodStart,
            periodEnd: periodEnd,
            dueDate: dueDate,
            amountCents: amount,
            currency: summary.lastStatementBalancePer?.currencyCode ?? account.currency
        )
    }
}
