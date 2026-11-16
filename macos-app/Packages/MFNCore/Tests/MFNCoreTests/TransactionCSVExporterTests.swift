import Foundation
import Testing
@testable import MFNCore

/// Synthetic data only; IBANs are fake `DE00…` values.
@Suite struct TransactionCSVExporterTests {
    private let day = BankDay(year: 2026, month: 3, day: 7)!

    private func tx(
        _ name: String = "Bäckerei Test",
        _ cents: Int = -1_234_56,
        purpose: String = "Einkauf",
        status: TransactionStatus = .booked,
        booking: BankDay?? = .none,
        iban: String? = nil,
        category: CategoryID? = nil,
        account: AccountID = "acc1"
    ) -> Transaction {
        var transaction = Transaction(
            accountID: account, bookingDate: booking ?? (status == .booked || status == .cancelled ? day : nil),
            valueDate: day, amountCents: cents, counterpartName: name, counterpartIBAN: iban,
            purpose: purpose, status: status, rawJSON: Data()
        )
        transaction.categoryID = category
        return transaction
    }

    private func csv(_ transactions: [Transaction]) -> String {
        TransactionCSVExporter.text(transactions, accountName: { _ in "Testbank Giro" }, accountIBAN: { _ in "DE00123456780000000001" })
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\r\n")
    }

    @Test func headerIsStable() {
        let header = lines(csv([]))[0]
        #expect(header == "Buchungstag;Wertstellung;Status;Gegenpartei;IBAN Gegenkonto;Verwendungszweck;Betrag;Währung;Kategorie;Konto;IBAN Konto;Ende-zu-Ende-Referenz;Mandatsreferenz;Gläubiger-ID;Originalbetrag;Originalwährung;Kategorie-ID")
        #expect(TransactionCSVExporter.columns.count == 17)
    }

    @Test func dataStartsWithBOMAndUsesCRLF() {
        let data = TransactionCSVExporter.data([tx()], accountName: { _ in "K" })
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.hasSuffix("\r\n"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF")
        #expect(text.components(separatedBy: "\r\n").count == 3, "header, one row, trailing empty")
    }

    @Test func bookedRowFormatsDatesAmountsAndCategory() {
        let row = lines(csv([tx(iban: "DE00999999990000000002", category: "lebensmittel")]))[1]
        #expect(row == "07.03.2026;07.03.2026;gebucht;Bäckerei Test;DE00999999990000000002;Einkauf;-1234,56;EUR;\(CategoryCatalog.title("lebensmittel"));Testbank Giro;DE00123456780000000001;;;;;;lebensmittel")
    }

    @Test func amounts() {
        #expect(TransactionCSVExporter.amount(-123_456) == "-1234,56")
        #expect(TransactionCSVExporter.amount(5) == "0,05")
        #expect(TransactionCSVExporter.amount(-5) == "-0,05")
        #expect(TransactionCSVExporter.amount(150_000) == "1500,00")
        #expect(TransactionCSVExporter.amount(0) == "0,00")
        #expect(TransactionCSVExporter.amount(-10) == "-0,10")
        #expect(TransactionCSVExporter.amount(Int.min).hasPrefix("-"), "no overflow")
    }

    @Test func pendingAndPlannedHaveNoBookingDay() {
        let rows = lines(csv([tx(status: .pending), tx(status: .planned), tx(status: .cancelled)]))
        #expect(rows[1].hasPrefix(";07.03.2026;vorgemerkt;"))
        #expect(rows[2].hasPrefix(";07.03.2026;geplant;"))
        #expect(rows[3].hasPrefix("07.03.2026;07.03.2026;storniert;"))
    }

    @Test func quotesSeparatorsQuotesAndNewlines() {
        let row = lines(csv([tx("Müller; Söhne \"GmbH\"", purpose: "Zeile 1\nZeile 2")]))
        let text = csv([tx("Müller; Söhne \"GmbH\"", purpose: "Zeile 1\r\nZeile 2")])
        #expect(row[1].hasPrefix("07.03.2026;07.03.2026;gebucht;\"Müller; Söhne \"\"GmbH\"\"\";;\"Zeile 1"))
        #expect(text.contains("\"Zeile 1\r\nZeile 2\""), "CRLF inside a purpose stays quoted")
        #expect(TransactionCSVExporter.field(" padded ") == "\" padded \"")
        #expect(TransactionCSVExporter.field("plain") == "plain")
    }

    @Test func formulaStartsAreNeutralised() {
        let row = lines(csv([tx("=HYPERLINK(\"x\")", purpose: "-Gutschrift", iban: "@x")]))[1]
        let fields = row.split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields[3] == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(fields[4] == "'@x")
        #expect(fields[5] == "'-Gutschrift")
        #expect(fields[6] == "-1234,56", "amounts keep their sign")
    }

    @Test func fileName() {
        #expect(TransactionCSVExporter.fileName(scope: "Alle Konten", day: day) == "MFN-Alle-Konten-2026-03-07.csv")
        #expect(TransactionCSVExporter.fileName(scope: "C24 Giro/Pocket: Urlaub", day: day) == "MFN-C24-Giro-Pocket-Urlaub-2026-03-07.csv")
        #expect(TransactionCSVExporter.fileName(scope: "  ", day: day) == "MFN-Umsaetze-2026-03-07.csv")
        #expect(TransactionCSVExporter.fileName(scope: ".hidden", day: day) == "MFN-hidden-2026-03-07.csv")
    }

    @Test func foreignCurrencyAndReferences() {
        let transaction = Transaction(
            accountID: "acc1", bookingDate: day, valueDate: day.adding(days: 1), amountCents: -2_000,
            counterpartName: "Shop", purpose: "Karte", eref: "E2E1", mref: "M1", creditorID: "DE00ZZZ00000000001",
            status: .booked, originalAmountCents: -2_150, originalCurrency: "USD", rawJSON: Data()
        )
        let row = lines(csv([transaction]))[1]
        #expect(row.hasSuffix(";E2E1;M1;DE00ZZZ00000000001;-21,50;USD;"))
        #expect(row.hasPrefix("07.03.2026;08.03.2026;"))
    }
}
