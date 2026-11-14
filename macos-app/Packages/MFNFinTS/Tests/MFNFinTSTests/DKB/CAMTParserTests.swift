import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNFinTS

@Suite struct CAMTParserTests {
    let account: AccountID = "dkb-test-giro"

    /// Hand-written camt.052.001.02 report (synthetic data).
    let report02 = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.052.001.02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <BkToCstmrAcctRpt>
        <GrpHdr><MsgId>M-1</MsgId><CreDtTm>2026-11-09T07:30:00+01:00</CreDtTm></GrpHdr>
        <Rpt>
          <Id>R-1</Id>
          <Acct><Id><IBAN>DE00120300001234567890</IBAN></Id></Acct>
          <Ntry>
            <Amt Ccy="EUR">45.9</Amt>
            <CdtDbtInd>DBIT</CdtDbtInd>
            <Sts>BOOK</Sts>
            <BookgDt><Dt>2026-11-02</Dt></BookgDt>
            <ValDt><Dt>2026-11-03</Dt></ValDt>
            <AcctSvcrRef>REF-1</AcctSvcrRef>
            <NtryDtls><TxDtls>
              <Refs><EndToEndId>E2E-1</EndToEndId><MndtId>MANDAT-1</MndtId></Refs>
              <RltdPties>
                <Dbtr><Nm>Erika Muster</Nm></Dbtr>
                <Cdtr><Nm>Stadtwerke Muster</Nm><Id><PrvtId><Othr><Id>DE98ZZZ09999999999</Id></Othr></PrvtId></Id></Cdtr>
                <CdtrAcct><Id><IBAN>DE00 7005 0000 0000 0000 02</IBAN></Id></CdtrAcct>
              </RltdPties>
              <RmtInf><Ustrd>Abschlag Strom</Ustrd><Ustrd>Kd-Nr. 4711 &amp; mehr</Ustrd></RmtInf>
            </TxDtls></NtryDtls>
          </Ntry>
          <Ntry>
            <Amt Ccy="EUR">2500</Amt>
            <CdtDbtInd>CRDT</CdtDbtInd>
            <Sts>BOOK</Sts>
            <BookgDt><Dt>2026-10-30</Dt></BookgDt>
            <ValDt><Dt>2026-10-30</Dt></ValDt>
            <NtryDtls><TxDtls>
              <Refs><EndToEndId>NOTPROVIDED</EndToEndId></Refs>
              <RltdPties><Dbtr><Nm>Arbeitgeber GmbH</Nm></Dbtr><DbtrAcct><Id><IBAN>DE00500105170000000001</IBAN></Id></DbtrAcct></RltdPties>
              <RmtInf><Ustrd>LOHN/GEHALT 10/2026</Ustrd></RmtInf>
            </TxDtls></NtryDtls>
          </Ntry>
          <Ntry>
            <Amt Ccy="EUR">23.45</Amt>
            <CdtDbtInd>DBIT</CdtDbtInd>
            <Sts>PDNG</Sts>
            <ValDt><Dt>2026-11-08</Dt></ValDt>
            <AddtlNtryInf>Kartenzahlung</AddtlNtryInf>
          </Ntry>
        </Rpt>
      </BkToCstmrAcctRpt>
    </Document>
    """.utf8)

    @Test func mapsBookedDirectDebit() throws {
        let transactions = try CAMTParser.parse(report02, accountID: account)
        #expect(transactions.count == 3)
        let debit = transactions[0]
        #expect(debit.amountCents == -4590)
        #expect(debit.currency == "EUR")
        #expect(debit.status == .booked)
        #expect(debit.bookingDate == BankDay(iso: "2026-11-02"))
        #expect(debit.valueDate == BankDay(iso: "2026-11-03"))
        #expect(debit.counterpartName == "Stadtwerke Muster")
        #expect(debit.counterpartIBAN == "DE00700500000000000002")
        #expect(debit.purpose == "Abschlag Strom Kd-Nr. 4711 & mehr")
        #expect(debit.eref == "E2E-1")
        #expect(debit.mref == "MANDAT-1")
        #expect(debit.creditorID == "DE98ZZZ09999999999")
        #expect(debit.externalID == nil)
        #expect(debit.accountID == account)
    }

    @Test func creditUsesDebtorAndDropsNotProvided() throws {
        let credit = try CAMTParser.parse(report02, accountID: account)[1]
        #expect(credit.amountCents == 250_000)
        #expect(credit.counterpartName == "Arbeitgeber GmbH")
        #expect(credit.counterpartIBAN == "DE00500105170000000001")
        #expect(credit.eref == nil)
        #expect(credit.creditorID == nil)
    }

    @Test func pendingHasNoBookingDate() throws {
        let pending = try CAMTParser.parse(report02, accountID: account)[2]
        #expect(pending.status == .pending)
        #expect(pending.bookingDate == nil)
        #expect(pending.valueDate == BankDay(iso: "2026-11-08"))
        #expect(pending.purpose == "Kartenzahlung")
        #expect(pending.counterpartName == "Kartenzahlung")
    }

    @Test func rawJSONKeepsTheEntry() throws {
        let debit = try CAMTParser.parse(report02, accountID: account)[0]
        let object = try #require(try JSONSerialization.jsonObject(with: debit.rawJSON) as? [String: Any])
        let entry = try #require(object["Ntry"] as? [String: Any])
        #expect(entry["AcctSvcrRef"] as? String == "REF-1")
        let amount = try #require(entry["Amt"] as? [String: Any])
        #expect(amount["@Ccy"] as? String == "EUR")
        #expect(amount["#text"] as? String == "45.9")
        // Deterministic: same input, same bytes (fingerprint and storage stay stable).
        #expect(try CAMTParser.parse(report02, accountID: account)[0].rawJSON == debit.rawJSON)
    }

    @Test func version08StatusCodeAndPartyWrapper() throws {
        let data = camt([
            CAMTEntry(amount: "11.20", debit: true, booking: "2026-11-01", name: "UBER TRIP", purpose: ["UBER *TRIP"], mref: "M-9", creditorID: "DE11ZZZ00000000001", instructed: ("12.00", "USD")),
            CAMTEntry(amount: "59.99", debit: true, status: "PDNG", booking: nil, value: "2026-11-07", name: "AMAZON", purpose: ["AMAZON MKTPLACE"]),
            CAMTEntry(amount: "1.00", debit: true, status: "INFO", booking: nil, value: "2026-11-20", name: "Planung", purpose: ["Dauerauftrag"]),
        ], v08: true)
        let transactions = try CAMTParser.parse(data, accountID: account)
        #expect(transactions.map(\.status) == [.booked, .pending, .planned])
        #expect(transactions[0].counterpartName == "UBER TRIP")
        #expect(transactions[0].creditorID == "DE11ZZZ00000000001")
        #expect(transactions[0].originalAmountCents == -1200)
        #expect(transactions[0].originalCurrency == "USD")
        #expect(transactions[1].bookingDate == nil)
        #expect(transactions[2].bookingDate == nil)
        #expect(transactions[2].valueDate == BankDay(iso: "2026-11-20"))
    }

    @Test func defaultStatusAppliesWithoutSts() throws {
        let xml = Data("""
        <Document><BkToCstmrAcctRpt><Rpt><Ntry><Amt Ccy="EUR">5.00</Amt><CdtDbtInd>DBIT</CdtDbtInd>
        <ValDt><Dt>2026-11-08</Dt></ValDt></Ntry></Rpt></BkToCstmrAcctRpt></Document>
        """.utf8)
        #expect(try CAMTParser.parse(xml, accountID: account, defaultStatus: .pending).first?.status == .pending)
        let booked = try #require(try CAMTParser.parse(xml, accountID: account, defaultStatus: .booked).first)
        #expect(booked.bookingDate == BankDay(iso: "2026-11-08"))
    }

    @Test func fingerprintIgnoresWrapping() throws {
        let a = try CAMTParser.parse(camt([CAMTEntry(amount: "3.00", debit: true, booking: "2026-11-02", name: "X", purpose: ["Rechnung 12", "34 vom Oktober"])]), accountID: account)
        let b = try CAMTParser.parse(camt([CAMTEntry(amount: "3.00", debit: true, booking: "2026-11-02", name: "X", purpose: ["Rechnung 1234 vom Oktober"])]), accountID: account)
        #expect(a[0].fingerprint == b[0].fingerprint)
    }

    @Test func brokenDocumentsThrowFormatChanged() {
        let cases = [
            "<Document><BkToCstmrAcctRpt><Rpt><Ntry><Amt>",
            "<Document><Other/></Document>",
            "<Document><BkToCstmrAcctRpt><Rpt><Ntry><Amt Ccy=\"EUR\">1,00</Amt><CdtDbtInd>DBIT</CdtDbtInd></Ntry></Rpt></BkToCstmrAcctRpt></Document>",
            "<Document><BkToCstmrAcctRpt><Rpt><Ntry><Amt Ccy=\"EUR\">1.00</Amt></Ntry></Rpt></BkToCstmrAcctRpt></Document>",
            "<Document><BkToCstmrAcctRpt><Rpt><Ntry><Amt Ccy=\"EUR\">1.00</Amt><CdtDbtInd>DBIT</CdtDbtInd></Ntry></Rpt></BkToCstmrAcctRpt></Document>",
        ]
        for xml in cases {
            #expect(throws: ConnectorError.self) { try CAMTParser.parse(Data(xml.utf8), accountID: account) }
        }
    }

    @Test(arguments: [("12.34", 1234), ("12.3", 1230), ("12", 1200), ("0.05", 5), (".5", 50), ("1000000.00", 100_000_000)])
    func centsAreExact(text: String, cents: Int) {
        #expect(CAMTParser.cents(text) == cents)
    }

    @Test(arguments: ["", "-1.00", "1.234", "1,00", "abc", "1.2.3"])
    func invalidAmountsAreRejected(text: String) {
        #expect(CAMTParser.cents(text) == nil)
    }

    /// Runs against the human-provided fixture once it exists (Fixtures/DKB/README.md).
    @Test(.enabled(if: Fixtures.exists(.dkb, "camt052-giro.xml")))
    func parsesRecordedFixture() throws {
        let transactions = try CAMTParser.parse(try Fixtures.data(.dkb, "camt052-giro.xml"), accountID: account)
        #expect(!transactions.isEmpty)
        for transaction in transactions {
            #expect((transaction.status == .booked) == (transaction.bookingDate != nil))
        }
    }
}
