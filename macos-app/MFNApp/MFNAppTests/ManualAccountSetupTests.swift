import Foundation
import MFNCore
import Testing
@testable import MFN

@MainActor @Suite struct ManualAccountSetupTests {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    @Test(arguments: ["Pacific/Auckland", "America/Los_Angeles", "UTC", "Europe/Berlin", "Pacific/Kiritimati"])
    func openingDateKeepsTheCalendarDay(zone: String) {
        let calendar = Self.calendar(zone)
        for (year, month, dayOfMonth) in [(2026, 3, 14), (2026, 1, 1), (2024, 2, 29), (2026, 12, 31)] {
            guard let day = BankDay(year: year, month: month, day: dayOfMonth) else {
                Issue.record("invalid day")
                continue
            }
            let picked = ManualAccountDraft.pickerDate(day, calendar: calendar)
            #expect(ManualAccountDraft.bankDay(picked: picked, calendar: calendar) == day)
            let parts = calendar.dateComponents([.year, .month, .day], from: picked)
            #expect(parts.year == year && parts.month == month && parts.day == dayOfMonth)
        }
    }

    @Test func lateAndEarlyPickedTimesStayOnTheirDay() {
        // 23:50 in Los Angeles is already the next day in Berlin; the picked day is what counts.
        let calendar = Self.calendar("America/Los_Angeles")
        let late = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 23, minute: 50)) ?? .distantPast
        #expect(ManualAccountDraft.bankDay(picked: late, calendar: calendar) == BankDay(year: 2026, month: 3, day: 14))
        let auckland = Self.calendar("Pacific/Auckland")
        let early = auckland.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 0, minute: 10)) ?? .distantPast
        #expect(ManualAccountDraft.bankDay(picked: early, calendar: auckland) == BankDay(year: 2026, month: 3, day: 14))
    }

    @Test func editingDraftRestoresOpeningBalanceAndDate() {
        let day = BankDay(year: 2026, month: 3, day: 14)
        let draft = ManualAccountDraft(account: Fixture.giro, name: "Mein Giro", opening: OpeningBalance(cents: -123_456, day: day))
        #expect(draft.name == "Mein Giro")
        #expect(draft.openingAmount == "-1.234,56")
        #expect(draft.usesOpeningDate)
        #expect(ManualAccountDraft.bankDay(picked: draft.openingDate) == day)
        #expect(CSVValues.cents(draft.openingAmount) == -123_456)
    }

    @Test func validDraftBuildsFields() {
        var draft = ManualAccountDraft()
        draft.name = "  Mein Konto "
        draft.openingAmount = "1.000,50"
        let fields = draft.fields
        #expect(fields?.name == "Mein Konto")
        #expect(fields?.opening == OpeningBalance(cents: 100_050, day: nil))
        #expect(draft.problem == nil)
    }

    @Test func problemMessages() {
        var draft = ManualAccountDraft()
        #expect(draft.problem == "Name fehlt.")
        #expect(draft.fields == nil)
        draft.name = "Konto"
        draft.openingAmount = "abc"
        #expect(draft.problem?.contains("Startsaldo") == true)
        draft.openingAmount = ""
        draft.iban = "DE00"
        #expect(draft.problem == ManualAccount.IBANProblem.wrongLength.message)
        draft.iban = "DE00 0000 0000 0000 0000 00"
        #expect(draft.problem == ManualAccount.IBANProblem.wrongChecksum.message)
        draft.iban = "D!"
        #expect(draft.problem == ManualAccount.IBANProblem.invalidCharacters.message)
        draft.iban = "  "
        #expect(draft.problem == nil)
    }

    @Test func currencyListIncludesAnExistingOtherCurrency() {
        var draft = ManualAccountDraft()
        #expect(draft.currencies == ManualAccountDraft.currencies)
        draft.currency = "SEK"
        #expect(draft.currencies.last == "SEK")
    }

    @Test func currencyIsLockedOnlyWhenTheAccountHasTransactions() {
        let model = Fixture.model(ledger: Fixture.snapshot(transactions: [Fixture.transaction("t1")]))
        let setup = BankSetup(model: model)
        setup.startManualAccount(editing: Fixture.giro)
        #expect(setup.manualCurrencyLocked)

        let empty = BankSetup(model: model)
        empty.startManualAccount(editing: Fixture.other)
        #expect(!empty.manualCurrencyLocked)

        let created = BankSetup(model: model)
        created.startManualAccount()
        #expect(!created.manualCurrencyLocked)
    }
}
