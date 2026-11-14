import Foundation
import MFNCore
import Testing
@testable import MFNEasybank

// Synthetic CSV only (no real export available yet). Names/merchants are placeholders.

@Suite struct CSVReaderTests {
    @Test func semicolonQuotedMultilineAndCRLF() throws {
        let csv = "a;b;c\r\n1;\"x;y\";\"he said \"\"hi\"\"\"\r\n2;\"line1\nline2\";\r\n\r\n"
        let rows = try CSVReader.rows(from: Data(csv.utf8))
        #expect(rows == [["a", "b", "c"], ["1", "x;y", "he said \"hi\""], ["2", "line1\nline2", ""]])
    }

    @Test func commaDelimiterAndBOM() throws {
        let rows = try CSVReader.rows(from: Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n1,2".utf8))
        #expect(rows == [["a", "b"], ["1", "2"]])
    }

    @Test func delimiterDetectedPastPreamble() throws {
        let rows = try CSVReader.rows(from: Data("Kartenumsätze\nDatum;Betrag;Händler\n01.11.2026;-1,00;X".utf8))
        #expect(rows.last == ["01.11.2026", "-1,00", "X"])
    }

    @Test func windows1252() throws {
        let data = try #require("Händler;Betrag\nCafé;1,00".data(using: .windowsCP1252))
        #expect(try CSVReader.rows(from: data) == [["Händler", "Betrag"], ["Café", "1,00"]])
    }

    @Test func unterminatedQuoteIsFormatChanged() {
        #expect(throws: ConnectorError.self) { try CSVReader.rows(from: Data("a;\"b\n".utf8)) }
    }
}

@Suite struct GermanFormatsTests {
    @Test(arguments: [
        ("-1.234,56", -123_456), ("1234,56", 123_456), ("−12,30 €", -1230), ("12,30-", -1230),
        ("+5,00", 500), ("EUR 7,5", 750), ("1234.56", 123_456), ("1.234", 123_400), ("0,01", 1),
        ("-0,99 EUR", -99), ("1.000.000,00", 100_000_000),
    ])
    func cents(_ text: String, _ expected: Int) {
        #expect(GermanFormats.cents(text) == expected)
    }

    @Test(arguments: ["", "abc", "1,234,5", "12,345", "1.2.3,4.5"])
    func invalidCents(_ text: String) {
        #expect(GermanFormats.cents(text) == nil)
    }

    @Test func days() {
        #expect(GermanFormats.day("08.11.2026") == BankDay(year: 2026, month: 11, day: 8))
        #expect(GermanFormats.day("08.11.26") == BankDay(year: 2026, month: 11, day: 8))
        #expect(GermanFormats.day("2026-11-08") == BankDay(year: 2026, month: 11, day: 8))
        #expect(GermanFormats.day("08.11.2026 14:03") == BankDay(year: 2026, month: 11, day: 8))
        #expect(GermanFormats.day("30.02.2026") == nil)
        #expect(GermanFormats.day("8/11/2026") == nil)
    }
}

@Suite struct EasybankCSVImporterTests {
    let card = Account(id: "easybank:test:card:1234", connectionID: "test", type: .card, name: "Visa", cardLast4: "1234", creditLimitCents: 300_000)

    static let export = """
    Kreditkartenumsätze;;;;;;
    Zeitraum: 01.10.2026 - 09.11.2026;;;;;;
    ;;;;;;
    Kartennummer;Transaktionsdatum;Buchungsdatum;Händler;Betrag;Originalbetrag;Status
    4111 **** **** 1234;05.11.2026;;Merchant Alpha;-12,50;;Vorgemerkt
    4111 **** **** 1234;01.11.2026;03.11.2026;Merchant Beta;-20,00;-21,90 USD;Gebucht
    4111 **** **** 5678;02.11.2026;04.11.2026;Partner Shop;-9,99;;Gebucht
    4111 **** **** 1234;28.10.2026;30.10.2026;Gutschrift Zahlung;300,00;;Gebucht
    4111 **** **** 1234;28.10.2026;30.10.2026;Gutschrift Zahlung;300,00;;Gebucht
    ;;;Summe;257,51;;
    """

    @Test func importsCardRowsWithStatusAndForeignCurrency() throws {
        let transactions = try EasybankCSVImporter().transactions(from: Data(Self.export.utf8), account: card)
        #expect(transactions.count == 5) // footer skipped, partner card kept

        let pending = transactions[0]
        #expect(pending.status == .pending)
        #expect(pending.bookingDate == nil)
        #expect(pending.valueDate == BankDay(year: 2026, month: 11, day: 5))
        #expect(pending.amountCents == -1250)
        #expect(pending.counterpartName == "Merchant Alpha")

        let fx = transactions[1]
        #expect(fx.status == .booked)
        #expect(fx.bookingDate == BankDay(year: 2026, month: 11, day: 3))
        #expect(fx.originalAmountCents == -2190)
        #expect(fx.originalCurrency == "USD")
        #expect(fx.currency == "EUR")

        // Two identical bookings: same fingerprint, distinct IDs.
        #expect(transactions[3].fingerprint == transactions[4].fingerprint)
        #expect(transactions[3].id != transactions[4].id)

        let raw = try #require(try JSONSerialization.jsonObject(with: fx.rawJSON) as? [String: String])
        #expect(raw["Händler"] == "Merchant Beta")
        #expect(transactions.allSatisfy { $0.accountID == card.id && $0.categoryID == nil })
    }

    @Test func partnerCardRowsBelongToTheCardAccount() throws {
        let transactions = try EasybankCSVImporter().transactions(from: Data(Self.export.utf8), account: card)
        #expect(transactions.contains { $0.counterpartName == "Partner Shop" })
    }

    @Test func idsAreFingerprintsAndStableAcrossImports() throws {
        let a = try EasybankCSVImporter().transactions(from: Data(Self.export.utf8), account: card)
        let b = try EasybankCSVImporter().transactions(from: Data(Self.export.utf8), account: card)
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.allSatisfy { $0.id.rawValue.hasPrefix("fp:\($0.fingerprint)") })
    }

    @Test func sameFingerprintAsBuilderPath() throws {
        let transactionDay = try #require(BankDay(year: 2026, month: 11, day: 1))
        // What the web connector will produce for the same booking (shared builder).
        let viaBuilder = EasybankTransactionBuilder.make(.init(
            accountID: card.id, status: .booked, bookingDate: BankDay(year: 2026, month: 11, day: 3),
            transactionDate: transactionDay, amountCents: -2000, currency: "EUR",
            merchant: "  Merchant   Beta ", details: nil, originalAmountCents: 2190, originalCurrency: "usd",
            externalID: nil, rawJSON: Data("{}".utf8)
        ))
        let viaCSV = try EasybankCSVImporter().transactions(from: Data(Self.export.utf8), account: card)[1]
        #expect(viaBuilder.fingerprint == viaCSV.fingerprint)
        #expect(viaBuilder.id == viaCSV.id)
        #expect(viaBuilder.originalAmountCents == -2190)
    }

    @Test func withoutStatusColumnMissingBookingDateMeansPending() throws {
        let csv = "Belegdatum;Buchungsdatum;Beschreibung;Betrag\n05.11.2026;;Merchant;-1,00\n01.11.2026;02.11.2026;Merchant;-2,00"
        let transactions = try EasybankCSVImporter().transactions(from: Data(csv.utf8), account: card)
        #expect(transactions.map(\.status) == [.pending, .booked])
    }

    @Test func unknownLayoutThrowsFormatChanged() {
        let csv = "Foo;Bar\n1;2"
        #expect(throws: ConnectorError.formatChanged(detail: "CSV: Kopfzeile nicht erkannt (Betrag, Datum oder Händler fehlt)")) {
            try EasybankCSVImporter().transactions(from: Data(csv.utf8), account: card)
        }
    }

    @Test func badCellsThrowWithoutValues() {
        let badAmount = "Datum;Händler;Betrag\n01.11.2026;Secret Merchant;zwölf"
        #expect(throws: ConnectorError.formatChanged(detail: "CSV Zeile 2: Betrag nicht lesbar")) {
            try EasybankCSVImporter().transactions(from: Data(badAmount.utf8), account: card)
        }
        let badStatus = "Datum;Händler;Betrag;Status\n01.11.2026;M;-1,00;Wunderlich"
        #expect(throws: ConnectorError.formatChanged(detail: "CSV Zeile 2: Status unbekannt")) {
            try EasybankCSVImporter().transactions(from: Data(badStatus.utf8), account: card)
        }
    }

    @Test func headerOnlyExportIsEmptyNotAnError() throws {
        let csv = "Datum;Händler;Betrag\n"
        #expect(try EasybankCSVImporter().transactions(from: Data(csv.utf8), account: card).isEmpty)
    }
}
