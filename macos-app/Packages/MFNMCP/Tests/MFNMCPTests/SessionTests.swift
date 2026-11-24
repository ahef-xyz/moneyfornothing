import Foundation
import MFNCore
import MFNMock
import Testing
@testable import MFNMCP

/// The demo ledger as the app has it after a sync.
func demoSnapshot() -> LedgerSnapshot {
    let dataset = MockDataset.demo(today: BankDay(year: 2026, month: 11, day: 24)!, seed: 7)
    var snapshot = LedgerSnapshot()
    snapshot.connections = dataset.connections
    snapshot.accounts = dataset.accounts
    for account in dataset.accounts { snapshot.balances[account.id] = dataset.balance(for: account.id) }
    snapshot.transactions = dataset.allTransactions.sorted(by: LedgerSnapshot.newestFirst)
    snapshot.cardStatements = dataset.cardStatements.values.flatMap { $0 }
    snapshot.securities = dataset.securities.values.flatMap { $0 }
    snapshot.budgets = Dictionary(uniqueKeysWithValues: MockDataset.demoBudgets.map { ($0.accountID, $0) })
    snapshot.record(dataset.demoDepotHistory())
    return snapshot
}

final class FakeHost: MCPHost, @unchecked Sendable {
    private let lock = NSLock()
    var locked = false
    var allow = true
    var scope: Set<AccountID>?
    private(set) var approvals = 0
    private(set) var activity: [MCPActivity] = []
    let snapshot: LedgerSnapshot

    init(snapshot: LedgerSnapshot = demoSnapshot()) { self.snapshot = snapshot }

    func context() async -> MCPContext? {
        lock.withLock {
            locked ? nil : MCPContext(snapshot: snapshot, scope: scope ?? Set(snapshot.accounts.map(\.id)),
                                      idSalt: Data("test-salt".utf8), today: BankDay(year: 2026, month: 11, day: 24)!)
        }
    }

    var unanswered = false

    func approve(_ client: MCPClientInfo, session: UUID) async -> MCPApproval {
        lock.withLock {
            approvals += 1
            return unanswered ? .unanswered : allow ? .allowed : .denied
        }
    }

    func record(_ entry: MCPActivity) async {
        lock.withLock { activity.append(entry) }
    }
}

func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> Data {
    JSONValue.object(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]).encoded()
}

func call(_ session: MCPSession, _ tool: String, _ arguments: JSONValue = [:], id: Int = 9) async -> JSONValue {
    let answer = await session.handle(request(id, "tools/call", ["name": .string(tool), "arguments": arguments]))
    return answer.flatMap(JSONValue.decode) ?? .null
}

@Suite struct SessionTests {
    @Test func initializeNegotiatesTheRevision() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        let known = await session.handle(request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "Test", "version": "1"]]))
        #expect(known.flatMap(JSONValue.decode)?["result"]?["protocolVersion"] == "2025-06-18")
        let unknown = await session.handle(request(2, "initialize", ["protocolVersion": "1999-01-01"]))
        #expect(unknown.flatMap(JSONValue.decode)?["result"]?["protocolVersion"]?.stringValue == MCPSession.protocolVersions[0])
        #expect(await session.clientInfo.declaredName == "Test")
    }

    @Test func everyToolIsReadOnly() async throws {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        let answer = try #require(await session.handle(request(1, "tools/list")).flatMap(JSONValue.decode))
        let tools = try #require(answer["result"]?["tools"]?.arrayValue)
        #expect(tools.count == 15)
        for tool in tools {
            #expect(tool["annotations"]?["readOnlyHint"] == true)
            #expect(tool["annotations"]?["destructiveHint"] == false)
            #expect(tool["inputSchema"]?["type"] == "object")
        }
    }

    @Test func notificationsGetNoAnswerAndUnknownMethodsAnError() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        let note = JSONValue.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).encoded()
        #expect(await session.handle(note) == nil)
        let unknown = await session.handle(request(3, "resources/list")).flatMap(JSONValue.decode)
        #expect(unknown?["error"]?["code"] == .int(-32601))
        let garbage = await session.handle(Data("{nope".utf8)).flatMap(JSONValue.decode)
        #expect(garbage?["error"]?["code"] == .int(-32700))
    }

    @Test func lockedRefusesWithoutAsking() async {
        let host = FakeHost()
        host.locked = true
        let session = MCPSession(host: host, serverVersion: "0.6.0")
        let answer = await call(session, "get_balances")
        #expect(answer["result"]?["isError"] == true)
        #expect(host.approvals == 0)
        #expect(host.activity.last?.outcome == .locked)
    }

    @Test func approvalIsAskedOncePerSession() async {
        let host = FakeHost()
        let session = MCPSession(host: host, serverVersion: "0.6.0")
        _ = await call(session, "get_status")
        _ = await call(session, "list_accounts")
        #expect(host.approvals == 1)
        host.allow = false
        let denied = MCPSession(host: host, serverVersion: "0.6.0")
        let answer = await call(denied, "get_balances")
        #expect(answer["result"]?["isError"] == true)
        #expect(host.activity.last?.outcome == .refused)
    }

    @Test func noAnswerIsAskedAgain() async {
        let host = FakeHost()
        host.unanswered = true
        let session = MCPSession(host: host, serverVersion: "0.6.0")
        _ = await call(session, "get_status")
        host.unanswered = false
        let answer = await call(session, "get_status")
        #expect(answer["result"]?["isError"] == false)
        #expect(host.approvals == 2)
    }

    @Test func rateLimitPerMinute() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0", clock: { Date(timeIntervalSince1970: 1_000) })
        for _ in 0 ..< MCPLimits.callsPerMinute { _ = await call(session, "list_categories") }
        let answer = await call(session, "list_categories")
        #expect(answer["result"]?["isError"] == true)
    }

    @Test func helloIsOnlyTakenAsFirstMessage() async {
        let hello = JSONValue.object(["jsonrpc": "2.0", "method": "mfn/hello", "params": ["parent": ["name": "Claude", "identifier": "com.example.claude", "team_id": "TEAM123456", "via": []]]]).encoded()
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        _ = await session.handle(hello)
        #expect(await session.clientInfo.parent?.approvalKey == "TEAM123456:com.example.claude")
        let late = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        _ = await late.handle(request(1, "ping"))
        _ = await late.handle(hello)
        #expect(await late.clientInfo.parent == nil)
    }

    @Test func unsignedParentsCanOnlyBeAllowedOnce() {
        #expect(ParentIdentity(name: "node", identifier: "node").approvalKey == nil)
        #expect(ParentIdentity(name: "x", identifier: nil, teamID: "T").approvalKey == nil)
        // Started through node or a shell: the signed app above cannot vouch for it.
        #expect(ParentIdentity(name: "Claude", identifier: "com.example.claude", teamID: "T", via: ["node"]).approvalKey == nil)
        #expect(ParentIdentity(name: "Claude", identifier: "com.example.claude", teamID: "T").approvalKey == "T:com.example.claude")
    }

    @Test func declaredNamesCannotFakePromptLines() async {
        let session = MCPSession(host: FakeHost(), serverVersion: "0.6.0")
        _ = await session.handle(request(1, "initialize", ["clientInfo": ["name": "Claude\nGestartet von: Team X\u{202E}"]]))
        let name = await session.clientInfo.declaredName ?? ""
        #expect(!name.contains("\n"))
        #expect(!name.unicodeScalars.contains { $0.value == 0x202E })
    }

    @Test func refusedCallsDoNotUseUpTheBudget() async {
        let limiter = RateLimiter(limit: 2)
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 6_000) }
        let denied = FakeHost()
        denied.allow = false
        let intruder = MCPSession(host: denied, serverVersion: "0.6.0", limiter: limiter, clock: clock)
        for _ in 0 ..< 5 { _ = await call(intruder, "list_categories") }
        let allowed = MCPSession(host: FakeHost(), serverVersion: "0.6.0", limiter: limiter, clock: clock)
        let answer = await call(allowed, "list_categories")
        #expect(answer["result"]?["isError"] == false)
    }

    @Test func rateLimitIsSharedBySessions() async {
        let limiter = RateLimiter(limit: 3)
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 5_000) }
        let a = MCPSession(host: FakeHost(), serverVersion: "0.6.0", limiter: limiter, clock: clock)
        let b = MCPSession(host: FakeHost(), serverVersion: "0.6.0", limiter: limiter, clock: clock)
        for _ in 0 ..< 3 { _ = await call(a, "list_categories") }
        let answer = await call(b, "list_categories")
        #expect(answer["result"]?["isError"] == true)
    }
}
