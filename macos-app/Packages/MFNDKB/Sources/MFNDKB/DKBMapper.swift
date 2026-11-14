import CryptoKit
import Foundation
import MFNCore

/// DKB JSON → MFN models. No interpretation beyond the bank's fields (categories etc. are MFNCore's job).
enum DKBMapper {
    static let log = Log.logger("dkb")

    struct Entry: Sendable {
        /// DKB account UUID (path segment of the API).
        var dkbID: String
        var account: Account
        var booked: DKBMoney?
        var available: DKBMoney?
    }

    // MARK: Accounts

    static func entries(_ list: DKBAccountList, connectionID: ConnectionID, groupNames: [String: String] = [:]) throws(ConnectorError) -> [Entry] {
        var result: [Entry] = []
        for resource in list.data {
            let attributes = resource.attributes
            if attributes.state?.lowercased() == "closed" { continue } // UNVERIFIED: state value of a closed account
            let type: AccountType
            let fallback: String
            switch attributes.product?.type {
            case .checking?, nil:
                (type, fallback) = (.giro, "DKB Girokonto")
            case .savings?:
                (type, fallback) = (.tagesgeld, "DKB Tagesgeld")
            case let .unknown(raw)?:
                // Unknown product: keep it visible rather than dropping money silently.
                log.notice("DKB: unbekannter Produkttyp '\(raw, privacy: .public)'")
                (type, fallback) = (.giro, "DKB Konto")
            }
            let name = groupNames[resource.id] ?? nonEmpty(attributes.product?.displayName) ?? fallback
            let currency = attributes.currencyCode ?? attributes.balance?.currencyCode ?? "EUR"
            let account = Account(
                id: accountID(connection: connectionID, dkbID: resource.id),
                connectionID: connectionID,
                iban: nonEmpty(attributes.iban).map(normalizeIBAN),
                type: type,
                currency: currency,
                name: name
            )
            result.append(Entry(dkbID: resource.id, account: account, booked: attributes.balance, available: attributes.availableBalance))
        }
        return result
    }

    /// Group names the user gave in the web banking, for groups holding exactly one account.
    static func groupNames(_ settings: DKBDisplaySettingsList) -> [String: String] {
        var names: [String: String] = [:]
        for resource in settings.data {
            for group in (resource.attributes?.productGroups ?? [:]).values {
                guard let name = nonEmpty(group.name), let accounts = group.products?.accounts, accounts.count == 1,
                      let accountID = accounts.keys.first else { continue }
                names[accountID] = name
            }
        }
        return names
    }

    /// Deterministic and opaque (IDs may be logged).
    static func accountID(connection: ConnectionID, dkbID: String) -> AccountID {
        let digest = SHA256.hash(data: Data("\(connection.rawValue)|\(dkbID.lowercased())".utf8))
        return AccountID("dkbweb-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Balance

    static func balance(_ entry: Entry, asOf: Date) throws(ConnectorError) -> Balance {
        guard let booked = entry.booked else { throw .formatChanged(detail: "DKB Saldo: balance fehlt") }
        return Balance(
            bookedCents: try cents(booked.value, context: "balance"),
            availableCents: try entry.available.map { money throws(ConnectorError) in try cents(money.value, context: "availableBalance") },
            currency: booked.currencyCode ?? entry.account.currency,
            asOf: asOf
        )
    }

    // MARK: Transactions

    static func transaction(_ item: DKBTransaction, raw: Data, account: Account) throws(ConnectorError) -> Transaction {
        let attributes = item.attributes
        let bookingDay = try day(attributes.bookingDate, field: "bookingDate")
        let valueDay = try day(attributes.valueDate, field: "valueDate")
        let status: TransactionStatus
        switch attributes.status {
        case .booked?: status = .booked
        case .pending?: status = .pending
        case let .unknown(raw)?:
            log.notice("DKB: unbekannter Umsatzstatus '\(raw, privacy: .public)'")
            status = bookingDay == nil ? .pending : .booked
        case nil:
            status = bookingDay == nil ? .pending : .booked
        }
        if status == .booked, bookingDay == nil { throw .formatChanged(detail: "DKB Umsatz: gebucht ohne bookingDate") }
        guard let valueDate = valueDay ?? bookingDay else { throw .formatChanged(detail: "DKB Umsatz: kein Datum") }

        let amount = try cents(attributes.amount.value, context: "amount")
        // Outgoing: the bank's counterpart is the creditor; incoming: the debtor (own account on the other side).
        let party = amount < 0 ? attributes.creditor : attributes.debtor
        return Transaction(
            accountID: account.id,
            bookingDate: status == .booked ? bookingDay : nil,
            valueDate: valueDate,
            amountCents: amount,
            currency: attributes.amount.currencyCode ?? account.currency,
            counterpartName: nonEmpty(party?.name) ?? nonEmpty(attributes.transactionType) ?? "",
            counterpartIBAN: nonEmpty(party?.iban).map(normalizeIBAN),
            purpose: attributes.description ?? "",
            eref: nonEmpty(attributes.endToEndId),
            mref: nonEmpty(attributes.mandateId),
            creditorID: nonEmpty(attributes.creditor?.id),
            status: status,
            externalID: nonEmpty(item.id),
            rawJSON: raw
        )
    }

    private static func day(_ text: String?, field: String) throws(ConnectorError) -> BankDay? {
        guard let text = nonEmpty(text) else { return nil }
        guard let day = BankDay(iso: String(text.prefix(10))) else { throw .formatChanged(detail: "DKB Umsatz: \(field) kein Datum") }
        return day
    }

    // MARK: Amounts

    /// Exact decimal string → cents (`"-1234.5"` → -123450). Never via `Double`; more than two decimals are only
    /// accepted when the extra digits are zeros.
    static func cents(_ text: String, context: String) throws(ConnectorError) -> Int {
        var string = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if string.first == "-" || string.first == "+" {
            negative = string.first == "-"
            string = string.dropFirst()
        }
        let parts = string.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let integer = parts.first, !integer.isEmpty, integer.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw .formatChanged(detail: "DKB: Betrag \(context) nicht lesbar")
        }
        var fraction = parts.count > 1 ? parts[1] : ""
        guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }), !(parts.count > 1 && fraction.isEmpty) else {
            throw .formatChanged(detail: "DKB: Betrag \(context) nicht lesbar")
        }
        while fraction.count > 2, fraction.last == "0" { fraction = fraction.dropLast() }
        guard fraction.count <= 2 else { throw .formatChanged(detail: "DKB: Betrag \(context) mit Bruchteil-Cent") }
        let fractionDigits = String(fraction).padding(toLength: 2, withPad: "0", startingAt: 0)
        guard integer.count <= 15, let whole = Int(integer), let hundredths = Int(fractionDigits) else {
            throw .formatChanged(detail: "DKB: Betrag \(context) zu groß")
        }
        let value = whole * 100 + hundredths
        return negative ? -value : value
    }

    // MARK: Helpers

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func normalizeIBAN(_ iban: String) -> String {
        iban.uppercased().filter { !$0.isWhitespace }
    }
}
