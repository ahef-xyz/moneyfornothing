import Foundation
import MFNCore
import Testing
@testable import MFNMock

/// The demo must show something under "Fixkosten" (screenshots, previews, first impression).
@Suite struct MockSubscriptionsTests {
    static let today = BankDay(iso: "2026-11-09") ?? .today
    let dataset = MockDataset.demo(today: Self.today, now: Self.today.startDate.addingTimeInterval(9 * 3600))

    @Test func demoHasRecurringPayments() {
        let found = Subscriptions.detect(transactions: dataset.allTransactions, ownIBANs: Set(dataset.accounts.compactMap(\.iban)), today: Self.today)
        #expect(found.contains { !$0.isIncome && !$0.isEnded })
        #expect(found.contains { $0.isIncome && !$0.isEnded })
        #expect(found.contains { $0.cadence == .quarterly })
        // Standing orders between the demo's own accounts are not costs (nothing is categorized
        // in the demo: the matching booking in the other account or the own IBAN tells).
        let titles = found.map(\.title)
        #expect(!titles.contains { $0.hasPrefix("Eigenes") }, "\(titles)")
    }
}
