import CryptoKit
import Foundation
import MFNCore

// MARK: - System ID persistence

/// Persists the FinTS customer system ID (`HKSYN`) per connection.
///
/// The DKB ties the 90-day SCA exemption to the system ID: a new ID on every app start would
/// mean an approval in the DKB-App on every sync. Persist it.
public protocol DKBStateStore: Sendable {
    func loadSystemID() async -> String?
    func saveSystemID(_ systemID: String) async
}

/// In-process only (tests, previews). The app uses `KeychainDKBStateStore`.
public actor InMemoryDKBStateStore: DKBStateStore {
    private var systemID: String?

    public init(systemID: String? = nil) {
        self.systemID = systemID
    }

    public func loadSystemID() async -> String? { systemID }
    public func saveSystemID(_ systemID: String) async { self.systemID = systemID }
}

/// Keychain-backed store (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` via `MFNCore.Keychain`).
public struct KeychainDKBStateStore: DKBStateStore {
    public let connectionID: ConnectionID
    public let keychain: Keychain

    private static let log = Log.logger("dkb")

    public init(connectionID: ConnectionID, keychain: Keychain = Keychain()) {
        self.connectionID = connectionID
        self.keychain = keychain
    }

    private var key: String { "fints.dkb.systemID.\(connectionID.rawValue)" }

    public func loadSystemID() async -> String? {
        do {
            return try keychain.data(for: key).map { String(decoding: $0, as: UTF8.self) }
        } catch {
            Self.log.error("DKB: System-ID nicht lesbar (\(String(describing: error), privacy: .public)); neue Synchronisierung")
            return nil
        }
    }

    public func saveSystemID(_ systemID: String) async {
        do {
            try keychain.set(Data(systemID.utf8), for: key)
        } catch {
            Self.log.error("DKB: System-ID nicht gespeichert (\(String(describing: error), privacy: .public))")
        }
    }
}

// MARK: - MT940 / MT535

/// Parsers for the SWIFT formats: MT940/MT942 as fallback (`HKKAZ` when `HKCAZ` is not offered)
/// and MT535 for the depot (`HKWPD`). `.standard` uses the shared `MT940Parser`/`MT535Parser`
/// and the same model mapping as the ING connector (`INGMapping`), so both FinTS banks map
/// SWIFT data identically. Injectable for tests (`.none` = not available).
public struct DKBStatementParsers: Sendable {
    /// `booked` = HIKAZ element 1 (MT940), `pending` = element 2 (MT942), if any.
    public typealias MT940 = @Sendable (_ booked: Data, _ pending: Data?, _ accountID: AccountID) throws(ConnectorError) -> [Transaction]
    /// HIWPD element 1 (MT535).
    public typealias MT535 = @Sendable (_ holdings: Data, _ accountID: AccountID, _ asOf: Date) throws(ConnectorError) -> [SecurityPosition]

    public var mt940: MT940?
    public var mt535: MT535?

    public init(mt940: MT940? = nil, mt535: MT535? = nil) {
        self.mt940 = mt940
        self.mt535 = mt535
    }

    public static let none = DKBStatementParsers()

    /// `MT940Parser` + `MT535Parser`; default of `DKBConnector`.
    public static let standard = DKBStatementParsers(
        mt940: { booked, pending, accountID throws(ConnectorError) in
            do throws(MT940Error) {
                var result: [Transaction] = []
                for statement in try MT940Parser.parse(booked) {
                    let currency = statement.currency ?? "EUR"
                    result += statement.entries.map { INGMapping.transaction($0, accountID: accountID, currency: currency, status: .booked) }
                }
                if let pending {
                    for statement in try MT940Parser.parse(pending) {
                        let currency = statement.currency ?? "EUR"
                        result += statement.entries.map { INGMapping.transaction($0, accountID: accountID, currency: currency, status: .pending) }
                    }
                }
                return result
            } catch {
                throw error.connectorError
            }
        },
        mt535: { holdings, accountID, asOf throws(ConnectorError) in
            do throws(MT940Error) {
                return INGMapping.positions(try MT535Parser.parse(holdings), accountID: accountID, currency: "EUR", now: asOf)
            } catch {
                throw error.connectorError
            }
        }
    )
}

// MARK: - Mapping

enum DKBMapping {
    /// Deterministic, opaque account ID (no account number in clear: IDs end up in logs).
    static func accountID(_ account: FinTSAccount) -> AccountID {
        let source = [account.blz, account.accountNumber, account.subAccount ?? ""].joined(separator: "|")
        let digest = SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AccountID("dkb-\(digest)")
    }

    static func accountType(_ kind: FinTSAccount.Kind) -> AccountType? {
        switch kind {
        case .giro: .giro
        case .savings, .timeDeposit: .tagesgeld
        case .depot: .depot
        case .creditCard: .card
        case .loan, .fund, .buildingSavings, .insurance, .other: nil
        }
    }

    static func defaultName(_ type: AccountType) -> String {
        switch type {
        case .giro: "Girokonto"
        case .tagesgeld: "Tagesgeld"
        case .depot: "Depot"
        case .card: "Visa Kreditkarte"
        }
    }

    /// Last four digits of the card number the DKB uses as account number for card accounts
    /// (masked or not, e.g. `4930********1234`).
    static func cardLast4(_ accountNumber: String) -> String? {
        let digits = accountNumber.filter(\.isNumber)
        guard digits.count >= 4, accountNumber.last?.isNumber == true else { return nil }
        return String(digits.suffix(4))
    }

    static func account(_ fints: FinTSAccount, connectionID: ConnectionID, creditLimitCents: Int?) -> Account? {
        guard let type = accountType(fints.kind) else { return nil }
        let product = fints.productName?.trimmingCharacters(in: .whitespaces)
        return Account(
            id: accountID(fints),
            connectionID: connectionID,
            iban: fints.iban.map { Fingerprint.normalize(iban: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            type: type,
            currency: fints.currency.flatMap { $0.count == 3 ? $0.uppercased() : nil } ?? "EUR",
            name: product.flatMap { $0.isEmpty ? nil : $0 } ?? defaultName(type),
            cardLast4: type == .card ? cardLast4(fints.accountNumber) : nil,
            creditLimitCents: type == .card || type == .giro ? creditLimitCents : nil
        )
    }

    /// `HIUPD` element 9 (Kontolimit): `Limitart : Wert : Währung : Limit-Tage`.
    static func creditLimit(_ hiupd: FinTSSegment) -> Int? {
        let limit = hiupd[8]
        guard limit[0] != nil, let value = limit[1] else { return nil }
        return DKBAmount.cents(value)
    }
}

// MARK: - Amounts and balances

enum DKBAmount {
    /// FinTS decimal (`1234,56`, `1234,`, `0,5`) → cents. Exact, never `Double`.
    static func cents(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, parts.count <= 2, parts[0].allSatisfy(\.isNumber) else { return nil }
        guard let whole = Int(parts[0].isEmpty ? "0" : parts[0]) else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2, fraction.allSatisfy(\.isNumber) else { return nil }
        while fraction.count < 2 { fraction += "0" }
        guard let decimals = Int(fraction) else { return nil }
        let (product, overflow) = whole.multipliedReportingOverflow(by: 100)
        return overflow ? nil : product + decimals
    }

    /// Saldo DEG: `C|D : Betrag : Währung : Datum [: Uhrzeit]` → signed cents and currency.
    static func balance(_ element: FinTSDataElement) -> (cents: Int, currency: String?)? {
        guard let sign = element[0], let value = element[1].flatMap(cents) else { return nil }
        switch sign {
        case "C": return (value, element[2])
        case "D": return (-value, element[2])
        default: return nil
        }
    }

    /// Betrag DEG: `Wert : Währung` → cents.
    static func amount(_ element: FinTSDataElement) -> Int? {
        element[0].flatMap(cents)
    }
}

enum DKBBalanceParser {
    /// `HISAL` v5–v7: 1 account, 2 product, 3 currency, 4 booked balance, 5 pending balance,
    /// 6 credit line, 7 available amount, …
    static func parse(_ hisal: FinTSSegment, asOf: Date) throws(ConnectorError) -> Balance {
        guard let booked = DKBAmount.balance(hisal[3]) else {
            throw .formatChanged(detail: "DKB: HISAL ohne gebuchten Saldo")
        }
        let currency = booked.currency ?? hisal[2].first ?? "EUR"
        return Balance(bookedCents: booked.cents, availableCents: DKBAmount.amount(hisal[6]), currency: currency, asOf: asOf)
    }
}
