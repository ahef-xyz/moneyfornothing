import Foundation
import Testing
@testable import MFNCore

@Suite struct TransactionInitiatorTests {
    @Test func readsTopLevelAndNestedFields() {
        let top = Data(#"{"id":"t1","initiator_name":" Name 02 ","initiator_id":4711,"amount":-12}"#.utf8)
        #expect(TransactionInitiator.extract(from: top) == TransactionInitiator(name: "Name 02", id: "4711"))
        let deep = Data(#"{"data":[{"x":1},{"meta":{"initiator_name":"Name 03","initiator_id":"u-9"}}]}"#.utf8)
        #expect(TransactionInitiator.extract(from: deep)?.id == "u-9")
        let nested = Data(#"{"initiator":{"name":"Name 04","id":"p1"}}"#.utf8)
        #expect(TransactionInitiator.extract(from: nested)?.name == "Name 04")
    }

    @Test func noneWithoutNameOrJSON() {
        #expect(TransactionInitiator.extract(from: Data(#"{"amount":1}"#.utf8)) == nil)
        #expect(TransactionInitiator.extract(from: Data(#"{"initiator_name":""}"#.utf8)) == nil)
        #expect(TransactionInitiator.extract(from: Data("initiator kaputt".utf8)) == nil)
    }

    @Test func queryFiltersAndSearchesByPerson() {
        let day = BankDay(year: 2026, month: 11, day: 3)!
        let a = Transaction(accountID: "joint", bookingDate: day, valueDate: day, amountCents: -1_000, counterpartName: "REWE", purpose: "Einkauf A", status: .booked, rawJSON: Data(#"{"initiator_name":"Name 02","initiator_id":"1"}"#.utf8))
        let b = Transaction(accountID: "joint", bookingDate: day, valueDate: day, amountCents: -2_000, counterpartName: "REWE", purpose: "Einkauf B", status: .booked, rawJSON: Data(#"{"initiator_name":"Name 03","initiator_id":"2"}"#.utf8))
        let lookup: (Transaction) -> TransactionInitiator? = { TransactionInitiator.extract(from: $0.rawJSON) }
        #expect(TransactionQuery().filter([a, b], initiator: lookup).count == 2)
        var byPerson = TransactionQuery()
        byPerson.initiator = "2"
        #expect(byPerson.filter([a, b], initiator: lookup).map(\.id) == [b.id])
        #expect(byPerson.isFiltering)
        #expect(TransactionQuery(text: "name 02").filter([a, b], initiator: lookup).map(\.id) == [a.id])
    }
}

@Suite struct UncategorizedFilterTests {
    @Test func onlyUncategorized() {
        let day = BankDay(year: 2026, month: 11, day: 3)!
        let open = Transaction(accountID: "a", bookingDate: day, valueDate: day, amountCents: -1, counterpartName: "X", purpose: "offen", status: .booked)
        let done = Transaction(accountID: "a", bookingDate: day, valueDate: day, amountCents: -1, counterpartName: "Y", purpose: "fertig", status: .booked, categoryID: "lebensmittel", categorySource: .manual)
        var query = TransactionQuery(category: "lebensmittel")
        query.onlyUncategorized = true
        #expect(query.filter([open, done]).map(\.id) == [open.id])
        #expect(query.isFiltering)
    }
}
