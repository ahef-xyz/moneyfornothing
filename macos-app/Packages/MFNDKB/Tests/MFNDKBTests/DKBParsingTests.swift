import Foundation
import MFNCore
import Testing
@testable import MFNDKB

@Suite struct DKBParsingTests {
    private let account = Account(id: "dkbweb-test", connectionID: TestValues.connection, type: .giro, name: "Girokonto")

    @Test func accountListMapsToGiroAccounts() throws {
        let list = try JSONDecoder().decode(DKBAccountList.self, from: DKBFixtures.data("accounts.json"))
        let entries = try DKBMapper.entries(list, connectionID: TestValues.connection)
        #expect(entries.map(\.dkbID) == [TestValues.kautionID, TestValues.giro1ID, TestValues.giro2ID, TestValues.giro3ID])
        #expect(entries.map(\.account.name) == ["Girokonto 2", "Girokonto 1", "Girokonto 1", "Girokonto 1"])
        #expect(entries.allSatisfy { $0.account.type == .giro && $0.account.currency == "EUR" })
        #expect(entries.first?.account.iban == "DE00898902834340121211")
        #expect(entries.allSatisfy { $0.account.id.rawValue.hasPrefix("dkbweb-") && !$0.account.id.rawValue.contains($0.dkbID) })
    }

    @Test func groupNamesOnlyForSingleAccountGroups() throws {
        let settings = try JSONDecoder().decode(DKBDisplaySettingsList.self, from: DKBFixtures.data("product-display-settings.json"))
        let names = DKBMapper.groupNames(settings)
        // "Gruppe 1" holds two accounts → no name from it.
        #expect(names == [TestValues.giro1ID: "Gruppe 2", TestValues.giro3ID: "Gruppe 3"])
    }

    @Test func singleAccountDocumentAndBalance() throws {
        let document = try JSONDecoder().decode(DKBAccountDocument.self, from: DKBFixtures.data("account.json"))
        let entry = try #require(try DKBMapper.entries(DKBAccountList(data: [document.data]), connectionID: TestValues.connection).first)
        let balance = try DKBMapper.balance(entry, asOf: TestValues.now)
        #expect(balance.bookedCents == 0)
        #expect(balance.availableCents == 16129)
        #expect(balance.currency == "EUR")
    }

    @Test func productTypesAreTolerant() {
        #expect(DKBProductType(rawValue: "checking-account-private") == .checking)
        #expect(DKBProductType(rawValue: "savings-account") == .savings)
        #expect(DKBProductType(rawValue: "brokerage") == .unknown("brokerage"))
        #expect(DKBTransactionStatus(rawValue: "booked") == .booked)
        #expect(DKBTransactionStatus(rawValue: "PENDING") == .pending)
        #expect(DKBTransactionStatus(rawValue: "reserved") == .unknown("reserved"))
    }

    @Test(arguments: [
        ("0.00", 0), ("2300.93", 230093), ("-500.00", -50000), ("-97.09", -9709), ("1097.09", 109709),
        ("0.1", 10), ("+12", 1200), ("-0.01", -1), ("19.990", 1999), ("123456789012.34", 12345678901234),
        // 0.1 + 0.2 style traps that Double would get wrong.
        ("0.29", 29), ("4.35", 435), ("1.15", 115),
    ])
    func centsAreExact(text: String, cents: Int) throws {
        #expect(try DKBMapper.cents(text, context: "test") == cents)
    }

    @Test(arguments: ["", "abc", "1,50", "1.234", "1.", ".5", "--1", "1e3", "12.3.4"])
    func malformedAmountsAreFormatChanges(text: String) {
        #expect(throws: ConnectorError.self) { try DKBMapper.cents(text, context: "test") }
    }

    @Test func pageWithCursor() throws {
        let page = try DKBTransactionPage(data: DKBFixtures.data("transactions-page.json"))
        #expect(page.items.count == 25)
        #expect(page.nextCursor == TestValues.giro1Cursor)
        let small = try DKBTransactionPage(data: DKBFixtures.data("transactions-small-page.json"))
        #expect(small.items.count == 3)
        #expect(small.nextCursor == TestValues.giro3Cursor)
        let last = try DKBTransactionPage(data: DKBFixtures.data("transactions-last.json"))
        #expect(last.items.count == 12)
        #expect(last.nextCursor == nil)
    }

    @Test func cursorFromLinkWhenMetaIsMissing() {
        #expect(DKBTransactionPage.cursor(inLink: "/accounts/x/transactions?page[size]=25&page[after]=2023-09-25,5997-72-13-34.96.97.283049") == TestValues.giro1Cursor)
        #expect(DKBTransactionPage.cursor(inLink: "/accounts/x/transactions?page%5Bafter%5D=a%2Cb") == "a,b")
        #expect(DKBTransactionPage.cursor(inLink: "/accounts/x/transactions") == nil)
    }

    @Test func everyFixtureTransactionMaps() throws {
        for name in ["transactions-page.json", "transactions-small-page.json", "transactions-last.json"] {
            let page = try DKBTransactionPage(data: DKBFixtures.data(name))
            for item in page.items {
                let transaction = try DKBMapper.transaction(item.value, raw: item.raw, account: account)
                #expect(transaction.status == .booked)
                #expect(transaction.bookingDate != nil)
                #expect(transaction.externalID == item.value.id)
                #expect(transaction.id.rawValue == "ext:\(item.value.id)")
                // One recorded item has no `description` at all → empty purpose.
                #expect(transaction.purpose == (item.value.attributes.description ?? ""))
                #expect(transaction.purpose.isEmpty || transaction.purpose.hasPrefix("Verwendungszweck "))
                #expect(!transaction.counterpartName.isEmpty)
                let raw = try #require(try JSONSerialization.jsonObject(with: transaction.rawJSON) as? [String: Any])
                #expect(raw["id"] as? String == item.value.id)
                #expect(transaction.fingerprint == Fingerprint.make(accountID: account.id, bookingDate: transaction.bookingDate, amountCents: transaction.amountCents, purpose: transaction.purpose, counterpartIBAN: transaction.counterpartIBAN))
            }
        }
    }

    @Test func outgoingUsesCreditorIncomingUsesDebtor() throws {
        let page = try DKBTransactionPage(data: DKBFixtures.data("transactions-page.json"))
        let mapped = try page.items.map { try DKBMapper.transaction($0.value, raw: $0.raw, account: account) }

        let outgoing = mapped[4] // -882.49 Echtzeitüberweisung to the own ING account
        #expect(outgoing.amountCents == -88249)
        #expect(outgoing.counterpartName == "Max Mustermann")
        #expect(outgoing.counterpartIBAN == "DE00556524677887320405")
        #expect(outgoing.bookingDate == BankDay(iso: "2025-03-17"))

        let otherPerson = mapped[5]
        #expect(otherPerson.counterpartName == "Paul Demo")
        #expect(otherPerson.counterpartIBAN == "DE00280270013233051852")

        let incoming = try #require(mapped.first { $0.amountCents == 38308 }) // Gutschrift from Anna Fiktiv
        #expect(incoming.counterpartName == "Anna Fiktiv")
        #expect(incoming.counterpartIBAN == "DE00112635601122089941")

        // Bank fee statement (0.00, no IBAN): debtor name.
        #expect(mapped[0].amountCents == 0 && mapped[0].counterpartName == "Musterhandel GmbH" && mapped[0].counterpartIBAN == nil)
        // Booking and value date differ.
        #expect(mapped[3].bookingDate == BankDay(iso: "2025-04-15") && mapped[3].valueDate == BankDay(iso: "2025-04-17"))
    }

    @Test func sepaReferencesAndPending() throws {
        let json = #"""
        {"type":"accountTransaction","id":"tx-1","attributes":{"status":"pending","bookingDate":"2026-11-09","valueDate":"2026-11-09",
         "description":"Abo November","amount":{"currencyCode":"EUR","value":"-9.99"},
         "creditor":{"name":"Streaming GmbH","id":"DE98ZZZ09999999999","creditorAccount":{"iban":"de00 1234 5678 9012 3456 78"}},
         "debtor":{"name":"Max Mustermann","debtorAccount":{"iban":"DE00245442831624936444"}},
         "endToEndId":"E2E-REF-1","mandateId":"MANDAT-7","unknownField":{"x":1}}}
        """#
        let item = try JSONDecoder().decode(DKBTransaction.self, from: Data(json.utf8))
        let transaction = try DKBMapper.transaction(item, raw: Data(json.utf8), account: account)
        #expect(transaction.status == .pending)
        #expect(transaction.bookingDate == nil)
        #expect(transaction.valueDate == BankDay(iso: "2026-11-09"))
        #expect(transaction.amountCents == -999)
        #expect(transaction.counterpartName == "Streaming GmbH")
        #expect(transaction.counterpartIBAN == "DE001234567890123456 78".replacingOccurrences(of: " ", with: ""))
        #expect(transaction.eref == "E2E-REF-1")
        #expect(transaction.mref == "MANDAT-7")
        #expect(transaction.creditorID == "DE98ZZZ09999999999")
        #expect(transaction.purpose == "Abo November")
    }

    @Test func bookedWithoutBookingDateIsAFormatChange() throws {
        let json = #"{"id":"tx-2","attributes":{"status":"booked","valueDate":"2026-11-09","amount":{"value":"1.00"}}}"#
        let item = try JSONDecoder().decode(DKBTransaction.self, from: Data(json.utf8))
        #expect(throws: ConnectorError.self) { try DKBMapper.transaction(item, raw: Data(json.utf8), account: account) }
    }

    @Test func unknownStatusFallsBackOnTheBookingDate() throws {
        let json = #"{"id":"tx-3","attributes":{"status":"reserved","valueDate":"2026-11-09","amount":{"value":"-1.00"}}}"#
        let item = try JSONDecoder().decode(DKBTransaction.self, from: Data(json.utf8))
        let transaction = try DKBMapper.transaction(item, raw: Data(json.utf8), account: account)
        #expect(transaction.status == .pending)
        #expect(transaction.counterpartName == "")
    }
}
