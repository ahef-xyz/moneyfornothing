import Foundation
import MFNCore

/// Event types of the Trade Republic timeline. Unknown types are kept and still delivered.
enum TREventType: Hashable, Sendable {
    case cardTransaction          // card_successful_transaction
    case cardRefund               // card_refund
    case cardFailed               // card_failed_transaction
    case cardATMWithdrawal        // card_successful_atm_withdrawal
    case paymentInbound           // BANK_TRANSACTION_INCOMING (fixture), PAYMENT_INBOUND*, INCOMING_TRANSFER*
    case paymentOutbound          // BANK_TRANSACTION_OUTGOING (fixture), PAYMENT_OUTBOUND, OUTGOING_TRANSFER*
    case directDebit              // *DIRECT_DEBIT*
    case interest                 // INTEREST_PAYOUT*
    case trade                    // TRADING_TRADE_EXECUTED (fixture), ORDER_EXECUTED, TRADE_INVOICE, SAVINGS_PLAN_*
    case corporateAction          // SSP_CORPORATE_ACTION_CASH (fixture): dividends, distributions
    case unknown(String)

    init(_ raw: String?) {
        let raw = raw ?? ""
        let upper = raw.uppercased()
        switch upper {
        case "CARD_SUCCESSFUL_TRANSACTION": self = .cardTransaction
        case "CARD_REFUND": self = .cardRefund
        case "CARD_FAILED_TRANSACTION": self = .cardFailed
        case "CARD_SUCCESSFUL_ATM_WITHDRAWAL": self = .cardATMWithdrawal
        default:
            if upper.contains("DIRECT_DEBIT") {
                self = .directDebit
            } else if upper == "BANK_TRANSACTION_INCOMING" || upper.hasPrefix("PAYMENT_INBOUND") || upper.hasPrefix("INCOMING_TRANSFER") {
                self = .paymentInbound
            } else if upper == "BANK_TRANSACTION_OUTGOING" || upper.hasPrefix("PAYMENT_OUTBOUND") || upper.hasPrefix("OUTGOING_TRANSFER") {
                self = .paymentOutbound
            } else if upper.hasPrefix("SSP_CORPORATE_ACTION") {
                self = .corporateAction
            } else if upper.hasPrefix("INTEREST_PAYOUT") {
                self = .interest
            } else if upper == "ORDER_EXECUTED" || upper == "TRADE_INVOICE" || upper.hasPrefix("SAVINGS_PLAN") || upper.hasPrefix("TRADING_") {
                self = .trade
            } else {
                self = .unknown(raw)
            }
        }
    }

    /// Transfers carry IBAN and reference only in `timelineDetailV2`.
    var needsDetail: Bool {
        switch self {
        case .paymentInbound, .paymentOutbound, .directDebit: true
        default: false
        }
    }
}

/// Pure mapping from Trade Republic JSON to MFN models. No network, fully unit-tested.
enum TRMapping {
    // MARK: - Timeline (REST `GET /api/v2/timeline/transactions`, verified against fixtures)

    struct TimelinePage: Sendable {
        var items: [JSONValue]
        var after: String?
    }

    static func timelinePage(_ json: JSONValue) throws(ConnectorError) -> TimelinePage {
        guard let items = json["items"]?.array else {
            throw .formatChanged(detail: "timelineTransactions ohne items")
        }
        return TimelinePage(items: items, after: json["cursors"]?["after"]?.string)
    }

    static func itemID(_ item: JSONValue) -> String? { item["id"]?.string }

    static func itemDay(_ item: JSONValue) -> BankDay? {
        item["timestamp"]?.string.flatMap(day(fromTimestamp:))
    }

    static func eventType(_ item: JSONValue) -> TREventType { TREventType(item["eventType"]?.string) }

    /// Maps one timeline item. `nil` for items without money movement (documents, notices).
    static func transaction(item: JSONValue, detail: JSONValue?, account: AccountID) throws(ConnectorError) -> Transaction? {
        guard item.object != nil else { throw .formatChanged(detail: "Timeline-Eintrag ist kein Objekt") }
        guard let id = itemID(item) else { throw .formatChanged(detail: "Timeline-Eintrag ohne id") }
        guard let day = itemDay(item) else { throw .formatChanged(detail: "Timeline-Eintrag ohne lesbaren timestamp") }
        guard let amountJSON = item["amount"], !amountJSON.isNull else { return nil }
        guard let amount = money(amountJSON) else { throw .formatChanged(detail: "Timeline-Betrag nicht lesbar") }

        let status = status(of: item)
        var original: (cents: Int, currency: String)?
        if let sub = item["subAmount"], let money = money(sub), money.currency != amount.currency {
            original = (money.cents, money.currency)
        }

        let fields = detail.map(detailFields) ?? [:]
        let type = eventType(item)
        let title = item["title"]?.string ?? ""
        let subtitle = item["subtitle"]?.string
        let purpose = fields[.purpose] ?? subtitle ?? purposeFallback(type)

        let raw: JSONValue = detail.map { .object(["timeline": item, "detail": $0]) } ?? item
        let booked = status == .booked
        return Transaction(
            accountID: account,
            bookingDate: booked ? day : nil,
            valueDate: day,
            amountCents: amount.cents,
            currency: amount.currency,
            counterpartName: title,
            counterpartIBAN: fields[.iban].map(Fingerprint.normalize(iban:)),
            purpose: purpose,
            eref: fields[.eref],
            mref: fields[.mref],
            creditorID: fields[.creditorID],
            status: status,
            externalID: id,
            originalAmountCents: original?.cents,
            originalCurrency: original?.currency,
            rawJSON: raw.data
        )
    }

    static func status(of item: JSONValue) -> TransactionStatus {
        if item["deleted"]?.bool == true { return .cancelled }
        if case .cardFailed = eventType(item) { return .cancelled }
        switch item["status"]?.string?.uppercased() {
        case "PENDING", "CREATED", "PROCESSING": return .pending
        case "CANCELED", "CANCELLED", "FAILED", "REJECTED": return .cancelled
        default: return .booked // EXECUTED and unknown states: the item is on the timeline
        }
    }

    static func purposeFallback(_ type: TREventType) -> String {
        switch type {
        case .cardTransaction: "Kartenzahlung"
        case .cardRefund: "Kartengutschrift"
        case .cardFailed: "Kartenzahlung abgelehnt"
        case .cardATMWithdrawal: "Bargeldauszahlung"
        case .paymentInbound: "Eingang"
        case .paymentOutbound: "Überweisung"
        case .directDebit: "Lastschrift"
        case .interest: "Zinsen"
        case .trade: "Wertpapiergeschäft"
        case .corporateAction: "Ausschüttung"
        case let .unknown(raw): raw
        }
    }

    // MARK: - Detail (WebSocket `timelineDetailV2`, unverified: not in the HAR)

    enum DetailField: Hashable { case iban, purpose, eref, mref, creditorID }

    /// Collects `{"title": …, "detail": {"text": …}}` rows anywhere in the detail sections.
    static func detailFields(_ detail: JSONValue) -> [DetailField: String] {
        var result: [DetailField: String] = [:]
        func visit(_ value: JSONValue) {
            switch value {
            case let .object(object):
                if let title = object["title"]?.string, let text = object["detail"]?["text"]?.string ?? object["detail"]?.string,
                   let field = field(forTitle: title), result[field] == nil {
                    result[field] = text
                }
                for (_, child) in object.sorted(by: { $0.key < $1.key }) { visit(child) }
            case let .array(array):
                array.forEach(visit)
            default:
                break
            }
        }
        visit(detail)
        return result
    }

    static func field(forTitle title: String) -> DetailField? {
        let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter }
        switch key {
        case "iban": return .iban
        case "verwendungszweck", "referenz", "zahlungsreferenz", "nachricht", "reference", "purpose": return .purpose
        case "endtoendreferenz", "endtoendid", "endtoendreference": return .eref
        case "mandatsreferenz", "mandatereference": return .mref
        case "glaubigerid", "glaeubigerid", "creditorid": return .creditorID
        default: return nil
        }
    }

    // MARK: - Accounts (REST, verified against fixtures)

    struct CashAccount: Sendable, Equatable {
        var accountID: String?
        var iban: String?
    }

    /// `GET /api/v1/account-manager/accounts/switchable`: profiles the login can switch between.
    /// Prefers the profile the card belongs to (`authAccountId`), then the first active one.
    static func cashAccount(_ json: JSONValue, preferredID: String?) throws(ConnectorError) -> CashAccount {
        guard let accounts = json["accounts"]?.array else {
            throw .formatChanged(detail: "accounts/switchable ohne accounts")
        }
        let active = accounts.filter { ($0["status"]?.string ?? "ACTIVE").uppercased() == "ACTIVE" }
        guard let account = active.first(where: { preferredID != nil && $0["accountId"]?.string == preferredID }) ?? active.first else {
            throw .unsupportedAccount
        }
        let iban = account["bankingInfo"]?["iban"]?.string.map(Fingerprint.normalize(iban:))
        return CashAccount(accountID: account["accountId"]?.string, iban: iban)
    }

    struct Card: Sendable, Equatable {
        var last4: String?
        var authAccountID: String?
    }

    /// `GET /api/v1/card/cards/home`: `data.card.lastFourPan`, `data.cardholder.authAccountId`.
    static func card(_ json: JSONValue) -> Card {
        let data = json["data"] ?? json
        let last4 = data["card"]?["lastFourPan"]?.string.flatMap { $0.count == 4 && $0.allSatisfy(\.isNumber) ? $0 : nil }
        return Card(last4: last4, authAccountID: data["cardholder"]?["authAccountId"]?.string ?? data["card"]?["authAccountId"]?.string)
    }

    // MARK: - Cash (WebSocket `cash`, unverified: pytr format, not in the HAR)

    struct Cash: Sendable, Equatable {
        var accountNumber: String?
        var currency: String
        var cents: Int
    }

    /// `cash`: `[{"accountNumber": …, "currencyId": "EUR", "amount": 123.45}]`.
    static func cash(_ json: JSONValue) throws(ConnectorError) -> Cash {
        let entries = json.array ?? (json.object != nil ? [json] : [])
        let entry = entries.first { $0["currencyId"]?.string == "EUR" } ?? entries.first
        guard let entry, let amount = entry["amount"]?.decimal else {
            throw .formatChanged(detail: "cash ohne Betrag")
        }
        let currency = entry["currencyId"]?.string ?? "EUR"
        guard let cents = Money.minorUnits(amount, fractionDigits: 2) else {
            throw .formatChanged(detail: "cash-Betrag nicht lesbar")
        }
        return Cash(accountNumber: entry["accountNumber"]?.string, currency: currency, cents: cents)
    }

    // MARK: - Portfolio

    struct Position: Sendable, Equatable {
        var isin: String
        var quantity: Decimal
        /// `averageBuyIn`: average purchase price per unit in EUR, nil if missing or implausible.
        var averageBuyIn: Decimal? = nil
    }

    /// Upper bound for a purchase price per unit; anything above is a broken value.
    static let maxBuyIn = Decimal(1_000_000_000)

    /// Unverified (WebSocket, not in the HAR). `compactPortfolio`: `{"positions": [{"instrumentId", "netSize"}]}`, newer variants group
    /// positions under `categories[].positions`.
    /// `accountPairs`: `{"accounts": [{"productType": "DEFAULT", "securitiesAccountNumber", "cashAccountNumber", "currency"}]}`
    /// (web bundle, 2026-11-10). The web app uses the `DEFAULT` account (not `TAX_WRAPPER`).
    static func securitiesAccountNumber(_ json: JSONValue) throws(ConnectorError) -> String {
        let accounts = json["accounts"]?.array ?? []
        let preferred = accounts.first { $0["productType"]?.string == "DEFAULT" } ?? accounts.first
        guard let number = preferred?["securitiesAccountNumber"]?.string, !number.isEmpty else {
            throw .formatChanged(detail: "accountPairs ohne securitiesAccountNumber")
        }
        return number
    }

    static func positions(_ json: JSONValue) throws(ConnectorError) -> [Position] {
        var raw = json["positions"]?.array ?? []
        for category in json["categories"]?.array ?? [] {
            raw += category["positions"]?.array ?? []
        }
        if raw.isEmpty, json["positions"] == nil, json["categories"] == nil {
            throw .formatChanged(detail: "compactPortfolioByTypeV2 ohne positions")
        }
        return raw.compactMap { entry in
            guard let isin = entry["instrumentId"]?.string ?? entry["isin"]?.string,
                  let quantity = (entry["netSize"] ?? entry["size"])?.decimal, quantity != 0,
                  isValidISIN(isin) else { return nil }
            let buyIn = entry["averageBuyIn"]?.decimal.flatMap { $0 > 0 && $0 < maxBuyIn ? $0 : nil }
            return Position(isin: isin, quantity: quantity, averageBuyIn: buyIn)
        }
    }

    struct Instrument: Sendable, Equatable {
        var name: String
        var exchange: String
    }

    static func instrument(_ json: JSONValue, isin: String) -> Instrument {
        let name = json["shortName"]?.string ?? json["name"]?.string ?? isin
        let exchanges = json["exchangeIds"]?.array?.compactMap(\.string) ?? []
        let exchange = exchanges.contains("LSX") ? "LSX" : (exchanges.first ?? "LSX")
        return Instrument(name: name, exchange: exchange)
    }

    /// `ticker`: `{"last": {"price": 12.34}, "bid": {...}}` – last, else bid.
    static func priceCents(_ json: JSONValue) throws(ConnectorError) -> Int {
        guard let cents = Money.minorUnits(try price(json), fractionDigits: 2) else {
            throw .formatChanged(detail: "ticker ohne Kurs")
        }
        return cents
    }

    /// Exact `ticker` price in EUR (may be below one cent, e.g. delisted penny stocks).
    static func price(_ json: JSONValue) throws(ConnectorError) -> Decimal {
        guard let price = json["last"]?["price"]?.decimal ?? json["bid"]?["price"]?.decimal else {
            throw .formatChanged(detail: "ticker ohne Kurs")
        }
        return price
    }

    static func isValidISIN(_ isin: String) -> Bool {
        isin.count == 12 && isin.prefix(2).allSatisfy { $0.isASCII && $0.isUppercase }
            && isin.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    // MARK: - Primitives

    /// `{"value": -12.34, "currency": "EUR", "fractionDigits": 2}`.
    static func money(_ json: JSONValue) -> (cents: Int, currency: String)? {
        guard let value = json["value"]?.decimal else { return nil }
        let currency = json["currency"]?.string ?? "EUR"
        guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        let digits = json["fractionDigits"]?.int ?? 2
        guard let cents = Money.minorUnits(value, fractionDigits: digits) else { return nil }
        return (cents, currency)
    }

    /// `2025-03-14T09:12:33.123+0000` (also `Z`, `+00:00`, without fraction, or a plain date) → bank day in Berlin.
    static func day(fromTimestamp raw: String) -> BankDay? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let match = text.wholeMatch(of: /(.*T.*[+-]\d\d)(\d\d)/) {
            text = "\(match.1):\(match.2)"
        }
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let date = try? style.parse(text) { return BankDay(date) }
        }
        return BankDay(iso: String(text.prefix(10)))
    }
}
