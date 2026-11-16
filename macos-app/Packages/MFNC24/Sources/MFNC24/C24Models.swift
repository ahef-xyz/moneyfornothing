import Foundation
import MFNCore

// Decodable models for the C24 API, shaped after `Fixtures/C24/*.json` (snake_case, decoded with
// `.convertFromSnakeCase`). Tolerant (CLAUDE.md §6): unknown fields are ignored, everything not
// needed for an MFN model is optional, types/states are kept as raw strings and mapped with an
// `unknown` fallback.

enum C24JSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// `formatChanged` with the coding path, never with values (CLAUDE.md §6 redaction).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws(ConnectorError) -> T {
        do {
            return try decoder().decode(type, from: data)
        } catch let DecodingError.keyNotFound(key, info) {
            throw .formatChanged(detail: "C24 \(context): Feld fehlt \(path(info.codingPath + [key]))")
        } catch let DecodingError.typeMismatch(_, info) {
            throw .formatChanged(detail: "C24 \(context): Typ geändert bei \(path(info.codingPath))")
        } catch let DecodingError.valueNotFound(_, info) {
            throw .formatChanged(detail: "C24 \(context): Wert fehlt bei \(path(info.codingPath))")
        } catch let DecodingError.dataCorrupted(info) {
            throw .formatChanged(detail: "C24 \(context): Wert unlesbar bei \(path(info.codingPath))")
        } catch {
            throw .formatChanged(detail: "C24 \(context): kein gültiges JSON")
        }
    }

    static func path(_ keys: [any CodingKey]) -> String {
        keys.isEmpty ? "(Wurzel)" : keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

// MARK: - Scalars

/// IDs arrive as strings (`"96761ceb7"`) or numbers (`6187484`).
struct C24Identifier: Decodable, Hashable, Sendable {
    let value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int64.self))
        }
    }
}

/// Money in cents. C24 sends decimal strings with a dot (`"-1222.01"`, `"0"`); German notation
/// (`"7,09 €"`, detail texts) and plain JSON numbers are accepted too. Never goes through `Double`.
struct C24Amount: Decodable, Hashable, Sendable {
    let cents: Int

    init(cents: Int) {
        self.cents = cents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard let cents = Self.cents(fromText: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Betrag nicht lesbar")
            }
            self.cents = cents
        } else {
            cents = Self.cents(from: try container.decode(Decimal.self))
        }
    }

    static func cents(from euros: Decimal) -> Int {
        var scaled = euros * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// No comma, and every dot is followed by a group of exactly three digits.
    static func dotsAreThousandsSeparators(_ body: String) -> Bool {
        let groups = body.split(separator: ".", omittingEmptySubsequences: false)
        return groups.count > 1 && groups.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }

    /// `"-1222.01"`, `"1.234,56 €"`, `"7,09 €"`, `"−0,99"`, `"1.234 €"` (dot = thousands).
    static func cents(fromText text: String) -> Int? {
        var body = text.replacingOccurrences(of: "−", with: "-")
            .filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
        guard !body.isEmpty else { return nil }
        switch (body.lastIndex(of: ","), body.lastIndex(of: ".")) {
        case let (comma?, dot?):
            body = comma > dot
                ? body.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                : body.replacingOccurrences(of: ",", with: "")
        case (_?, nil):
            body = body.replacingOccurrences(of: ",", with: ".")
        case (nil, _?) where Self.dotsAreThousandsSeparators(body):
            // German grouping without decimals: "1.234 €", "1.234.567" (a decimal point would
            // have one or two digits after it, as in "-1222.01").
            body = body.replacingOccurrences(of: ".", with: "")
        default:
            break
        }
        guard body.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: body, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return cents(from: value)
    }
}

enum C24Day {
    /// `yyyy-MM-dd`, `dd.MM.yyyy` (optionally followed by a time, e.g. `"02.11.2026 05:36 Uhr"`)
    /// or ISO-8601 with offset (`"2026-11-09T09:13:47+01:00"`, converted to the Berlin calendar day).
    static func parse(_ string: String) -> BankDay? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let tIndex = trimmed.firstIndex(of: "T") {
            let time = trimmed[trimmed.index(after: tIndex)...]
            guard time.hasSuffix("Z") || time.contains("+") || time.contains("-") else {
                return BankDay(iso: String(trimmed[..<tIndex]))
            }
            for style in [Date.ISO8601FormatStyle(), Date.ISO8601FormatStyle(includingFractionalSeconds: true)] {
                if let date = try? Date(trimmed, strategy: style) { return BankDay(date) }
            }
            return nil
        }
        let datePart = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if datePart.contains(".") {
            let parts = datePart.split(separator: ".")
            guard parts.count == 3, let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2]) else { return nil }
            return BankDay(year: y, month: m, day: d)
        }
        return BankDay(iso: datePart)
    }
}

// MARK: - Accounts (`GET /api/user/me/accounts/internal/`, `GET /api/v3/pockets/`)

struct C24AccountsResponse: Decodable, Sendable {
    let accounts: [C24Account]
    let pockets: [C24Pocket]?
}

struct C24PocketsResponse: Decodable, Sendable {
    let pockets: [C24Pocket]
}

struct C24Personalization: Decodable, Sendable {
    let name: String?
}

struct C24Account: Decodable, Sendable {
    let accountNumber: String
    let name: String?
    let iban: String?
    let accountType: String?
    let accountplanName: String?
    let state: String?
    let totalBalance: C24Amount?
    let availableBalance: C24Amount?
    let personalization: C24Personalization?
}

struct C24Pocket: Decodable, Sendable {
    let pocketNumber: String
    let parentAccountNumber: String?
    let productType: String?
    let iban: String?
    let state: String?
    let dateOfClosure: String?
    let totalBalance: C24Amount?
    let availableBalance: C24Amount?
    let customDetails: C24Personalization?
    let personalization: C24Personalization?
}

enum C24AccountKind: Hashable, Sendable {
    case giro
    case pocketPlus
    case pocket
    case unknown(String)

    init(accountType: String?) {
        switch accountType?.uppercased() {
        case "CURRENT_ACCOUNT", "CURRENT_ACCOUNT_JOINT": self = .giro
        default: self = .unknown(accountType ?? "")
        }
    }

    init(productType: String?) {
        switch productType?.lowercased() {
        case "pocket_plus": self = .pocketPlus
        case "pocket", "joint_pocket", "shared_pocket": self = .pocket
        default: self = .unknown(productType ?? "")
        }
    }
}

/// Accounts/pockets in these states are no longer shown.
let c24ClosedStates: Set<String> = ["closed", "terminated", "cancelled", "deleted"]

// MARK: - Transactions (`POST /api/v3/transactions/search/`)

/// Body exactly as the web app sends it (`Fixtures/C24/endpoints.md`): only `criteria.account_numbers`
/// and `pagination`. The other `criteria` fields (`search_type`, `include_auth_holds`, …) appear only
/// in the server's answer as its defaults; sending guessed values made the server answer HTTP 500
/// (first real sync, 2026-11-10).
struct C24SearchRequest: Encodable, Sendable {
    struct Criteria: Encodable, Sendable {
        let accountNumbers: [String]

        enum CodingKeys: String, CodingKey {
            case accountNumbers = "account_numbers"
        }
    }

    struct Pagination: Encodable, Sendable {
        let limit: Int
        let offset: Int
    }

    let criteria: Criteria
    let pagination: Pagination
}

struct C24Pagination: Decodable, Sendable {
    let limit: Int?
    let offset: Int?
    let more: Bool?
}

/// Only the paging part of a search answer; transactions are decoded one by one (own `rawJSON`).
struct C24SearchEnvelope: Decodable, Sendable {
    let pagination: C24Pagination?
}

/// One entry of the `data` detail list: `{ "title": "Verwendungszweck", "content": "…" }`.
struct C24Detail: Decodable, Sendable {
    let title: String
    let content: String?
}

struct C24Transaction: Decodable, Sendable {
    let id: C24Identifier?
    let type: String?
    let preliminary: Bool?
    let amount: C24Amount
    let date: String
    let sortDate: String?
    let accountNumber: String?
    let counterpart: String?
    /// Spelled `ent_to_end_id` by C24; `end_to_end_id` accepted in case they fix it.
    let entToEndId: String?
    let endToEndId: String?
    let data: [C24Detail]?

    /// First non-empty detail with one of these titles (case-insensitive).
    func detail(_ titles: String...) -> String? {
        let wanted = Set(titles.map { $0.lowercased() })
        return data?.lazy
            .filter { wanted.contains($0.title.lowercased()) }
            .compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

/// One page of the search, each transaction with its own raw JSON for `Transaction.rawJSON`.
struct C24SearchPage {
    struct Item {
        var value: C24Transaction
        var raw: Data
    }

    var items: [Item] = []
    var pagination: C24Pagination?

    init(data: Data) throws(ConnectorError) {
        pagination = try C24JSON.decode(C24SearchEnvelope.self, from: data, context: "Umsätze").pagination
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .formatChanged(detail: "C24 Umsätze: kein gültiges JSON")
        }
        guard let list = (root as? [String: Any])?["transactions"] as? [Any] else {
            throw .formatChanged(detail: "C24 Umsätze: Feld fehlt transactions")
        }
        for (index, element) in list.enumerated() {
            guard JSONSerialization.isValidJSONObject(element),
                  let raw = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .withoutEscapingSlashes])
            else {
                throw .formatChanged(detail: "C24 Umsätze: transactions.[\(index)] ist kein Objekt")
            }
            let value = try C24JSON.decode(C24Transaction.self, from: raw, context: "Umsätze transactions.[\(index)]")
            items.append(Item(value: value, raw: raw))
        }
    }
}

// MARK: - Upcoming (`GET /api/v2/upcoming-transactions/?future_days=…`)

struct C24Upcoming: Decodable, Sendable {
    let standingOrders: [C24StandingOrder]?
    let directDebits: [C24DirectDebit]?
}

struct C24StandingOrder: Decodable, Sendable {
    let id: C24Identifier
    let accountNumber: String?
    let recipient: String?
    let iban: String?
    let subject: String?
    let amount: C24Amount
    let nextExecution: String?
}

struct C24DirectDebit: Decodable, Sendable {
    let debtorIban: String?
    let creditorId: String?
    let creditorName: String?
    let creditorIban: String?
    let amount: C24Amount
    let status: String?
    let purpose: String?
    let mandateReference: String?
    let requestedCollectionDate: String?
    let settlementDate: String?
    let paymentorderid: String?
}

extension String {
    /// IBAN without spaces, upper-cased; `nil` when empty.
    var normalizedIBAN: String? {
        let value = filter { !$0.isWhitespace }.uppercased()
        return value.isEmpty ? nil : value
    }
}
