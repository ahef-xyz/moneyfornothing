import Foundation

extension ConnectorID {
    /// v10: `false` for `.manual` (account without a bank connection): no connector, no sync,
    /// no sync state, no credentials.
    public var hasConnector: Bool { self != .manual }
}

extension Connection {
    /// v10: account without a bank connection ("Ohne Anbindung").
    public var isManual: Bool { connectorID == .manual }
}

/// The balance the user entered for an account without a bank connection. Persisted in the
/// store (`LedgerSnapshot.openingBalances`), not part of the protocol models.
public struct OpeningBalance: Sendable, Equatable, Hashable, Codable {
    public var cents: Int
    /// Bookings from this day on are added to `cents`; earlier ones are already in it.
    /// `nil`: every booking counts.
    public var day: BankDay?

    public init(cents: Int, day: BankDay? = nil) {
        self.cents = cents
        self.day = day
    }
}

/// Accounts without a bank connection (protocol v10, `ConnectorID.manual`): IDs, IBAN check and
/// the computed balance. Their transactions come from the CSV import only.
public enum ManualAccount {
    /// IDs of a new manual account: `manual:<UUID>` for its connection and its account.
    public static func newIDs() -> (connection: ConnectionID, account: AccountID) {
        let uuid = UUID().uuidString
        return (ConnectionID("manual:\(uuid)"), AccountID("manual:\(uuid)"))
    }

    /// Opening balance plus every booked transaction (in the account's currency) from the
    /// opening day on. Pending, planned and cancelled ones do not count, like at a bank.
    public static func balance(opening: OpeningBalance?, transactions: [Transaction], currency: String, asOf: Date) -> Balance {
        var cents = opening?.cents ?? 0
        for transaction in transactions where transaction.status == .booked && transaction.currency == currency {
            if let day = opening?.day, transaction.effectiveDate < day { continue }
            // Saturating: a crafted import must not trap the app (amounts are capped on import too).
            cents = cents.addingSaturating(transaction.amountCents)
        }
        return Balance(bookedCents: cents, availableCents: nil, currency: currency, asOf: asOf)
    }

    public enum IBANProblem: Error, Equatable, Sendable {
        case invalidCharacters
        case wrongLength
        case wrongChecksum

        public var message: String {
            switch self {
            case .invalidCharacters: "Die IBAN darf nur Buchstaben und Ziffern enthalten und beginnt mit dem Ländercode."
            case .wrongLength: "Die IBAN hat nicht die richtige Länge."
            case .wrongChecksum: "Die Prüfziffer der IBAN stimmt nicht. Bitte auf Tippfehler prüfen."
            }
        }
    }

    /// Lengths of the IBAN countries MFN users will meet most; others only get 15–34.
    private static let lengths: [String: Int] = [
        "DE": 22, "AT": 20, "CH": 21, "LI": 21, "LU": 20, "NL": 18, "BE": 16, "FR": 27, "IT": 27, "ES": 24,
        "PT": 25, "IE": 22, "GB": 22, "DK": 18, "SE": 24, "NO": 15, "FI": 18, "PL": 28, "CZ": 24, "LT": 20,
        "EE": 20, "LV": 21, "MT": 31, "GR": 27, "HR": 21, "SI": 19, "SK": 24, "HU": 28, "RO": 24, "BG": 22,
    ]

    /// Upper case without spaces; `nil` for an empty field (the IBAN is optional).
    public static func normalizedIBAN(_ input: String) -> String? {
        let compact = input.uppercased().filter { !$0.isWhitespace }
        return compact.isEmpty ? nil : compact
    }

    /// Format and ISO 13616 checksum (mod 97). Expects `normalizedIBAN` output.
    public static func validate(iban: String) -> IBANProblem? {
        let characters = Array(iban)
        guard characters.count >= 4,
              characters.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              characters[0].isLetter, characters[1].isLetter, characters[2].isNumber, characters[3].isNumber else {
            return .invalidCharacters
        }
        let country = String(characters[0...1])
        if let expected = lengths[country] {
            guard characters.count == expected else { return .wrongLength }
        } else if !(15...34).contains(characters.count) {
            return .wrongLength
        }
        // Move the first four characters to the end, letters → 10…35, remainder mod 97 must be 1.
        var remainder = 0
        for character in characters[4...] + characters[0..<4] {
            let value: Int
            if let digit = character.wholeNumberValue {
                value = digit
            } else if let ascii = character.asciiValue {
                value = Int(ascii) - 55
            } else {
                return .invalidCharacters
            }
            remainder = value >= 10 ? (remainder * 100 + value) % 97 : (remainder * 10 + value) % 97
        }
        return remainder == 1 ? nil : .wrongChecksum
    }
}

extension Int {
    /// `self + other`, clamped to `Int.min...Int.max` instead of trapping on overflow. For sums of
    /// amounts that come from files or user input.
    func addingSaturating(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }
}
