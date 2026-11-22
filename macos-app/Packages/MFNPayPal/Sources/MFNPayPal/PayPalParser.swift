import CryptoKit
import Foundation
import MFNCore

/// PayPal's pages and list rows → MFN's models. Pure; every assumption about PayPal's markup
/// and data is in this file.
enum PayPalParser {
    static let log = Log.logger("paypal")

    // MARK: - Pages

    /// The page is the login form: the session is gone.
    static func isLoginPage(_ html: String) -> Bool {
        html.contains("login_email") || html.contains("/authflow/")
    }

    /// Content of `<script id="…" type="application/json">`.
    static func scriptJSON(id: String, in html: String) -> Data? {
        guard let open = html.range(of: "<script id=\"\(id)\""),
              let start = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else { return nil }
        return Data(html[start.upperBound..<end.lowerBound].utf8)
    }

    /// The token the activity calls need: `_csrf` in the page state, which the page keeps base64
    /// encoded in `<div id="__react_data__" data="…" data-isEncoded="yes">`.
    static func csrfToken(in html: String) -> String? {
        guard let element = html.range(of: "id=\"__react_data__\""),
              let tagStart = html.range(of: "<", options: .backwards, range: html.startIndex..<element.lowerBound),
              let tagEnd = html.range(of: ">", range: element.upperBound..<html.endIndex) else { return nil }
        let tag = String(html[tagStart.lowerBound..<tagEnd.upperBound])
        guard let raw = attribute("data", in: tag) else { return nil }
        let encoded = attribute("data-isEncoded", in: tag) == "yes"
        let json: Data? = encoded ? Data(base64Encoded: raw, options: .ignoreUnknownCharacters) : Data(unescape(raw).utf8)
        struct State: Decodable { var _csrf: String? }
        guard let json, let token = (try? JSONDecoder().decode(State.self, from: json))?._csrf, !token.isEmpty else { return nil }
        return token
    }

    /// Value of ` name="…"` in a tag.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: " \(name)=\"") else { return nil }
        guard let end = tag.range(of: "\"", range: start.upperBound..<tag.endIndex) else { return nil }
        return String(tag[start.upperBound..<end.lowerBound])
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&#34;", with: "\"").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Balances

    struct Money: Decodable, Sendable {
        var amount: String?
        var currency: String?
    }

    struct BalanceProps: Decodable, Sendable {
        struct Outer: Decodable, Sendable { var balance: Inner? }
        struct Inner: Decodable, Sendable {
            var primaryCurrency: String?
            var balances: [Entry]?
        }
        struct Entry: Decodable, Sendable {
            struct Part: Decodable, Sendable { var total: Money? }
            var id: String?
            var currency: String?
            var availableBalance: Part?
            var pendingBalance: Part?
        }
        var balance: Outer?
    }

    struct Wallet: Sendable {
        var account: Account
        var balance: Balance
    }

    /// One account per currency PayPal keeps a balance in, the primary currency first.
    static func wallets(summary html: String, connectionID: ConnectionID, now: Date) throws(ConnectorError) -> [Wallet] {
        guard let data = scriptJSON(id: "reactContainer__balance_props", in: html),
              let inner = (try? JSONDecoder().decode(BalanceProps.self, from: data))?.balance?.balance, let entries = inner.balances else {
            throw .formatChanged(detail: "summary: Guthaben nicht gefunden")
        }
        let primary = inner.primaryCurrency?.uppercased()
        var wallets: [Wallet] = []
        for entry in entries.sorted(by: { ($0.currency?.uppercased() == primary) && ($1.currency?.uppercased() != primary) }) {
            guard let currency = entry.currency?.uppercased(), currency.count == 3 else { throw .formatChanged(detail: "summary: Währung fehlt") }
            guard let available = entry.availableBalance?.total?.amount.flatMap(decimalCents) else {
                throw .formatChanged(detail: "summary: availableBalance fehlt")
            }
            guard !wallets.contains(where: { $0.account.currency == currency }) else { continue }
            // Money on its way in counts to the balance, not to what can be spent.
            let pending = entry.pendingBalance?.total?.amount.flatMap(decimalCents) ?? 0
            let account = Account(id: accountID(connection: connectionID, currency: currency), connectionID: connectionID, type: .giro,
                                  currency: currency, name: entries.count > 1 ? "PayPal \(currency)" : "PayPal")
            wallets.append(Wallet(account: account, balance: Balance(bookedCents: available + pending, availableCents: available, currency: currency, asOf: now)))
        }
        guard !wallets.isEmpty else { throw .formatChanged(detail: "summary: kein Guthaben-Konto") }
        return wallets
    }

    /// Per connection and currency. PayPal's own balance ID is not used: nothing recorded says it
    /// stays the same.
    static func accountID(connection: ConnectionID, currency: String) -> AccountID {
        let digest = SHA256.hash(data: Data("\(connection.rawValue):\(currency)".utf8))
        return AccountID("paypal-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    /// `"1234.50"` (the page's data, always with a dot) → 123450.
    static func decimalCents(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    // MARK: - Activity list

    /// One entry of `data.data.activity.transactions`: the typed part and the entry as sent.
    struct Row: Sendable {
        var detail: Detail
        var raw: Data
    }

    struct Detail: Decodable, Sendable {
        struct DateInfo: Decodable, Sendable {
            struct Raw: Decodable, Sendable { var date: String? }
            var rawDate: Raw?
        }
        struct AmountInfo: Decodable, Sendable {
            struct Contents: Decodable, Sendable { var amountText: String? }
            struct ClassNames: Decodable, Sendable { var transactionAmountClassName: String? }
            var contents: Contents?
            var classNames: ClassNames?
        }
        struct Amounts: Decodable, Sendable { var currencyCode: String? }
        struct Counterparty: Decodable, Sendable { var counterpartyName: String? }
        struct Description: Decodable, Sendable {
            struct Content: Decodable, Sendable { var transactionDescriptionText: String? }
            var content: Content?
        }
        struct Notes: Decodable, Sendable { var notes: String? }
        struct Search: Decodable, Sendable { var displayType: String? }

        var id: String?
        var type: String?
        var status: String?
        var date: DateInfo?
        var amounts: Amounts?
        var amountInfo: AmountInfo?
        var counterpartyInfo: Counterparty?
        var descriptionInfo: Description?
        var notesInfo: Notes?
        var ftsSearchInfo: Search?
    }

    static func rows(_ data: Data) throws(ConnectorError) -> [Row] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activity = ((object["data"] as? [String: Any])?["data"] as? [String: Any])?["activity"] as? [String: Any] else {
            throw .formatChanged(detail: "activities/filter: Feld fehlt data.data.activity")
        }
        // A range without activity: an empty list or none.
        let entries = activity["transactions"] as? [Any] ?? []
        var rows: [Row] = []
        for entry in entries {
            guard let object = entry as? [String: Any], JSONSerialization.isValidJSONObject(object),
                  let raw = try? JSONSerialization.data(withJSONObject: stable(object), options: [.sortedKeys]),
                  let detail = try? JSONDecoder().decode(Detail.self, from: raw) else {
                throw .formatChanged(detail: "activities/filter: Eintrag nicht lesbar")
            }
            rows.append(Row(detail: detail, raw: raw))
        }
        return rows
    }

    /// What of a row is kept as `rawJSON`: the data about the payment. The rest of a row is page
    /// furniture (tracking payloads, style names, "this month" dividers) that differs from one
    /// answer to the next, which would make every sync rewrite every row, and is most of its size.
    static func stable(_ row: [String: Any]) -> [String: Any] {
        func pick(_ source: Any?, _ keys: [String]) -> [String: Any]? {
            guard let source = source as? [String: Any] else { return nil }
            let kept = source.filter { keys.contains($0.key) }
            return kept.isEmpty ? nil : kept
        }
        var kept = row.filter { ["id", "type", "status", "primitiveTxnType", "amounts", "isOnHold"].contains($0.key) }
        if let raw = pick((row["date"] as? [String: Any])?["rawDate"], ["date", "timeZone"]) { kept["date"] = ["rawDate": raw] }
        if let amount = row["amountInfo"] as? [String: Any] {
            var info: [String: Any] = [:]
            if let contents = pick(amount["contents"], ["amountText"]) { info["contents"] = contents }
            if let names = pick(amount["classNames"], ["transactionAmountClassName"]) { info["classNames"] = names }
            kept["amountInfo"] = info
        }
        if let party = pick(row["counterpartyInfo"], ["counterpartyName"]) { kept["counterpartyInfo"] = party }
        if let content = pick((row["descriptionInfo"] as? [String: Any])?["content"], ["transactionDescriptionText"]) { kept["descriptionInfo"] = ["content": content] }
        if let notes = pick(row["notesInfo"], ["notes"]) { kept["notesInfo"] = notes }
        if let links = pick(row["linksInfo"], ["detailsLink"]) { kept["linksInfo"] = links }
        if let search = pick(row["ftsSearchInfo"], ["displayType", "counterparty", "email", "displayAmount", "notes", "memo", "invoiceId"]) { kept["ftsSearchInfo"] = search }
        return kept
    }

    /// The rows of `account`'s currency as transactions.
    ///
    /// A payment in another currency that PayPal converted (a row in USD without a USD balance)
    /// is left out: the list does not say what it cost in the account's currency.
    static func transactions(_ rows: [Row], account: Account) throws(ConnectorError) -> [Transaction] {
        var result: [Transaction] = []
        var seen: Set<String> = []
        var foreign = 0
        for row in rows {
            let detail = row.detail
            guard let id = detail.id, !id.isEmpty else { throw .formatChanged(detail: "activities/filter: Feld fehlt id") }
            guard let currency = detail.amounts?.currencyCode?.uppercased(), currency.count == 3 else {
                throw .formatChanged(detail: "activities/filter: Feld fehlt amounts.currencyCode")
            }
            guard let text = detail.amountInfo?.contents?.amountText,
                  let amount = amountCents(text, isCredit: detail.amountInfo?.classNames?.transactionAmountClassName?.contains("isCredit") ?? false) else {
                throw .formatChanged(detail: "activities/filter: Betrag nicht lesbar")
            }
            guard let day = detail.date?.rawDate?.date.flatMap(date).map(BankDay.init) else {
                throw .formatChanged(detail: "activities/filter: Feld fehlt date.rawDate.date")
            }
            guard currency == account.currency else {
                foreign += 1
                continue
            }
            // Ranges touch at their ends: the same row may come twice.
            guard seen.insert(id).inserted else { continue }
            let status = status(detail.status)
            let name = detail.counterpartyInfo?.counterpartyName.map(collapse).flatMap { $0.isEmpty ? nil : $0 } ?? "PayPal"
            let kind = kind(detail)
            let note = detail.notesInfo?.notes.map(collapse) ?? ""
            let purpose = ([name] + [kind, note].filter { !$0.isEmpty && $0 != name }).joined(separator: " ")
            result.append(Transaction(
                accountID: account.id,
                bookingDate: status == .pending ? nil : day,
                valueDate: day,
                amountCents: amount,
                currency: currency,
                counterpartName: name,
                purpose: purpose,
                status: status,
                // PayPal's ID alone for EUR (as imported so far); with the currency elsewhere, so an
                // activity listed under two currencies cannot overwrite itself across accounts.
                externalID: currency == "EUR" ? id : "\(id):\(currency)",
                rawJSON: row.raw
            ))
        }
        if foreign > 0 { log.info("PayPal: \(foreign, privacy: .public) Zeilen in anderer Währung ausgelassen") }
        return Transaction.uniquingIDs(result)
    }

    /// Recorded so far: only `COMPLETED`. The other names are what PayPal's interfaces use
    /// elsewhere; a status nobody has seen counts as not final rather than failing the sync.
    static func status(_ text: String?) -> TransactionStatus {
        switch text?.uppercased() {
        case "COMPLETED", "REFUNDED", "PARTIALLY_REFUNDED": return .booked
        case "DENIED", "CANCELED", "CANCELLED", "REVERSED", "FAILED", "EXPIRED", "VOIDED", "RETURNED": return .cancelled
        case "PENDING", "UNCLAIMED", "ON_HOLD", "HELD", "PROCESSING", "CREATED": return .pending
        default:
            // Only a name in PayPal's own spelling is logged.
            let name = text.flatMap { $0.count <= 40 && $0.allSatisfy { $0.isUppercase || $0 == "_" } ? $0 : nil } ?? "?"
            log.notice("PayPal: unbekannter Status \(name, privacy: .public), als vorgemerkt geführt")
            return .pending
        }
    }

    /// What kind of activity it is, in PayPal's words ("Zahlung", "Geld gesendet").
    static func kind(_ detail: Detail) -> String {
        if let type = detail.ftsSearchInfo?.displayType.map(collapse), !type.isEmpty { return type }
        // "12. Okt. . Zahlung": the part after the date.
        guard let text = detail.descriptionInfo?.content?.transactionDescriptionText, let separator = text.range(of: " . ", options: .backwards) else { return "" }
        return collapse(String(text[separator.upperBound...]))
    }

    /// `"&minus;1.234,56 €"`, `"+12,00 €"`, `"−40.00 $ USD"` → cents with sign. Without a sign the
    /// row's style decides (credits are marked).
    static func amountCents(_ text: String, isCredit: Bool) -> Int? {
        let plain = text.replacingOccurrences(of: "&minus;", with: "−").replacingOccurrences(of: "&#8722;", with: "−")
            .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let negative: Bool
        switch plain.first {
        case "−", "-", "–": negative = true
        case "+": negative = false
        default: negative = !isCredit
        }
        let number = plain.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard number.contains(where: \.isNumber) else { return nil }
        // The last separator is the decimal one if exactly two digits follow it.
        var whole = number
        var fraction = ""
        if let last = number.lastIndex(where: { $0 == "." || $0 == "," }), number.distance(from: last, to: number.endIndex) == 3 {
            whole = String(number[..<last])
            fraction = String(number[number.index(after: last)...])
        }
        let digits = whole.filter(\.isNumber)
        guard digits.count <= 12, let units = Int(digits.isEmpty ? "0" : digits), let cents = Int(fraction.isEmpty ? "0" : fraction) else { return nil }
        let value = units * 100 + cents
        return negative ? -value : value
    }

    /// `2026-11-05T09:24:11.000Z`, with or without fractions.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: fractionalStyle)) ?? (try? Date(text, strategy: plainStyle))
    }

    // Value types, built once: a first import parses thousands of rows.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
