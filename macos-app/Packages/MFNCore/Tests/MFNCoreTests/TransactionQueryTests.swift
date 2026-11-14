import Foundation
import Testing
@testable import MFNCore

@Suite struct TransactionQueryTests {
    private let today = BankDay(year: 2026, month: 11, day: 10)!

    private func tx(_ name: String, _ cents: Int, _ day: BankDay, purpose: String = "", account: AccountID = "a1", category: CategoryID? = nil, iban: String? = nil) -> Transaction {
        var transaction = Transaction(
            accountID: account, bookingDate: day, valueDate: day, amountCents: cents, currency: "EUR",
            counterpartName: name, counterpartIBAN: iban, purpose: purpose, status: .booked, rawJSON: Data()
        )
        transaction.categoryID = category
        return transaction
    }

    private var sample: [Transaction] {
        [
            tx("REWE Markt", -4_250, today, purpose: "Einkauf Lebensmittel", category: "lebensmittel"),
            tx("Arbeitgeber GmbH", 320_000, today.adding(days: -9), purpose: "Gehalt Oktober", iban: "DE89370400440532013000"),
            tx("Café Glück", -1_250, today.adding(days: -40), account: "a2"),
            tx("Stadtwerke", -8_900, BankDay(year: 2025, month: 12, day: 2)!, purpose: "Abschlag Strom"),
        ]
    }

    @Test func textMatchesAllWordsFoldedAcrossFields() {
        #expect(TransactionQuery(text: "rewe lebensmittel").filter(sample, today: today).map(\.counterpartName) == ["REWE Markt"])
        #expect(TransactionQuery(text: "cafe").filter(sample, today: today).count == 1, "diacritics folded")
        #expect(TransactionQuery(text: "DE89 3704").filter(sample, today: today).count == 1, "IBAN with spaces")
        #expect(TransactionQuery(text: "rewe gehalt").filter(sample, today: today).isEmpty)
        #expect(TransactionQuery(text: "privat").filter(sample, today: today) { $0 == "a2" ? "C24 Privat" : nil }.count == 1, "account name")
    }

    @Test func amountsMatchInGermanAndEnglishNotation() {
        #expect(TransactionQuery(text: "42,50").filter(sample, today: today).count == 1)
        #expect(TransactionQuery(text: "42.5").filter(sample, today: today).count == 1)
        #expect(TransactionQuery(text: "3.200,00").filter(sample, today: today).count == 1)
        #expect(TransactionQuery(text: "-12,50").filter(sample, today: today).count == 1)
        #expect(TransactionQuery(text: "+12,50").filter(sample, today: today).isEmpty, "sign given: must match")
        #expect(TransactionQuery.amountCents("1.234,56") == 123_456)
        #expect(TransactionQuery.amountCents("abc") == nil)
    }

    @Test func directionPeriodCategoryAccount() {
        #expect(TransactionQuery(direction: .inflow).filter(sample, today: today).count == 1)
        #expect(TransactionQuery(direction: .outflow).filter(sample, today: today).count == 3)
        #expect(TransactionQuery(period: .last30Days).filter(sample, today: today).count == 2)
        #expect(TransactionQuery(period: .thisMonth).filter(sample, today: today).count == 2, "10. and 1. November")
        #expect(TransactionQuery(period: .lastMonth).filter(sample, today: today).map(\.counterpartName) == ["Café Glück"], "1. Oktober")
        #expect(TransactionQuery(period: .lastYear).filter(sample, today: today).map(\.counterpartName) == ["Stadtwerke"])
        #expect(TransactionQuery(category: "lebensmittel").filter(sample, today: today).count == 1)
        #expect(TransactionQuery(accounts: ["a2"]).filter(sample, today: today).count == 1)
    }

    @Test func periodRanges() {
        let march = BankDay(year: 2026, month: 3, day: 31)!
        #expect(TransactionQuery.Period.lastMonth.range(today: march) == BankDay(year: 2026, month: 2, day: 1)!...BankDay(year: 2026, month: 2, day: 28)!)
        let january = BankDay(year: 2026, month: 1, day: 15)!
        #expect(TransactionQuery.Period.lastMonth.range(today: january)?.lowerBound == BankDay(year: 2025, month: 12, day: 1))
    }

    @Test func sorting() {
        let names = { (sort: TransactionQuery.Sort) in TransactionQuery(sort: sort).apply(sample, today: today).map(\.counterpartName) }
        #expect(names(.newestFirst) == ["REWE Markt", "Arbeitgeber GmbH", "Café Glück", "Stadtwerke"])
        #expect(names(.oldestFirst) == ["Stadtwerke", "Café Glück", "Arbeitgeber GmbH", "REWE Markt"])
        #expect(names(.largestOutflow).first == "Stadtwerke")
        #expect(names(.largestInflow).first == "Arbeitgeber GmbH")
        #expect(names(.counterpart) == ["Arbeitgeber GmbH", "Café Glück", "REWE Markt", "Stadtwerke"])
    }

    @Test func filteringFlag() {
        #expect(!TransactionQuery().isFiltering)
        #expect(!TransactionQuery(text: "   ", sort: .largestInflow).isFiltering)
        #expect(TransactionQuery(text: "x").isFiltering)
        #expect(TransactionQuery(period: .thisYear).isFiltering)
    }
}
