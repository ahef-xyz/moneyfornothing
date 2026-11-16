import Foundation
import MFNCore

/// Validated input of the "Konto ohne Anbindung" form (protocol v10, `ConnectorID.manual`).
struct ManualAccountFields: Equatable {
    var name: String
    var type: AccountType
    var currency: String
    /// Upper case without spaces, checksum verified.
    var iban: String?
    var opening: OpeningBalance?
}

/// The form's raw text. Lives in `BankSetup` (one sheet for both ways of adding an account).
struct ManualAccountDraft: Equatable {
    /// No depots: positions cannot be imported from CSV.
    static let types: [AccountType] = [.giro, .tagesgeld, .card]
    static let currencies = ["EUR", "CHF", "USD", "GBP"]

    var name = ""
    var type: AccountType = .giro
    var currency = "EUR"
    var iban = ""
    /// Empty: no opening balance (the balance is the sum of the imported bookings).
    var openingAmount = ""
    var usesOpeningDate = false
    var openingDate = Date()

    init() {}

    /// The form of an existing account (editing).
    init(account: Account, name: String, opening: OpeningBalance?) {
        self.name = name
        type = account.type
        currency = account.currency
        iban = account.iban ?? ""
        if let opening {
            openingAmount = Self.amountText(opening.cents)
            if let day = opening.day {
                usesOpeningDate = true
                openingDate = Self.pickerDate(day)
            }
        }
    }

    var currencies: [String] {
        Self.currencies.contains(currency) ? Self.currencies : Self.currencies + [currency]
    }

    /// The first thing that keeps "Anlegen" disabled, as a sentence; `nil` when the form is valid.
    var problem: String? {
        switch validated {
        case .success: nil
        case let .failure(problem): problem.message
        }
    }

    var fields: ManualAccountFields? { try? validated.get() }

    struct Problem: Error, Equatable {
        let message: String
    }

    private var validated: Result<ManualAccountFields, Problem> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(Problem(message: "Name fehlt.")) }
        var iban: String?
        if let normalized = ManualAccount.normalizedIBAN(self.iban) {
            if let problem = ManualAccount.validate(iban: normalized) { return .failure(Problem(message: problem.message)) }
            iban = normalized
        }
        var opening: OpeningBalance?
        if !openingAmount.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let cents = CSVValues.cents(openingAmount) else {
                return .failure(Problem(message: "Der Startsaldo ist kein Betrag, z. B. 1.234,56 oder -50,00."))
            }
            opening = OpeningBalance(cents: cents, day: usesOpeningDate ? Self.bankDay(picked: openingDate) : nil)
        }
        return .success(ManualAccountFields(name: trimmedName, type: type, currency: currency, iban: iban, opening: opening))
    }

    /// The date picker works in the Mac's calendar and time zone, `BankDay` in Europe/Berlin:
    /// convert by calendar components, never by instant, so the day shown is the day stored.
    static func pickerDate(_ day: BankDay, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? day.startDate
    }

    /// The day the picker shows for `date` (see `pickerDate`).
    static func bankDay(picked date: Date, calendar: Calendar = .current) -> BankDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let bankDay = BankDay(year: year, month: month, day: day) else { return BankDay(date) }
        return bankDay
    }

    /// `-1234,56` → "-1.234,56": the form's own format, read back by `CSVValues.cents`.
    static func amountText(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
    }

    static func title(_ type: AccountType) -> String {
        switch type {
        case .giro: "Girokonto"
        case .tagesgeld: "Tagesgeld"
        case .card: "Kreditkarte"
        case .depot: "Depot"
        }
    }
}
