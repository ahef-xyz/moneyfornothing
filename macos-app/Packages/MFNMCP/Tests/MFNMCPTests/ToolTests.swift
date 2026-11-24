import Foundation
import MFNCore
import MFNMock
import Testing
@testable import MFNMCP

@Suite struct FieldRuleTests {
    /// Every value that must never reach a client, from the full demo ledger.
    static func forbiddenValues(_ snapshot: LedgerSnapshot) -> Set<String> {
        var values: Set<String> = []
        func add(_ value: String?) {
            guard let value, value.count >= 6 else { return }
            values.insert(value)
            values.insert(value.replacingOccurrences(of: " ", with: ""))
        }
        for account in snapshot.accounts {
            add(account.iban)
            add(account.id.rawValue)
            if let last4 = account.cardLast4 { values.insert("*" + last4); values.insert(" " + last4) }
        }
        for transaction in snapshot.transactions {
            add(transaction.counterpartIBAN)
            add(transaction.eref)
            add(transaction.mref)
            add(transaction.creditorID)
            add(transaction.externalID)
            add(transaction.fingerprint)
            add(transaction.id.rawValue)
            let raw = String(decoding: transaction.rawJSON, as: UTF8.self)
            if raw.count > 12 { values.insert(raw) }
        }
        return values
    }

    /// Calls every tool with defaults, wide periods and every account.
    static func allOutputs(session: MCPSession, snapshot: LedgerSnapshot) async -> [String] {
        var outputs: [String] = []
        let accounts = await call(session, "list_accounts")
        let ids = accounts["result"]?["structuredContent"]?["accounts"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(ids.count == snapshot.accounts.count)
        outputs.append(accounts.encodedString())
        let wide: JSONValue = ["from": "2024-01-01", "to": "2026-12-31"]
        let rows: JSONValue = ["from": "2025-11-01", "to": "2026-11-30"]
        for tool in ["get_status", "list_categories", "get_balances", "find_recurring", "get_budget", "get_portfolio"] {
            outputs.append(await call(session, tool).encodedString())
        }
        outputs.append(await call(session, "find_recurring", ["include_ended": true]).encodedString())
        outputs.append(await call(session, "sum_by_category", wide).encodedString())
        outputs.append(await call(session, "cash_flow", wide).encodedString())
        outputs.append(await call(session, "compare_periods", ["first_from": "2025-01-01", "first_to": "2025-12-31", "second_from": "2026-01-01", "second_to": "2026-11-30"]).encodedString())
        for id in ids {
            outputs.append(await call(session, "balance_on", ["account_id": .string(id), "date": "2026-01-15"]).encodedString())
            outputs.append(await call(session, "get_forecast", ["account_id": .string(id), "days": 180]).encodedString())
            var page = 1
            while true {
                let list = await call(session, "list_transactions", ["account_id": .string(id), "from": "2025-11-01", "to": "2026-11-30", "page": .int(page)])
                outputs.append(list.encodedString())
                for transaction in list["result"]?["structuredContent"]?["transactions"]?.arrayValue ?? [] {
                    if let tid = transaction["id"] {
                        outputs.append(await call(session, "get_transaction", ["id": tid]).encodedString())
                    }
                }
                guard let next = list["result"]?["structuredContent"]?["next_page"]?.intValue else { break }
                page = next
            }
        }
        outputs.append(await call(session, "search_transactions", rows.objectValue.map { JSONValue.object($0.merging(["query": "e"]) { a, _ in a }) } ?? rows).encodedString())
        return outputs
    }

    @Test func noForbiddenFieldInAnyToolOutput() async {
        let host = FakeHost()
        let session = MCPSession(host: host, serverVersion: "0.6.0")
        let outputs = await Self.allOutputs(session: session, snapshot: host.snapshot)
        let forbidden = Self.forbiddenValues(host.snapshot)
        #expect(!forbidden.isEmpty)
        let joined = outputs.joined(separator: "\n")
        #expect(joined.count > 100_000, "the walk read the whole ledger")
        for value in forbidden {
            #expect(!joined.contains(value), "leaked: \(value.prefix(12))…")
        }
        for key in ["iban", "eref", "mref", "creditor", "fingerprint", "raw_json", "rawJSON", "external"] {
            #expect(!joined.lowercased().contains("\"\(key.lowercased())"), "field \(key)")
        }
        #expect(!host.activity.contains { $0.outcome == .failed })
    }

    @Test func accountsOutsideTheScopeDoNotExist() async {
        let host = FakeHost()
        let shared = host.snapshot.accounts.prefix(2).map(\.id)
        host.scope = Set(shared)
        let session = MCPSession(host: host, serverVersion: "0.6.0")
        let accounts = await call(session, "list_accounts")
        #expect(accounts["result"]?["structuredContent"]?["accounts"]?.arrayValue?.count == 2)
        let balances = await call(session, "get_balances")
        #expect(balances["result"]?["structuredContent"]?["accounts"]?.arrayValue?.count ?? 0 <= 2)
        let list = await call(session, "list_transactions", ["from": "2025-11-01", "to": "2026-11-30"])
        let ids = MCPIdentifiers(salt: Data("test-salt".utf8))
        let allowed = Set(shared.map(ids.account))
        for row in list["result"]?["structuredContent"]?["transactions"]?.arrayValue ?? [] {
            #expect(allowed.contains(row["account_id"]?.stringValue ?? ""))
        }
        // An id of another account is unknown.
        let other = ids.account(host.snapshot.accounts[3].id)
        let refused = await call(session, "balance_on", ["account_id": .string(other), "date": "2026-11-01"])
        #expect(refused["result"]?["isError"] == true)
    }

    @Test func pagesAreCappedAndPeriodsLimited() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        let list = await call(session, "list_transactions", ["from": "2025-11-01", "to": "2026-11-30"])
        let rows = list["result"]?["structuredContent"]?["transactions"]?.arrayValue ?? []
        #expect(rows.count == MCPLimits.pageSize)
        #expect(list["result"]?["structuredContent"]?["next_page"] == .int(2))
        let tooLong = await call(session, "list_transactions", ["from": "2024-01-01", "to": "2026-11-30"])
        #expect(tooLong["result"]?["isError"] == true)
    }

    @Test func sumsMatchTheRowsTheyCount() async throws {
        let host = FakeHost()
        let session = MCPSession(host: host, serverVersion: "0.6.0")
        let sums = await call(session, "sum_by_category", ["from": "2026-10-01", "to": "2026-10-31"])
        let total = (sums["result"]?["structuredContent"]?["sums"]?.arrayValue ?? [])
            .filter { $0["currency"] == "EUR" }
            .compactMap { Money.cents($0["amount"]) }.reduce(0, +)
        let october = DayPeriod(from: BankDay(year: 2026, month: 10, day: 1)!, to: BankDay(year: 2026, month: 10, day: 31)!)!
        let expected = host.snapshot.transactions.filter {
            ($0.status == .booked || $0.status == .pending) && october.contains($0.effectiveDate) && $0.currency == "EUR"
        }.reduce(0) { $0 + $1.amountCents }
        #expect(total == expected)
        #expect(expected != 0)
    }

    @Test func wrongArgumentsComeBackAsToolErrors() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        for (tool, arguments) in [
            ("balance_on", ["account_id": "nope", "date": "2026-01-01"] as JSONValue),
            ("sum_by_category", ["from": "yesterday"]),
            ("sum_by_category", ["from": "2026-10-10", "to": "2026-10-01"]),
            ("list_transactions", ["min_amount": "1.234"]),
            ("list_transactions", ["category_id": "nothing"]),
            ("get_transaction", ["id": "t_000"]),
            ("balance_on", ["account_id": "nope", "date": "2099-01-01"]),
            ("cash_flow", ["from": "1900-01-01", "to": "2026-01-01"]),
        ] {
            let answer = await call(session, tool, arguments)
            #expect(answer["result"]?["isError"] == true, "\(tool)")
        }
    }

    @Test func accountsComeInAStableOrder() async {
        let host = FakeHost()
        var shuffled = host.snapshot
        shuffled.accounts.reverse()
        let a = await call(MCPSession(host: host, serverVersion: "0"), "list_accounts")
        let b = await call(MCPSession(host: FakeHost(snapshot: shuffled), serverVersion: "0"), "list_accounts")
        #expect(a["result"]?["structuredContent"] == b["result"]?["structuredContent"])
    }

    @Test func aFutureStartRunsToTheEndOfItsMonth() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        let answer = await call(session, "sum_by_category", ["from": "2027-02-10"])
        #expect(answer["result"]?["structuredContent"]?["to"] == "2027-02-28")
    }

    @Test func onlyAnEndDateMeansThatMonth() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        let answer = await call(session, "sum_by_category", ["to": "2026-10-31"])
        #expect(answer["result"]?["structuredContent"]?["from"] == "2026-10-01")
    }

    @Test func numbersInNamesAndIBANsInTextAreScrubbed() {
        #expect(FieldRules.scrubNumbers("Visa Karte 4111 2222") == "Visa Karte …")
        #expect(FieldRules.scrubNumbers("Tagesgeld 2") == "Tagesgeld 2")
        #expect(FieldRules.scrubIBANs("Miete von DE89 3704 0044 0532 0130 00 danke") == "Miete von [IBAN] danke")
        #expect(FieldRules.scrubIBANs("iban de89-3704-0044-0532-0130-00") == "iban [IBAN]")
        #expect(FieldRules.thirdParty("Konto 1234567890 am 20261124", limit: 80) == "Konto … am 20261124")
        #expect(FieldRules.thirdParty("Karte 1234 1234 1234 1234", limit: 80) == "Karte …")
    }
}
