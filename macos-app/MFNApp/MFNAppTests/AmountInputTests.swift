import Foundation
import Testing
@testable import MFN

@MainActor @Suite struct AmountInputTests {
    @Test func parsesGermanAndEnglishStyle() {
        #expect(BudgetSheet.parseCents("2.000") == 200_000)
        #expect(BudgetSheet.parseCents("2,000") == 200_000)
        #expect(BudgetSheet.parseCents("2000,50") == 200_050)
        #expect(BudgetSheet.parseCents("12.50") == 1_250)
        #expect(BudgetSheet.parseCents("1.234,5") == 123_450)
        #expect(BudgetSheet.parseCents("1,234.50") == 123_450)
        #expect(BudgetSheet.parseCents("€ 9,99") == 999)
        #expect(BudgetSheet.parseCents("1'234.50") == 123_450)
        #expect(BudgetSheet.parseCents("1’234.50") == 123_450)
        #expect(BudgetSheet.parseCents("١٢٫٥") == 1_250)
        #expect(BudgetSheet.parseCents("۱۲٫۵۰") == 1_250)
    }

    @Test func rejectsNonAmounts() {
        #expect(BudgetSheet.parseCents("0") == nil)
        #expect(BudgetSheet.parseCents("abc") == nil)
        #expect(BudgetSheet.parseCents("12,345.6.7") == nil)
    }

    @Test func fieldTextRoundTrips() {
        for locale in [Locale(identifier: "de_DE"), Locale(identifier: "en_US"), Locale(identifier: "de_CH"), Locale(identifier: "ar_EG")] {
            let text = RecurringDraft.text(123_450, locale: locale)
            #expect(BudgetSheet.parseCents(text) == 123_450)
        }
    }
}
