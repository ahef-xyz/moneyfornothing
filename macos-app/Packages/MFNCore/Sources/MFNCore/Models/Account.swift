import Foundation

public enum AccountType: String, Codable, Sendable, CaseIterable, Hashable {
    case giro
    case tagesgeld
    case depot
    case card
}

/// One bank login. A connection owns one or more accounts.
public struct Connection: Identifiable, Hashable, Codable, Sendable {
    public let id: ConnectionID
    public var connectorID: ConnectorID
    public var displayName: String

    public init(id: ConnectionID, connectorID: ConnectorID, displayName: String) {
        self.id = id
        self.connectorID = connectorID
        self.displayName = displayName
    }
}

public struct Account: Identifiable, Hashable, Codable, Sendable {
    public let id: AccountID
    public let connectionID: ConnectionID
    public var iban: String?
    public var type: AccountType
    /// ISO 4217 code, e.g. `EUR`.
    public var currency: String
    public var name: String
    public var cardLast4: String?
    public var creditLimitCents: Int?

    public init(
        id: AccountID,
        connectionID: ConnectionID,
        iban: String? = nil,
        type: AccountType,
        currency: String = "EUR",
        name: String,
        cardLast4: String? = nil,
        creditLimitCents: Int? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.iban = iban
        self.type = type
        self.currency = currency
        self.name = name
        self.cardLast4 = cardLast4
        self.creditLimitCents = creditLimitCents
    }
}

public struct Balance: Hashable, Codable, Sendable {
    public var bookedCents: Int
    public var availableCents: Int?
    public var currency: String
    public var asOf: Date

    public init(bookedCents: Int, availableCents: Int? = nil, currency: String = "EUR", asOf: Date) {
        self.bookedCents = bookedCents
        self.availableCents = availableCents
        self.currency = currency
        self.asOf = asOf
    }
}

public struct CardStatement: Hashable, Codable, Sendable {
    public let accountID: AccountID
    public var periodStart: BankDay
    public var periodEnd: BankDay
    public var dueDate: BankDay?
    /// Statement total; negative means the card holder owes the bank.
    public var amountCents: Int
    public var currency: String
    public var pdfBlobID: String?

    public init(
        accountID: AccountID,
        periodStart: BankDay,
        periodEnd: BankDay,
        dueDate: BankDay?,
        amountCents: Int,
        currency: String = "EUR",
        pdfBlobID: String? = nil
    ) {
        self.accountID = accountID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.dueDate = dueDate
        self.amountCents = amountCents
        self.currency = currency
        self.pdfBlobID = pdfBlobID
    }

    public func contains(_ day: BankDay) -> Bool {
        day >= periodStart && day <= periodEnd
    }
}

public struct SecurityPosition: Hashable, Codable, Sendable {
    public let accountID: AccountID
    public var isin: String
    public var name: String
    /// Number of units. `Decimal` because fractional shares (Trade Republic savings plans) are common.
    public var quantity: Decimal
    /// Price per unit in cents of `currency`.
    public var priceCents: Int
    public var currency: String
    public var asOf: Date
    /// Average purchase price per unit in cents of `currency` (v9), nil if the bank sends none.
    /// Same unit as `priceCents` (bonds: per 100 face value).
    public var purchasePriceCents: Int?

    public init(
        accountID: AccountID,
        isin: String,
        name: String,
        quantity: Decimal,
        priceCents: Int,
        currency: String = "EUR",
        asOf: Date,
        purchasePriceCents: Int? = nil
    ) {
        self.accountID = accountID
        self.isin = isin
        self.name = name
        self.quantity = quantity
        self.priceCents = priceCents
        self.currency = currency
        self.asOf = asOf
        self.purchasePriceCents = purchasePriceCents
    }

    /// Market value in cents, rounded half-even to whole cents.
    public var valueCents: Int { Self.cents(quantity, times: priceCents) }

    /// What the position cost: quantity × purchase price, nil without a purchase price.
    public var purchaseValueCents: Int? { purchasePriceCents.map { Self.cents(quantity, times: $0) } }

    /// Gain (positive) or loss (negative) against the purchase value.
    public var gainCents: Int? { purchaseValueCents.map { valueCents - $0 } }

    /// Gain relative to the purchase value (0.1 = +10 %), nil without a purchase value.
    public var gainRatio: Double? {
        guard let purchase = purchaseValueCents, purchase > 0, let gain = gainCents else { return nil }
        return Double(gain) / Double(purchase)
    }

    private static func cents(_ quantity: Decimal, times price: Int) -> Int {
        var product = quantity * Decimal(price)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .bankers)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
