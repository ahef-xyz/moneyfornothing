import CryptoKit
import Foundation
import MFNCore

/// Pure mapping from FinTS / MT940 / MT535 to MFN models. No network, no state.
enum INGMapping {
    /// `9010`: ING answers this for an account without any booking.
    static let noTransactions = FinTSCode.noTransactions

    // MARK: Accounts

    /// Deterministic, opaque ID: survives re-syncs, reveals no account number.
    static func accountID(_ account: FinTSAccount, connectionID: ConnectionID) -> AccountID {
        let key = [connectionID.rawValue, account.blz, account.accountNumber, account.subAccount ?? ""].joined(separator: "|")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AccountID("ing-\(digest)")
    }

    static func accountType(_ account: FinTSAccount) -> AccountType? {
        if account.typeCode == nil {
            return account.allowedTransactions.contains("HKWPD") ? .depot : .giro
        }
        switch account.kind {
        case .giro: return .giro
        case .savings, .timeDeposit: return .tagesgeld
        case .depot: return .depot
        // ING has no FinTS access to cards; loans, building savings etc. are not supported.
        default: return nil
        }
    }

    static func account(_ fints: FinTSAccount, connectionID: ConnectionID) -> Account? {
        guard let type = accountType(fints) else { return nil }
        let fallbackName = switch type {
        case .giro: "Girokonto"
        case .tagesgeld: "Extra-Konto"
        case .depot: "Direkt-Depot"
        case .card: "Karte"
        }
        let product = fints.productName?.trimmingCharacters(in: .whitespaces)
        let iban = fints.iban.map(Fingerprint.normalize(iban:)).flatMap { $0.isEmpty ? nil : $0 }
        return Account(
            id: accountID(fints, connectionID: connectionID),
            connectionID: connectionID,
            iban: iban,
            type: type,
            currency: validCurrency(fints.currency) ?? "EUR",
            name: product.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        )
    }

    // MARK: Return codes

    /// Segment-level errors for the business segment. `9010` → `unsupportedAccount`; anything
    /// else is unexpected. Only the code goes into the error – bank texts may contain account numbers.
    static func checkSegmentErrors(_ response: FinTSResponse) throws(ConnectorError) {
        let errors = response.segmentCodes.filter(\.isError)
        guard let first = errors.first else { return }
        if errors.contains(where: { $0.code == noTransactions }) { throw .unsupportedAccount }
        throw .formatChanged(detail: "ING: Rückmeldung \(first.code)")
    }

    // MARK: Balance

    /// `HISAL` v5–v7: 1 account, 2 product, 3 currency, 4 booked balance (C/D:amount:currency:date[:time]),
    /// 5 pending balance, 6 credit line, 7 available amount (amount:currency), …
    static func balance(_ hisal: FinTSSegment, fallbackCurrency: String, asOf: Date) throws(ConnectorError) -> Balance {
        let booked = hisal[3]
        guard let mark = booked[0], mark == "C" || mark == "D",
              let amount = booked[1].flatMap(MT940Text.cents)
        else { throw .formatChanged(detail: "ING: Saldo in HISAL nicht lesbar") }
        let currency = validCurrency(booked[2]) ?? validCurrency(hisal[2].first) ?? fallbackCurrency
        let available = hisal[6][0].flatMap(MT940Text.cents)
        return Balance(
            bookedCents: mark == "D" ? -amount : amount,
            availableCents: available,
            currency: currency,
            asOf: asOf
        )
    }

    // MARK: Transactions

    /// Storage period from `HIKAZS` (element 4, first component), else 90 days.
    static func storageDays(_ bpd: FinTSBPD, version: Int) -> Int {
        let parameters = bpd.parameters("HIKAZS")
        let segment = parameters.first { $0.version == version } ?? parameters.first
        guard let days = segment?[3][0].flatMap(Int.init), days > 0 else { return INGConnector.defaultHistoryDays }
        return days
    }

    /// Start day for `HKKAZ`: `since` (bank day), capped to the storage period. `nil` → whole period.
    /// Today counts as day 1 of the period, so the earliest day is `storageDays - 1` days back.
    static func statementStart(since: Date?, today: BankDay, storageDays: Int) -> BankDay {
        let earliest = today.adding(days: -(max(storageDays, 1) - 1))
        guard let since else { return earliest }
        return max(BankDay(since), earliest)
    }

    static func transaction(_ entry: MT940Entry, accountID: AccountID, currency: String, status: TransactionStatus) -> Transaction {
        let details = entry.details
        let counterpartIBAN = details?.counterpartAccount.flatMap(iban)
        let name = details?.counterpartName
            ?? details?.sepa["ABWA"]
            ?? details?.postingText
            ?? ""
        let purpose = details?.purpose ?? entry.supplementaryDetails ?? ""
        let booked = status == .booked
        return Transaction(
            accountID: accountID,
            bookingDate: booked ? (entry.entryDate ?? entry.valueDate) : nil,
            valueDate: entry.valueDate,
            amountCents: entry.amountCents,
            currency: currency,
            counterpartName: name,
            counterpartIBAN: counterpartIBAN,
            purpose: purpose,
            eref: details?.endToEndReference,
            mref: details?.mandateReference,
            creditorID: details?.creditorID,
            status: status,
            rawJSON: rawJSON(entry, currency: currency)
        )
    }

    /// The bank data, unchanged, plus the parsed subfields for later interpretation in `MFNCore`.
    static func rawJSON(_ entry: MT940Entry, currency: String) -> Data {
        var object: [String: Any] = [
            "format": "MT940",
            "61": entry.raw61,
            "currency": currency,
            "transactionType": entry.transactionType,
            "customerReference": entry.customerReference,
            "reversal": entry.isReversal,
        ]
        object["86"] = entry.raw86
        object["bankReference"] = entry.bankReference
        object["supplementaryDetails"] = entry.supplementaryDetails
        if let details = entry.details {
            object["gvc"] = details.transactionCode
            object["postingText"] = details.postingText
            object["primanota"] = details.primanota
            object["textKeyExtension"] = details.textKeyExtension
            object["counterpartBIC"] = details.counterpartBIC
            object["counterpartAccount"] = details.counterpartAccount
            if !details.sepa.isEmpty { object["sepa"] = details.sepa }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `?31` holds an IBAN for SEPA, an old account number otherwise.
    static func iban(_ text: String) -> String? {
        let compact = Fingerprint.normalize(iban: text)
        guard (15...34).contains(compact.count),
              compact.prefix(2).allSatisfy({ $0.isASCII && $0.isLetter }),
              compact.dropFirst(2).prefix(2).allSatisfy(\.isNumber),
              compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return compact
    }

    // MARK: Depot

    /// MT535 holdings → positions. Bonds (`FAMT` + `PRCT`) are expressed per 100 face value so that
    /// `quantity × priceCents` stays the market value: quantity = face / 100, price = percent in cents.
    static func positions(_ statement: MT535Statement, accountID: AccountID, currency: String, now: Date) -> [SecurityPosition] {
        statement.holdings.compactMap { holding in
            guard let isin = holding.isin, isISIN(isin) else { return nil }
            var quantity = holding.quantity
            var priceCents: Int?
            if let price = holding.price {
                if holding.priceIsPercentage {
                    quantity = holding.quantity / 100
                    priceCents = roundedCents(price * 100)
                } else {
                    priceCents = roundedCents(price * 100)
                }
            } else if let value = holding.holdingValueCents, holding.quantity != 0 {
                priceCents = roundedCents(Decimal(value) / holding.quantity)
            }
            let asOf = holding.priceDate?.startDate ?? statement.statementDate?.startDate ?? now
            let positionCurrency = validCurrency(holding.priceCurrency) ?? validCurrency(holding.holdingCurrency) ?? currency
            // Same unit as the price: bonds per 100 face, which only fits a quantity that was divided
            // by 100 (percent price); otherwise dropped. A purchase price in another currency is dropped.
            let purchaseCents = holding.purchasePrice.flatMap { price -> Int? in
                if let purchaseCurrency = validCurrency(holding.purchaseCurrency), purchaseCurrency != positionCurrency { return nil }
                if holding.quantityIsFaceAmount, !holding.priceIsPercentage { return nil }
                return roundedCents(price * 100)
            }
            return SecurityPosition(
                accountID: accountID,
                isin: isin,
                name: holding.name.isEmpty ? isin : holding.name,
                quantity: quantity,
                priceCents: priceCents ?? 0,
                currency: positionCurrency,
                asOf: asOf,
                purchasePriceCents: purchaseCents
            )
        }
    }

    static func roundedCents(_ value: Decimal) -> Int {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .bankers)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static func isISIN(_ text: String) -> Bool {
        text.count == 12 && text.prefix(2).allSatisfy { $0.isASCII && $0.isUppercase }
            && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func validCurrency(_ code: String?) -> String? {
        guard let code, code.count == 3, code.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return code
    }
}

extension FinTSAccount {
    /// UPD lists allowed transactions; an empty list means the bank did not restrict anything.
    func allows(_ request: String) -> Bool {
        allowedTransactions.isEmpty || allowedTransactions.contains(request)
    }
}
