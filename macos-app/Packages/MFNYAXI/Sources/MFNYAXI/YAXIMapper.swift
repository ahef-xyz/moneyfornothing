import CryptoKit
import Foundation
import MFNCore
import RoutexModels

typealias RXAccount = RoutexModels.Account
typealias RXTransaction = RoutexModels.Transaction
typealias RXBalances = RoutexModels.Balances

/// YAXI models → MFN models (docs/v0.7.0.md section 4). No interpretation beyond the bank's fields.
enum YAXIMapper {
    static let log = Log.logger("yaxi")

    // MARK: Accounts

    /// `nil` for account types MFN does not show (yet): loans, insurance, depots (YAXI has no
    /// positions service), unknown.
    static func account(_ source: RXAccount, connection: MFNCore.ConnectionID) -> YAXIConnectionState.KnownAccount? {
        let type: MFNCore.AccountType
        switch source.type {
        case .current?: type = .giro
        case .savings?, .callMoney?, .timeDeposit?: type = .tagesgeld
        case .card?: type = .card
        // Some banks send accounts without a type: shown as a current account instead of dropped.
        case nil: type = .giro
        case let other?:
            log.notice("YAXI: Kontoart \(other.rawValue, privacy: .public) übersprungen")
            return nil
        }
        guard let reference = reference(source) else {
            log.notice("YAXI: Konto ohne IBAN, Nummer oder Kartennummer übersprungen (Art \(source.type?.rawValue ?? "ohne Angabe", privacy: .public))")
            return nil
        }
        let iban = nonEmpty(source.iban).map(normalizeIBAN)
        let fallback = switch type {
        case .giro: "Girokonto"
        case .tagesgeld: "Tagesgeld"
        case .card: "Kreditkarte"
        case .depot: "Depot"
        }
        let account = MFNCore.Account(
            id: accountID(connection: connection, reference: reference),
            connectionID: connection,
            iban: iban,
            type: type,
            currency: nonEmpty(source.currency)?.uppercased() ?? "EUR",
            name: nonEmpty(source.displayName) ?? nonEmpty(source.name) ?? nonEmpty(source.productName) ?? fallback,
            cardLast4: type == .card ? source.maskedPan.flatMap(last4) : nil
        )
        return YAXIConnectionState.KnownAccount(account: account, reference: reference)
    }

    /// How YAXI addresses an account, as a string for the state (`iban:…`, `number:…`, `maskedPan:…`).
    static func reference(_ account: RXAccount) -> String? {
        if let iban = nonEmpty(account.iban) { return "iban:" + normalizeIBAN(iban) }
        if let number = nonEmpty(account.number) { return "number:" + number }
        if let pan = nonEmpty(account.maskedPan) { return "maskedPan:" + pan }
        return nil
    }

    static func accountReference(_ known: YAXIConnectionState.KnownAccount) -> AccountReference? {
        let parts = known.reference.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let id: AccountIdentifier
        switch parts[0] {
        case "iban": id = .iban(parts[1])
        case "number": id = .number(parts[1])
        case "maskedPan": id = .maskedPan(parts[1])
        default: return nil
        }
        return AccountReference(id: id, currency: known.account.currency)
    }

    /// Deterministic and opaque (IDs may be logged).
    static func accountID(connection: MFNCore.ConnectionID, reference: String) -> AccountID {
        let digest = SHA256.hash(data: Data("\(connection.rawValue)|\(reference)".utf8))
        return AccountID("yaxi-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Balances

    static func balance(_ balances: RXBalances, for known: YAXIConnectionState.KnownAccount, asOf: Date) throws(ConnectorError) -> MFNCore.Balance {
        guard let entry = balances.balances.first(where: { matches($0.account, known) }) else {
            throw .formatChanged(detail: "YAXI Saldo fehlt")
        }
        // Without credit line first: a balance with `creditLimitIncluded` is what can be spent, not
        // what is on the account.
        func pick(_ type: BalanceType) -> RoutexModels.Balance? {
            let all = entry.balances.filter { $0.balanceType == type }
            return all.first { $0.creditLimitIncluded != true } ?? all.first
        }
        // M0: C24 sends only `Available` (twice), no `Booked`: then the available amount without
        // credit line is the balance.
        guard let booked = pick(.booked) ?? pick(.expected) ?? pick(.available) else {
            throw .formatChanged(detail: "YAXI Saldo: kein Saldo")
        }
        let availables = entry.balances.filter { $0.balanceType == .available }
        let available = availables.first { $0.creditLimitIncluded == true } ?? availables.first
        return MFNCore.Balance(
            bookedCents: try cents(booked.amount, context: "balance"),
            availableCents: try available.map { balance throws(ConnectorError) in try cents(balance.amount, context: "available") },
            currency: booked.currency.uppercased(),
            asOf: booked.dateTime ?? asOf
        )
    }

    static func matches(_ reference: AccountReference, _ known: YAXIConnectionState.KnownAccount) -> Bool {
        switch reference.id {
        case let .iban(iban): known.reference == "iban:" + normalizeIBAN(iban)
        case let .number(number): known.reference == "number:" + number
        case let .maskedPan(pan): known.reference == "maskedPan:" + pan
        }
    }

    // MARK: Transactions

    static func transaction(_ source: RXTransaction, account: MFNCore.Account, today: BankDay = BankDay(Date())) throws(ConnectorError) -> MFNCore.Transaction {
        let status: MFNCore.TransactionStatus = switch source.status {
        case .booked, .invoiced, .paid: .booked
        case .pending: .pending
        case .canceled: .cancelled
        }
        let booking = try day(source.bookingDate, field: "bookingDate")
        let value = try day(source.valueDate, field: "valueDate")
        let transaction = try day(source.transactionDate, field: "transactionDate")
        if status == .booked, booking == nil, value == nil, transaction == nil { throw .formatChanged(detail: "YAXI Umsatz: gebucht ohne Datum") }
        // C24 sends pending transactions without any date: they are open as of today. Their
        // fingerprint has no booking date, so the date moving with the day creates no duplicates.
        guard let valueDate = value ?? transaction ?? booking ?? (status == .booked ? nil : today) else {
            throw .formatChanged(detail: "YAXI Umsatz: kein Datum")
        }

        let amount = try cents(source.amount.amount, context: "amount")
        // Outgoing: the counterpart is the creditor; incoming: the debtor. A reversal carries the parties
        // of the original transaction, so its sign points to the other side.
        let party = (amount < 0) != source.reversal ? source.creditor : source.debtor
        let original = try source.originalAmount.flatMap { original throws(ConnectorError) -> (Int, String)? in
            guard original.currency.uppercased() != source.amount.currency.uppercased() else { return nil }
            return (try cents(original.amount, context: "originalAmount"), original.currency.uppercased())
        }
        return MFNCore.Transaction(
            accountID: account.id,
            bookingDate: status == .booked ? (booking ?? value) : nil,
            valueDate: valueDate,
            amountCents: amount,
            currency: source.amount.currency.uppercased(),
            counterpartName: nonEmpty(party?.name) ?? nonEmpty(party?.ultimate) ?? "",
            counterpartIBAN: nonEmpty(party?.iban).map(normalizeIBAN),
            purpose: source.remittanceInformation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " "),
            eref: nonEmpty(source.endToEndID).flatMap { $0 == "NOTPROVIDED" ? nil : $0 },
            mref: nonEmpty(source.mandateID),
            creditorID: nonEmpty(source.creditorID),
            status: status,
            externalID: nonEmpty(source.entryReference) ?? nonEmpty(source.accountServicerReference) ?? nonEmpty(source.transactionID),
            originalAmountCents: original?.0,
            originalCurrency: original?.1,
            rawJSON: raw(source)
        )
    }

    static func raw(_ source: RXTransaction) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(source)) ?? Data("{}".utf8)
    }

    static func day(_ date: ISODate?, field: String) throws(ConnectorError) -> BankDay? {
        guard let date else { return nil }
        guard let day = BankDay(iso: String(date.rawValue.prefix(10))) else {
            throw .formatChanged(detail: "YAXI Umsatz: \(field) kein Datum")
        }
        return day
    }

    // MARK: Amounts

    /// Exact decimal → cents. More than two decimals only when the extra digits are zeros; never via `Double`.
    static func cents(_ value: Decimal, context: String) throws(ConnectorError) -> Int {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw .formatChanged(detail: "YAXI Betrag (\(context)) mit mehr als zwei Nachkommastellen") }
        guard abs(rounded) < 1_000_000_000_000_000 else { throw .formatChanged(detail: "YAXI Betrag (\(context)) zu groß") }
        return NSDecimalNumber(decimal: rounded).intValue
    }

    // MARK: Text

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func normalizeIBAN(_ iban: String) -> String {
        iban.uppercased().filter { !$0.isWhitespace }
    }

    static func last4(_ pan: String) -> String? {
        let digits = pan.filter(\.isNumber)
        return digits.count >= 4 ? String(digits.suffix(4)) : nil
    }
}
