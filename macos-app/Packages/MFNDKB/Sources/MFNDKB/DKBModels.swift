import Foundation
import MFNCore

// Tolerant models of the DKB web-banking JSON:API answers (`Fixtures/DKB/web`). Unknown fields are ignored,
// everything not needed for the mapping is optional, enums keep unknown values.

/// `{"currencyCode": "EUR", "value": "123.45"}` – the value is a decimal string, never a JSON number.
struct DKBMoney: Decodable, Sendable, Equatable {
    var currencyCode: String?
    var value: String

    init(currencyCode: String?, value: String) {
        self.currencyCode = currencyCode
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode)
        // Tolerate a JSON number as well, via its exact textual form (Decimal, never Double).
        if let text = try? container.decode(String.self, forKey: .value) {
            value = text
        } else {
            value = try container.decode(Decimal.self, forKey: .value).description
        }
    }

    enum CodingKeys: String, CodingKey { case currencyCode, value }
}

// MARK: - Accounts

struct DKBAccountList: Decodable, Sendable {
    var data: [DKBAccountResource]
}

struct DKBAccountDocument: Decodable, Sendable {
    var data: DKBAccountResource
}

struct DKBAccountResource: Decodable, Sendable {
    var id: String
    var type: String?
    var attributes: Attributes

    struct Attributes: Decodable, Sendable {
        var iban: String?
        var currencyCode: String?
        var balance: DKBMoney?
        var availableBalance: DKBMoney?
        var product: Product?
        var state: String?
        var overdraftLimit: String?
    }

    struct Product: Decodable, Sendable {
        var id: String?
        var type: DKBProductType?
        var displayName: String?
    }
}

/// `product.type` of an account. Seen: `checking-account-private`. Everything else is guessed from the name.
enum DKBProductType: Decodable, Sendable, Equatable {
    case checking
    case savings
    case unknown(String)

    init(rawValue: String) {
        let lowered = rawValue.lowercased()
        if lowered.hasPrefix("checking") || lowered.contains("giro") {
            self = .checking
        } else if lowered.contains("saving") || lowered.contains("tagesgeld") || lowered.contains("call-money") || lowered.contains("callmoney") {
            // UNVERIFIED: no savings account in the HAR; DKB "Tagesgeld" is expected to carry "savings" in its type.
            self = .savings
        } else {
            self = .unknown(rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

// MARK: - Display settings (user-named groups)

struct DKBDisplaySettingsList: Decodable, Sendable {
    var data: [Resource]

    struct Resource: Decodable, Sendable {
        var attributes: Attributes?
    }

    struct Attributes: Decodable, Sendable {
        var productGroups: [String: Group]?
    }

    struct Group: Decodable, Sendable {
        var name: String?
        var index: Int?
        var products: Products?
    }

    struct Products: Decodable, Sendable {
        var accounts: [String: Position]?
    }

    struct Position: Decodable, Sendable {
        var index: Int?
    }
}

// MARK: - Transactions

/// One page of `accountTransaction`s. `data` stays raw so every transaction keeps its own `rawJSON`.
struct DKBTransactionPage: Sendable {
    var items: [(value: DKBTransaction, raw: Data)]
    /// `meta.page.next`, or the `page[after]` parameter of `links.next`.
    var nextCursor: String?

    init(data: Data) throws(ConnectorError) {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConnectorError.formatChanged(detail: "DKB Umsätze: kein JSON-Objekt")
            }
            root = object
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw .formatChanged(detail: "DKB Umsätze: kein gültiges JSON")
        }
        guard let list = root["data"] as? [Any] else { throw .formatChanged(detail: "DKB Umsätze: Feld fehlt data") }
        var items: [(value: DKBTransaction, raw: Data)] = []
        for (index, element) in list.enumerated() {
            guard JSONSerialization.isValidJSONObject(element),
                  let raw = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .withoutEscapingSlashes])
            else { throw .formatChanged(detail: "DKB Umsätze: data[\(index)] kein Objekt") }
            let value: DKBTransaction
            do {
                value = try JSONDecoder().decode(DKBTransaction.self, from: raw)
            } catch {
                throw .formatChanged(detail: "DKB Umsätze: data[\(index)] \(DKBTransactionPage.describe(error))")
            }
            items.append((value, raw))
        }
        self.items = items

        let meta = (root["meta"] as? [String: Any])?["page"] as? [String: Any]
        if let next = meta?["next"] as? String, !next.isEmpty {
            nextCursor = next
        } else if let link = (root["links"] as? [String: Any])?["next"] as? String {
            nextCursor = Self.cursor(inLink: link)
        } else {
            nextCursor = nil
        }
    }

    /// `page[after]` of a relative link like `/accounts/<id>/transactions?page[size]=25&page[after]=<cursor>`.
    static func cursor(inLink link: String) -> String? {
        guard let query = link.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            if name == "page[after]" {
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, _): "Feld fehlt \(key.stringValue)"
        case let DecodingError.typeMismatch(_, context): "Typ geändert bei \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.valueNotFound(_, context): "Wert fehlt bei \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: "nicht lesbar"
        }
    }
}

struct DKBTransaction: Decodable, Sendable {
    var id: String
    var type: String?
    var attributes: Attributes

    struct Attributes: Decodable, Sendable {
        var status: DKBTransactionStatus?
        var bookingDate: String?
        var valueDate: String?
        var description: String?
        var transactionType: String?
        var amount: DKBMoney
        var creditor: DKBParty?
        var debtor: DKBParty?
        var endToEndId: String?
        var mandateId: String?
    }
}

/// `creditor` / `debtor`: the account object is `creditorAccount` resp. `debtorAccount`.
struct DKBParty: Decodable, Sendable {
    var name: String?
    /// Creditor identifier (Gläubiger-ID) on `creditor`.
    var id: String?
    var iban: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        let account = try container.decodeIfPresent(PartyAccount.self, forKey: .creditorAccount)
            ?? container.decodeIfPresent(PartyAccount.self, forKey: .debtorAccount)
        iban = account?.iban
    }

    struct PartyAccount: Decodable, Sendable {
        var iban: String?
    }

    enum CodingKeys: String, CodingKey { case name, id, creditorAccount, debtorAccount }
}

/// Seen: `booked`. `pending` is expected for not yet booked card payments (not in the HAR).
enum DKBTransactionStatus: Decodable, Sendable, Equatable {
    case booked
    case pending
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "booked": self = .booked
        case "pending": self = .pending // UNVERIFIED: value not in the HAR
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}
