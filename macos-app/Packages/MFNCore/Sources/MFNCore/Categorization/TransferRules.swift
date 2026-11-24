import Foundation

/// Money that only moves between the user's own accounts: not income, not spending. Shared by
/// the overview and the MCP aggregations (`cash_flow`), so both count alike.
public enum TransferRules {
    /// Own transfers and card settlements (`TransferStage`).
    public static let categories: Set<CategoryID> = [TransferStage.category, TransferStage.cardSettlementCategory]

    /// "kredit" holds card settlements and loan repayments. Only a card settlement moves money
    /// between own accounts, and only if the card is in MFN (else it is the only trace of that
    /// spending). Loan repayments are real spending.
    public static func isCardSettlement(_ transaction: Transaction, account: Account?, hasCardAccount: Bool) -> Bool {
        guard hasCardAccount, transaction.categoryID == "kredit" else { return false }
        if account?.type == .card { return true }
        let text = (transaction.counterpartName + " " + transaction.purpose).lowercased()
        return ["kreditkart", "kartenabrechnung", "visa", "mastercard", "american express"].contains { text.contains($0) }
    }

    /// Whether the booking moves money between own accounts (left out of income and spending).
    public static func isOwnTransfer(_ transaction: Transaction, account: Account?, hasCardAccount: Bool) -> Bool {
        (transaction.categoryID.map(categories.contains) ?? false)
            || isCardSettlement(transaction, account: account, hasCardAccount: hasCardAccount)
    }
}
