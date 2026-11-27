import Foundation
import Testing
@testable import MFNCore

/// Synthetic exports in the layouts of the presets. All names, IBANs (DE00…) and amounts are made up.
enum CSVSamples {
    static let ing = """
    Umsatzanzeige;Datei erstellt am: 16.11.2026 10:00
    ;Letztes Update: aktuell

    IBAN;DE00 1234 5678 9012 3456 78
    Kontoname;Girokonto
    Bank;ING
    Kunde;Erika Musterfrau
    Zeitraum;01.10.2026 - 16.11.2026
    Saldo;1.234,56;EUR

    Sortierung;Datum absteigend

    In der CSV-Datei finden Sie alle bereits gebuchten Umsätze.

    Buchung;Wertstellungsdatum;Auftraggeber/Empfänger;Buchungstext;Verwendungszweck;Saldo;Währung;Betrag;Währung
    14.11.2026;14.11.2026;Bäckerei Körner;Lastschrift;Brötchen und Kaffee;1.234,56;EUR;-7,40;EUR
    12.11.2026;13.11.2026;Muster GmbH;Gehalt/Rente;Gehalt November;1.241,96;EUR;2.500,00;EUR
    01.11.2026;01.11.2026;Hausverwaltung Beispiel;Dauerauftrag;Miete Wohnung 3;-1.258,04;EUR;-1.050,00;EUR

    """

    static let dkb = """
    "Konto";"Girokonto DE00120300001234567890"
    ""
    "Kontostand vom 16.11.2026:";"2.345,67 €"
    ""
    "Buchungsdatum";"Wertstellung";"Status";"Zahlungspflichtige*r";"Zahlungsempfänger*in";"Verwendungszweck";"Umsatztyp";"IBAN";"Betrag (€)";"Gläubiger-ID";"Mandatsreferenz";"Kundenreferenz"
    "15.11.26";"15.11.26";"Vorgemerkt";"Erika Musterfrau";"Tankstelle Nord";"Kartenzahlung";"Ausgang";"";"-45,00";"";"";""
    "13.11.26";"13.11.26";"Gebucht";"Erika Musterfrau";"Stadtwerke Beispielstadt";"Abschlag Strom 11/2026";"Ausgang";"DE00500105170000000001";"-89,00";"DE00ZZZ00000000001";"MANDAT-0001";"EREF-0001"
    "10.11.26";"10.11.26";"Gebucht";"Max Mustermann";"Erika Musterfrau";"Rückzahlung Konzertkarten";"Eingang";"DE00500105170000000002";"35,50";"";"";""

    """

    static let n26 = """
    "Booking Date","Value Date","Partner Name","Partner Iban",Type,"Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"
    2026-11-14,2026-11-14,"Coffee Corner",,Presentment,"-","Main Account",-3.5,-3.5,EUR,1.0
    2026-11-10,2026-11-10,"Bookshop London",,Presentment,"-","Main Account",-23.17,-20,GBP,1.1585
    2026-11-02,2026-11-02,"Max Mustermann",DE00100110012345678901,Credit Transfer,"Pizza","Main Account",1234.5,,,

    """

    static let mfn = """
    Buchungstag;Wertstellung;Status;Gegenpartei;IBAN Gegenkonto;Verwendungszweck;Betrag;Währung;Kategorie;Konto;IBAN Konto;Ende-zu-Ende-Referenz;Mandatsreferenz;Gläubiger-ID;Originalbetrag;Originalwährung;Kategorie-ID\r
    14.11.2026;14.11.2026;gebucht;Supermarkt Beispiel;;'-Einkauf 2;-1234,56;EUR;Lebensmittel;Demo Giro;DE00111122223333444455;;;;;;lebensmittel\r
    ;15.11.2026;vorgemerkt;Tankstelle;;Karte;-50,00;EUR;;Demo Giro;DE00111122223333444455;;;;;;\r
    13.11.2026;13.11.2026;gebucht;"Name; mit Semikolon";;"Zweck mit ""Anführung""\";100,00;EUR;;Demo Giro;DE00111122223333444455;;;;;;\r
    12.11.2026;12.11.2026;gebucht;Andere Bank;;Umbuchung;-5,00;EUR;;Demo Tagesgeld;;;;;;;\r

    """

    static let sollHaben = """
    Datum;Empfänger/Auftraggeber;Verwendungszweck;Soll;Haben
    03.11.2026;Versicherung AG;Beitrag;1.200,00;
    04.11.2026;Muster GmbH;Erstattung;;12.345,67
    Summe;;;1.200,00;12.345,67

    """

    static let mark = """
    Buchungstag;Name;Zweck;Umsatz;Soll/Haben
    03.11.2026;Versicherung AG;Beitrag;99,90;S
    04.11.2026;Muster GmbH;Erstattung;10,00;H

    """
}

@Suite struct CSVImportTests {
    let account = Account(id: "acc-1", connectionID: "conn-1", type: .giro, name: "Giro")

    private func document(_ text: String, encoding: String.Encoding = .utf8, bom: Bool = false) throws -> CSVDocument {
        var data = Data(bom ? [0xEF, 0xBB, 0xBF] : [])
        data.append(try #require(text.data(using: encoding)))
        return try CSVDocument(data: data)
    }

    // MARK: Reader

    @Test func encodingDetection() throws {
        let text = "Datum;Name;Betrag\n01.11.2026;Bäckerei Körner;-1,00\n"
        let utf8 = try document(text)
        #expect(utf8.table.encoding == .utf8)
        let bom = try document(text, bom: true)
        #expect(bom.table.encoding == .utf8BOM)
        #expect(bom.table.rows[0][0] == "Datum", "BOM removed")
        let latin = try document(text, encoding: .windowsCP1252)
        #expect(latin.table.encoding == .windows1252)
        #expect(latin.table.rows[1][1] == "Bäckerei Körner")
        let utf16 = try document(text, encoding: .utf16)
        #expect(utf16.table.encoding == .utf16)
        #expect(utf16.table.rows[1][1] == "Bäckerei Körner")
    }

    @Test func delimiterDetectionAndQuoting() throws {
        #expect(try document(CSVSamples.n26).table.delimiter == .comma)
        #expect(try document("a\tb\tc\n1\t2\t3\n").table.delimiter == .tab)
        let mfn = try document(CSVSamples.mfn, bom: true)
        #expect(mfn.table.delimiter == .semicolon)
        #expect(mfn.table.rows[3][3] == "Name; mit Semikolon")
        #expect(mfn.table.rows[3][5] == "Zweck mit \"Anführung\"")
    }

    @Test func utf16KeepsZeroWidthNoBreakSpaceInsideTheText() throws {
        let utf16 = try document("Datum;Name\n01.11.2026;A\u{FEFF}B\n", encoding: .utf16)
        #expect(utf16.table.rows[0][0] == "Datum", "leading BOM removed")
        #expect(utf16.table.rows[1][1] == "A\u{FEFF}B")
    }

    @Test func quotesOpenOnlyAtTheStartOfAField() throws {
        let table = try CSVParser.parse(Data("a;  \"x;y\" ;b\"c\"\r\n\"\"\"q\"\"\";\"\"\r1;2;3".utf8))
        #expect(table.rows == [["a", "x;y", "b\"c\""], ["\"q\"", ""], ["1", "2", "3"]])
        #expect(table.lines == [1, 2, 3])
    }

    @Test func multilineQuotedFieldKeepsLineNumbers() throws {
        let doc = try document("Datum;Name;Zweck;Betrag\n01.11.2026;A;\"Zeile 1\nZeile 2\";-1,00\n02.11.2026;B;x;kaputt\n")
        let result = doc.transactions(for: account)
        #expect(result.transactions.first?.purpose == "Zeile 1\nZeile 2")
        #expect(result.skipped == [CSVSkippedRow(line: 4, reason: .unreadableAmount)])
    }

    @Test func unclosedQuoteThrows() {
        #expect(throws: CSVImportError.unclosedQuote(line: 2)) { try CSVParser.parse(Data("a;b\n\"x;1\n".utf8)) }
        #expect(throws: CSVImportError.empty) { try CSVParser.parse(Data("\n\n".utf8)) }
    }

    // MARK: Values

    @Test func amounts() {
        #expect(CSVValues.cents("-1.234,56") == -123_456)
        #expect(CSVValues.cents("1234,5") == 123_450)
        #expect(CSVValues.cents("12,30-") == -1_230)
        #expect(CSVValues.cents("−7,00 €") == -700)
        #expect(CSVValues.cents("(12,30)") == -1_230)
        #expect(CSVValues.cents("1.000") == 100_000, "dot is grouping with decimal comma")
        #expect(CSVValues.cents("12.5") == nil, "not a German amount")
        #expect(CSVValues.cents("-1,234.56", decimal: .point) == -123_456)
        #expect(CSVValues.cents("-3.5", decimal: .point) == -350)
        #expect(CSVValues.cents("1.2.3,00") == nil)
        #expect(CSVValues.cents("abc") == nil)
        #expect(CSVValues.cents("") == nil)
    }

    @Test func amountsWithDebitCreditMarkers() {
        #expect(CSVValues.cents("12,30 S") == -1_230)
        #expect(CSVValues.cents("12,30 H") == 1_230)
        #expect(CSVValues.cents("1.234,56 Soll") == -123_456)
        #expect(CSVValues.cents("7,00 haben") == 700)
        #expect(CSVValues.cents("12.30 DR", decimal: .point) == -1_230)
        #expect(CSVValues.cents("12.30 CR", decimal: .point) == 1_230)
        #expect(CSVValues.cents("12,30 EUR S") == -1_230)
        #expect(CSVValues.cents("-12,30 H") == 1_230, "the marker decides the sign")
        #expect(CSVValues.cents("12,30S") == -1_230)
    }

    @Test func amountsRejectStrayLetters() {
        #expect(CSVValues.cents("EUR 7,5") == 750)
        #expect(CSVValues.cents("7,50 usd") == 750)
        #expect(CSVValues.cents("12,30 X") == nil)
        #expect(CSVValues.cents("1O,00") == nil, "letter O instead of zero")
        #expect(CSVValues.cents("12,30 Euro") == nil)
        #expect(CSVValues.cents("S") == nil)
    }

    @Test func amountsAreCapped() {
        #expect(CSVValues.cents("100.000.000.000,00") == CSVValues.maximumAbsoluteCents)
        #expect(CSVValues.cents("-100.000.000.000,00") == -CSVValues.maximumAbsoluteCents)
        #expect(CSVValues.cents("100.000.000.000,01") == nil)
        #expect(CSVValues.cents("92233720368547758,07") == nil)
    }

    @Test func dates() {
        #expect(CSVValues.day("14.11.2026") == BankDay(year: 2026, month: 11, day: 14))
        #expect(CSVValues.day("14.11.26") == BankDay(year: 2026, month: 11, day: 14))
        #expect(CSVValues.day("2026-11-14") == BankDay(year: 2026, month: 11, day: 14))
        #expect(CSVValues.day("1.2.2026 12:00") == BankDay(year: 2026, month: 2, day: 1))
        #expect(CSVValues.day("31.02.2026") == nil)
        #expect(CSVValues.day("Summe") == nil)
    }

    @Test func decimalSeparatorDetection() {
        #expect(CSVValues.detectDecimalSeparator(["-3.5", "-23.17", "1234.5"]) == .point)
        #expect(CSVValues.detectDecimalSeparator(["-7,40", "2.500,00"]) == .comma)
        #expect(CSVValues.detectDecimalSeparator(["12", "1.000"]) == .comma)
    }

    // MARK: Presets

    @Test func ingMetadataAboveHeader() throws {
        let doc = try document(CSVSamples.ing, encoding: .windowsCP1252)
        #expect(doc.table.encoding == .windows1252)
        #expect(doc.preset == .ing)
        #expect(doc.headerRow == 10, "empty lines are not rows")
        #expect(doc.mapping[.currency] == 8, "the currency next to the amount, not the balance's")
        let result = doc.transactions(for: account)
        #expect(result.skipped.isEmpty)
        #expect(result.transactions.map(\.amountCents) == [-740, 250_000, -105_000])
        let salary = result.transactions[1]
        #expect(salary.counterpartName == "Muster GmbH")
        #expect(salary.purpose == "Gehalt November")
        #expect(salary.bookingDate == BankDay(year: 2026, month: 11, day: 12))
        #expect(salary.valueDate == BankDay(year: 2026, month: 11, day: 13))
        #expect(salary.status == .booked)
        #expect(salary.id.rawValue.hasPrefix("fp:"))
    }

    @Test func dkbPayerPayeeAndStatus() throws {
        let doc = try document(CSVSamples.dkb, bom: true)
        #expect(doc.preset == .dkb)
        let result = doc.transactions(for: account)
        #expect(result.skipped.map(\.reason) == [.notBooked])
        let power = try #require(result.transactions.first)
        #expect(power.counterpartName == "Stadtwerke Beispielstadt", "payee of an outflow")
        #expect(power.counterpartIBAN == "DE00500105170000000001")
        #expect(power.creditorID == "DE00ZZZ00000000001")
        #expect(power.mref == "MANDAT-0001")
        #expect(power.eref == "EREF-0001")
        #expect(power.amountCents == -8_900)
        #expect(result.transactions[1].counterpartName == "Max Mustermann", "payer of an inflow")
        #expect(result.transactions[1].amountCents == 3_550)
    }

    @Test func n26DecimalPointAndForeignCurrency() throws {
        let doc = try document(CSVSamples.n26)
        #expect(doc.preset == .n26)
        #expect(doc.decimalSeparator == .point)
        let result = doc.transactions(for: account)
        #expect(result.transactions.map(\.amountCents) == [-350, -2_317, 123_450])
        #expect(result.transactions[0].originalAmountCents == nil, "same as the amount")
        #expect(result.transactions[1].originalAmountCents == -2_000)
        #expect(result.transactions[1].originalCurrency == "GBP")
        #expect(result.transactions[2].counterpartIBAN == "DE00100110012345678901")
        #expect(result.transactions[2].purpose == "Pizza")
    }

    @Test func mfnExportRoundTrip() throws {
        let doc = try document(CSVSamples.mfn, bom: true)
        #expect(doc.preset == .mfn)
        #expect(doc.accountValues == ["Demo Giro", "Demo Tagesgeld"])
        #expect(doc.accountFilter == "Demo Giro")
        let result = doc.transactions(for: account)
        #expect(result.skipped.map(\.reason) == [.notBooked, .otherAccount], "pending row without booking day is not a date error")
        let first = try #require(result.transactions.first)
        #expect(first.purpose == "-Einkauf 2", "formula guard quote removed")
        #expect(first.amountCents == -123_456)
        #expect(first.categoryID == "lebensmittel")
        #expect(first.categorySource == .manual)
        #expect(first.counterpartIBAN == nil, "IBAN Konto is the own account, not the counterpart")
        #expect(result.transactions[1].counterpartName == "Name; mit Semikolon")
    }

    @Test func mfnExporterOutputImports() throws {
        // What `TransactionCSVExporter` writes (see its documentation), produced by hand here.
        let day = BankDay(year: 2026, month: 11, day: 3)!
        let original = Transaction(accountID: account.id, bookingDate: day, valueDate: day, amountCents: -4_200,
                                   counterpartName: "=Formel", counterpartIBAN: "DE00 1111 2222 3333 4444 55",
                                   purpose: "Test 1", status: .booked)
        let text = "Buchungstag;Wertstellung;Status;Gegenpartei;IBAN Gegenkonto;Verwendungszweck;Betrag;Währung;Kategorie;Konto\r\n"
            + "03.11.2026;03.11.2026;gebucht;'=Formel;DE00111122223333444455;Test 1;-42,00;EUR;;Giro\r\n"
        let imported = try document(text, bom: true).transactions(for: account).transactions
        #expect(imported.first?.counterpartName == "=Formel")
        #expect(imported.first?.fingerprint == original.fingerprint)
        #expect(imported.first?.id == original.id)
    }

    @Test func sollHabenColumns() throws {
        let doc = try document(CSVSamples.sollHaben)
        #expect(doc.preset == nil)
        #expect(doc.mapping[.debit] == 3)
        #expect(doc.mapping[.credit] == 4)
        let result = doc.transactions(for: account)
        #expect(result.transactions.map(\.amountCents) == [-120_000, 1_234_567])
        #expect(result.skipped.isEmpty, "the sum line has no date and is skipped silently")
    }

    @Test func debitCreditMark() throws {
        let result = try document(CSVSamples.mark).transactions(for: account)
        #expect(result.transactions.map(\.amountCents) == [-9_990, 1_000])
    }

    @Test func noHeaderMeansManualMapping() throws {
        var doc = try document("01.11.2026;Laden;-1,00\n02.11.2026;Laden;-2,00\n")
        #expect(doc.headerRow == nil)
        #expect(!doc.mapping.isComplete)
        #expect(doc.columnNames == (1...3).map { String(localized: "Spalte \($0)", bundle: .module) })
        #expect(doc.transactions(for: account).transactions.isEmpty)
        doc.mapping = CSVMapping([.bookingDate: 0, .counterparty: 1, .amount: 2])
        #expect(doc.transactions(for: account).transactions.map(\.amountCents) == [-100, -200])
    }

    @Test func identicalRowsGetDistinctStableIDs() throws {
        let text = "Datum;Name;Betrag\n01.11.2026;Kaffee;-3,00\n01.11.2026;Kaffee;-3,00\n"
        let first = try document(text).transactions(for: account).transactions
        let second = try document(text).transactions(for: account).transactions
        #expect(Set(first.map(\.id)).count == 2)
        #expect(first.map(\.id) == second.map(\.id))
    }

    // MARK: Dedup and merge

    @Test func reimportFindsOnlyDuplicates() throws {
        let doc = try document(CSVSamples.ing, encoding: .windowsCP1252)
        let incoming = doc.transactions(for: account).transactions
        var ledger = LedgerSnapshot()
        ledger.apply(CSVImportPlan.merge(CSVImportPlan.make(incoming: incoming, stored: []).new, into: []))
        #expect(ledger.transactions.count == 3)

        let again = CSVImportPlan.make(incoming: incoming, stored: ledger.transactions(of: account.id))
        #expect(again.new.isEmpty)
        #expect(again.duplicates.count == 3)
    }

    @Test func duplicatesCountedPerFingerprint() throws {
        let text = "Datum;Name;Betrag\n01.11.2026;Kaffee;-3,00\n01.11.2026;Kaffee;-3,00\n"
        let incoming = try document(text).transactions(for: account).transactions
        let stored = [incoming[0]]
        let plan = CSVImportPlan.make(incoming: incoming, stored: stored)
        #expect(plan.duplicates.count == 1)
        #expect(plan.new.count == 1)
    }

    @Test func syncedBookingWithExternalIDIsDuplicateByFingerprint() throws {
        let day = BankDay(year: 2026, month: 11, day: 14)!
        let synced = Transaction(accountID: account.id, bookingDate: day, valueDate: day, amountCents: -740,
                                 counterpartName: "Bäckerei Körner", purpose: "Brötchen und  Kaffee", status: .booked, externalID: "bank-1")
        let incoming = try document(CSVSamples.ing, encoding: .windowsCP1252).transactions(for: account).transactions
        let plan = CSVImportPlan.make(incoming: incoming, stored: [synced])
        #expect(plan.duplicates.count == 1)
        #expect(plan.new.count == 2)
    }

    @Test func likelyDuplicateWhenPurposeDiffers() throws {
        let day = BankDay(year: 2026, month: 11, day: 14)!
        let synced = Transaction(accountID: account.id, bookingDate: day, valueDate: day, amountCents: -740,
                                 counterpartName: "BÄCKEREI KÖRNER SAGT DANKE", purpose: "SVWZ+Broetchen", status: .booked)
        let synced2 = Transaction(accountID: account.id, bookingDate: day, valueDate: day, amountCents: -740,
                                  counterpartName: "Bäckerei Körner Filiale 2", purpose: "Lastschrift", status: .booked)
        let incoming = try document(CSVSamples.ing, encoding: .windowsCP1252).transactions(for: account).transactions
        let plan = CSVImportPlan.make(incoming: incoming, stored: [synced, synced2])
        #expect(plan.likelyDuplicates.count == 1)
        #expect(plan.new.count == 2)
        #expect(plan.transactionsToImport(includingLikelyDuplicates: true).count == 3)
    }

    @Test func importResolvesStoredPendingAndKeepsOtherPending() throws {
        let booked = try document(CSVSamples.ing, encoding: .windowsCP1252).transactions(for: account).transactions
        var pending = Transaction(accountID: account.id, bookingDate: nil, valueDate: BankDay(year: 2026, month: 11, day: 13)!,
                                  amountCents: -740, counterpartName: "Bäckerei Körner", purpose: "", status: .pending)
        pending.categoryID = "lebensmittel"
        pending.categorySource = .manual
        let unrelated = Transaction(accountID: account.id, bookingDate: nil, valueDate: BankDay(year: 2026, month: 11, day: 15)!,
                                    amountCents: -999, counterpartName: "Kino", purpose: "", status: .pending)
        let stored = [pending, unrelated]
        let plan = CSVImportPlan.make(incoming: booked, stored: stored)
        #expect(plan.new.count == 3)
        let merge = CSVImportPlan.merge(plan.new, into: stored)
        #expect(merge.deletions == [pending.id], "only the resolved reservation goes, the unrelated one stays")
        #expect(merge.upserts.first { $0.amountCents == -740 }?.categoryID == "lebensmittel")
    }

    @Test func mergeNeverReplacesStoredIDs() {
        let day = BankDay(year: 2026, month: 11, day: 1)!
        let a = Transaction(accountID: account.id, bookingDate: day, valueDate: day, amountCents: -1, counterpartName: "A", purpose: "x", status: .booked)
        let clash = a.withID(TransactionID("\(a.id.rawValue)#2"))
        // Stored: a and something that took "#2". Importing a second "a" must not overwrite it.
        let stored = [a, clash]
        let merge = CSVImportPlan.merge([clash], into: stored)
        #expect(merge.upserts.map(\.id.rawValue) == ["\(a.id.rawValue)#3"])
        #expect(merge.deletions.isEmpty)
    }
}
