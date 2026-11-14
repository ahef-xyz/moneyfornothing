import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNFinTS

/// Synthetic MT940 – structure as ING delivers it, all data invented (IBANs use the `DE00` test prefix).
enum SyntheticMT940 {
    static let twoStatements = """
    :20:STARTUMSE
    :25:50010517/0000000000
    :28C:00000/001
    :60F:C261020EUR1000,00
    :61:2610211021DR12,50NDDTNONREF
    :86:105?00Lastschrift?100001?20EREF+E2E-0001 MREF+M-77?21CRED+DE98ZZZ09999999999?22SVWZ+Rechnung 4711 Strom Ok?23tober?30TESTDEFFXXX?31DE00123400001234567890?32Stadtwerke Müllheim GmbH
    :61:2610221022CR2500,00NMSCNONREF//BANKREF1
    :86:166?00Gutschrift?20SVWZ+Gehalt Oktober?30TESTDEFFXXX?31DE00999900009876543210?32Arbeitgeber AG?33Niederlassung Süd
    :62F:C261022EUR3487,50
    -
    :20:STARTUMSE
    :25:50010517/0000000000
    :28C:00000/002
    :60F:C261022EUR3487,50
    :61:2610231023DR3,20NMSCNONREF
    :86:106?00Kartenzahlung?20VISA Bäckerei Köhler? 1?21 Stück
    :61:2610241024RD12,50NDDTNONREF
    :86:109?00Rücklastschrift?20SVWZ+Rueckgabe?32Stadtwerke Müllheim GmbH
    :62F:C261024EUR3496,80
    -
    """

    static func data(_ text: String, latin1: Bool = true) -> Data {
        let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
        return latin1 ? (crlf.data(using: .isoLatin1) ?? Data()) : Data(crlf.utf8)
    }
}

@Suite struct MT940ParserTests {
    @Test func parsesMultipleStatementsWithUmlautsAndSEPATags() throws {
        let statements = try MT940Parser.parse(SyntheticMT940.data(SyntheticMT940.twoStatements))
        #expect(statements.count == 2)
        let first = statements[0]
        #expect(first.statementNumber == "00000/001")
        #expect(first.openingBalance == MT940Balance(date: BankDay(year: 2026, month: 10, day: 20)!, currency: "EUR", amountCents: 100_000))
        #expect(first.closingBalance?.amountCents == 348_750)
        #expect(first.currency == "EUR")
        #expect(first.entries.count == 2)

        let debit = first.entries[0]
        #expect(debit.amountCents == -1250)
        #expect(debit.valueDate == BankDay(year: 2026, month: 10, day: 21))
        #expect(debit.entryDate == BankDay(year: 2026, month: 10, day: 21))
        #expect(debit.fundsCode == "R")
        #expect(debit.transactionType == "NDDT")
        #expect(debit.customerReference == "NONREF")
        let details = try #require(debit.details)
        #expect(details.transactionCode == "105")
        #expect(details.postingText == "Lastschrift")
        #expect(details.primanota == "0001")
        #expect(details.counterpartName == "Stadtwerke Müllheim GmbH")
        #expect(details.counterpartAccount == "DE00123400001234567890")
        #expect(details.counterpartBIC == "TESTDEFFXXX")
        #expect(details.endToEndReference == "E2E-0001")
        #expect(details.mandateReference == "M-77")
        #expect(details.creditorID == "DE98ZZZ09999999999")
        // ?22/?23 wrap mid-word: joined without separator.
        #expect(details.purpose == "Rechnung 4711 Strom Oktober")

        let credit = first.entries[1]
        #expect(credit.amountCents == 250_000)
        #expect(credit.bankReference == "BANKREF1")
        #expect(credit.details?.counterpartName == "Arbeitgeber AGNiederlassung Süd")
    }

    @Test func unstructuredPurposeWithLoneQuestionMarkAndReversal() throws {
        let statements = try MT940Parser.parse(SyntheticMT940.data(SyntheticMT940.twoStatements))
        let entries = statements[1].entries
        #expect(entries.count == 2)
        #expect(entries[0].amountCents == -320)
        #expect(entries[0].details?.purpose == "VISA Bäckerei Köhler? 1 Stück")
        #expect(entries[0].details?.sepa.isEmpty == true)
        // RD = reversal of a debit → money comes back.
        #expect(entries[1].isReversal)
        #expect(entries[1].amountCents == 1250)
    }

    @Test func acceptsUTF8AndAtAtSeparators() throws {
        let utf8 = try MT940Parser.parse(SyntheticMT940.data(SyntheticMT940.twoStatements, latin1: false))
        #expect(utf8[0].entries[0].details?.counterpartName == "Stadtwerke Müllheim GmbH")
        let atAt = SyntheticMT940.twoStatements.replacingOccurrences(of: "\n", with: "@@")
        let parsed = try MT940Parser.parse(atAt)
        #expect(parsed.flatMap(\.entries).count == 4)
    }

    @Test func multiLine86AndSupplementaryDetails() throws {
        let text = """
        :20:X
        :25:50010517/0000000000
        :28C:1
        :60F:D261231EUR5,00
        :61:2612310102DR1,00NMSCNONREF
        /OCMT/EUR1,00/
        :86:177?00Ueberweisung?20SVWZ+Miete Januar 2027 Woh
        ?21nung 3 OG?32Vermieterin
        :62F:D270102EUR6,00
        -
        """
        let statement = try #require(try MT940Parser.parse(text).first)
        #expect(statement.openingBalance?.amountCents == -500)
        let entry = try #require(statement.entries.first)
        // Entry date 01-02 belongs to the next year (value date 2026-12-31).
        #expect(entry.entryDate == BankDay(year: 2027, month: 1, day: 2))
        #expect(entry.supplementaryDetails == "/OCMT/EUR1,00/")
        #expect(entry.details?.purpose == "Miete Januar 2027 Wohnung 3 OG")
        #expect(entry.details?.counterpartName == "Vermieterin")
    }

    @Test func amountsNeverUseFloatingPoint() {
        #expect(MT940Text.cents("0,1") == 10)
        #expect(MT940Text.cents("1234,") == 123_400)
        #expect(MT940Text.cents("1234") == 123_400)
        #expect(MT940Text.cents("0,07") == 7)
        #expect(MT940Text.cents("19999999,99") == 1_999_999_999)
        #expect(MT940Text.cents("1,005") == 100)
        #expect(MT940Text.cents("1,015") == 102)
        #expect(MT940Text.cents("1,0051") == 101)
        #expect(MT940Text.cents("") == nil)
        #expect(MT940Text.cents("1.5") == nil)
    }

    @Test func malformedLinesThrowWithoutContent() {
        #expect(throws: MT940Error.self) {
            try MT940Parser.parse(":20:X\n:61:26AB01CR1,00NMSCNONREF\n-")
        }
        do {
            _ = try MT940Parser.parse(":20:X\n:60F:C261020EURabc\n-")
            Issue.record("expected error")
        } catch {
            #expect(!error.description.contains("EURabc"))
            #expect(error.connectorError == .formatChanged(detail: error.description))
        }
    }

    @Test func realFixtureParsesIfPresent() throws {
        guard Fixtures.exists(.ing, "mt940-giro.sta") else { return }
        let statements = try MT940Parser.parse(Fixtures.data(.ing, "mt940-giro.sta"))
        #expect(!statements.flatMap(\.entries).isEmpty)
    }
}
