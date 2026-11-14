import Foundation
import MFNCore

/// One holding from a SWIFT MT535 statement of holdings (FinTS `HIWPD`).
public struct MT535Holding: Sendable, Equatable {
    public var isin: String?
    /// WKN or other national identifier (`/DE/514000`).
    public var nationalID: String?
    public var name: String
    /// Units (`UNIT`) or face amount (`FAMT`, bonds).
    public var quantity: Decimal
    public var quantityIsFaceAmount: Bool
    /// Price per unit, or percent of face value if `priceIsPercentage`.
    public var price: Decimal?
    public var priceIsPercentage: Bool
    public var priceCurrency: String?
    public var priceDate: BankDay?
    /// `:19A::HOLD//` market value of the holding.
    public var holdingValueCents: Int?
    public var holdingCurrency: String?
    /// `:70E::HOLD//` average purchase price per unit (percent of face value for `FAMT`).
    public var purchasePrice: Decimal?
    public var purchaseCurrency: String?
}

public struct MT535Statement: Sendable, Equatable {
    /// `:98A::STAT//` / `:98C::STAT//` statement date.
    public var statementDate: BankDay?
    public var holdings: [MT535Holding]
    /// `:19A::HOLP//` total value of the depot, if given.
    public var totalValueCents: Int?
    public var totalCurrency: String?
}

/// SWIFT MT535 parser (blocks `:16R:GENL`, `:16R:FIN` …, qualifiers `:90B::MRKT//ACTU/EUR12,34`).
public enum MT535Parser {
    public static func parse(_ data: Data) throws(MT940Error) -> MT535Statement {
        try parse(MT940Text.decode(data))
    }

    public static func parse(_ text: String) throws(MT940Error) -> MT535Statement {
        var statement = MT535Statement(statementDate: nil, holdings: [], totalValueCents: nil, totalCurrency: nil)
        var blocks: [String] = []
        var holding: Holding?

        for field in MT940Text.fields(text) {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.tag {
            case "16R":
                blocks.append(value)
                if value == "FIN" { holding = Holding() }
            case "16S":
                if value == "FIN", let finished = holding {
                    statement.holdings.append(try finished.build())
                    holding = nil
                }
                if let index = blocks.lastIndex(of: value) { blocks.remove(at: index) }
            case "98A", "98C":
                guard let (qualifier, content) = qualified(value) else { break }
                let day = MT940Text.day(yyyymmdd: String(content.prefix(8)))
                if qualifier == "STAT", blocks.contains("GENL") { statement.statementDate = day }
                if qualifier == "PRIC", holding != nil { holding?.priceDate = day }
            case "19A":
                guard let (qualifier, content) = qualified(value), let (currency, cents) = money(content) else { break }
                if holding != nil, qualifier == "HOLD", blocks.last == "FIN" {
                    holding?.holdingValueCents = cents
                    holding?.holdingCurrency = currency
                } else if holding == nil, qualifier == "HOLP" {
                    statement.totalValueCents = cents
                    statement.totalCurrency = currency
                }
            case "35B" where holding != nil:
                holding?.identification(field.value)
            case "90A", "90B":
                guard holding != nil, let (qualifier, content) = qualified(value), qualifier == "MRKT" || holding?.price == nil else { break }
                // ACTU/EUR38,82 (amount) or PRCT/101,5 (percent of face value).
                let parts = content.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { break }
                if parts[0] == "PRCT" {
                    holding?.price = MT940Text.decimal(parts[1])
                    holding?.priceIsPercentage = true
                    holding?.priceCurrency = nil
                } else {
                    let amount = parts[1]
                    let hasCurrency = amount.prefix(3).allSatisfy(\.isLetter)
                    holding?.priceCurrency = hasCurrency ? String(amount.prefix(3)) : nil
                    holding?.price = MT940Text.decimal(hasCurrency ? String(amount.dropFirst(3)) : amount)
                    holding?.priceIsPercentage = false
                }
            case "70E" where holding != nil:
                guard blocks.last == "FIN", let (qualifier, content) = qualified(value), qualifier == "HOLD",
                      let (price, currency) = purchasePrice(content) else { break }
                holding?.purchasePrice = price
                holding?.purchaseCurrency = currency
            case "93B" where holding != nil:
                // Only the aggregate balance of the main block, not SUBBAL details.
                guard blocks.last == "FIN", let (qualifier, content) = qualified(value), qualifier == "AGGR" else { break }
                let parts = content.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw MT940Error("Bestand :93B: nicht lesbar") }
                var amount = parts[1]
                let negative = amount.hasPrefix("N")
                if negative { amount.removeFirst() }
                guard let quantity = MT940Text.decimal(amount) else { throw MT940Error("Stückzahl :93B: nicht lesbar") }
                holding?.quantity = negative ? -quantity : quantity
                holding?.quantityIsFaceAmount = parts[0] == "FAMT"
            default:
                break
            }
        }
        return statement
    }

    /// Upper bound for a purchase price per unit (or percent); anything above is a broken value.
    static let maxPurchasePrice = Decimal(1_000_000_000)

    /// `:70E::HOLD//` per DK spec: line `1` + unit type (`STK`, `FAMT`), line `2` + average purchase
    /// price + `+` + currency, e.g. `1STK⏎2123,456789+EUR`. Percent of face value for `FAMT`.
    static func purchasePrice(_ content: String) -> (price: Decimal, currency: String?)? {
        let lines = content.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: { $0.hasPrefix("2") }) else { return nil }
        let parts = line.dropFirst().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // Bounded: a broken value must not overflow into cents and look like a real price.
        guard let first = parts.first, let price = MT940Text.decimal(first), price > 0, price < maxPurchasePrice else { return nil }
        let currency = parts.count > 1 && parts[1].count == 3 && parts[1].allSatisfy(\.isLetter) ? parts[1] : nil
        return (price, currency)
    }

    /// `:QUAL//content` → (QUAL, content). Also accepts a data source scheme `:QUAL/SCHEME/content`.
    static func qualified(_ value: String) -> (String, String)? {
        guard value.hasPrefix(":") else { return nil }
        let body = value.dropFirst()
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let qualifier = String(body[..<slash])
        var rest = body[body.index(after: slash)...]
        if let next = rest.firstIndex(of: "/") { rest = rest[rest.index(after: next)...] }
        return (qualifier, String(rest))
    }

    /// `EUR1234,56` or `NEUR1234,56` (negative) → (currency, signed cents).
    static func money(_ content: String) -> (String, Int)? {
        var text = Substring(content)
        let negative = text.hasPrefix("N") && text.dropFirst().prefix(3).allSatisfy(\.isLetter) && text.count > 4
        if negative { text = text.dropFirst() }
        let currency = String(text.prefix(3))
        guard currency.count == 3, currency.allSatisfy(\.isLetter), let cents = MT940Text.cents(String(text.dropFirst(3))) else { return nil }
        return (currency, negative ? -cents : cents)
    }

    private struct Holding {
        var isin: String?
        var nationalID: String?
        var nameLines: [String] = []
        var quantity: Decimal?
        var quantityIsFaceAmount = false
        var price: Decimal?
        var priceIsPercentage = false
        var priceCurrency: String?
        var priceDate: BankDay?
        var holdingValueCents: Int?
        var holdingCurrency: String?
        var purchasePrice: Decimal?
        var purchaseCurrency: String?

        /// `ISIN DE0005140008/DE/514000` then name lines; `ISIN …` and `/DE/514000` on separate lines (ING); or only `/DE/514000`.
        mutating func identification(_ raw: String) {
            let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard var first = lines.first else { return }
            if first.hasPrefix("ISIN ") {
                first.removeFirst(5)
                let parts = first.split(separator: "/", omittingEmptySubsequences: false)
                isin = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count >= 3 { nationalID = String(parts[2]) }
                var rest = Array(lines.dropFirst())
                // ING: the national ID on its own line (`ISIN XS…⏎/DE/ABC123⏎NAME`).
                if let line = rest.first, line.hasPrefix("/") {
                    let id = line.split(separator: "/")
                    if nationalID == nil, id.count >= 2 { nationalID = String(id[1]) }
                    rest.removeFirst()
                }
                nameLines = rest
            } else if first.hasPrefix("/") {
                let parts = first.split(separator: "/")
                if parts.count >= 2 { nationalID = String(parts[1]) }
                nameLines = Array(lines.dropFirst())
            } else {
                nameLines = lines
            }
        }

        func build() throws(MT940Error) -> MT535Holding {
            guard let quantity else { throw MT940Error("Position ohne Bestand :93B:") }
            return MT535Holding(
                isin: isin.flatMap { $0.isEmpty ? nil : $0 },
                nationalID: nationalID,
                name: nameLines.filter { !$0.isEmpty }.joined(separator: " "),
                quantity: quantity,
                quantityIsFaceAmount: quantityIsFaceAmount,
                price: price,
                priceIsPercentage: priceIsPercentage,
                priceCurrency: priceCurrency,
                priceDate: priceDate,
                holdingValueCents: holdingValueCents,
                holdingCurrency: holdingCurrency,
                purchasePrice: purchasePrice,
                purchaseCurrency: purchaseCurrency
            )
        }
    }
}
