import CryptoKit
import Foundation
import MFNCore
import MFNStore

/// What the detection found for one state of the data.
struct RecurringDetection: Equatable {
    var revision: Int
    var day: BankDay
    /// Counts up with every finished detection: what depends on it is cached by this number.
    var version: Int
    var payments: [RecurringPayment]
}

/// "Fixkosten" (⌘3): recurring payments read from the bookings of the visible accounts.
extension AppModel {
    /// Runs `Subscriptions.detect` for the current data unless that result is there already.
    /// The detection walks two years of bookings: it runs off the main actor, and the list keeps
    /// showing the result before until the new one arrives. Called by the view
    /// (`.task(id: snapshotRevision)`, so a newer publish cancels the wait of an older one).
    func refreshRecurringDetection() async {
        let revision = snapshotRevision
        let today = BankDay.today
        if let known = recurringDetection, known.revision == revision, known.day == today { return }
        // A sync or a categorization run publishes in quick succession: wait for a pause.
        if recurringDetection != nil {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        let session = lockSession
        // Own IBANs from the whole ledger: a transfer to a hidden account is still a transfer.
        let own = Set(ledger.accounts.compactMap(\.iban))
        let transactions = snapshot.transactions
        let payments = await Task.detached(priority: .userInitiated) {
            Subscriptions.detect(transactions: transactions, ownIBANs: own, today: today)
        }.value
        guard !Task.isCancelled, !isStale(session) else { return }
        migrateHiddenRecurring(payments)
        recurringDetection = RecurringDetection(revision: revision, day: today, version: (recurringDetection?.version ?? 0) + 1, payments: payments)
    }

    /// The detected payments with the user's entries, hidden ones included. `nil` until the first
    /// detection finished. Cached: the list reads it on every render.
    var recurringPayments: [RecurringPayment]? {
        guard let detection = recurringDetection else { return nil }
        let entries = snapshot.recurringEntries
        if let cache = recurringCache, cache.version == detection.version, cache.entries == entries { return cache.payments }
        let payments = Subscriptions.applying(entries, to: detection.payments, today: detection.day)
        recurringCache = (detection.version, entries, payments)
        return payments
    }

    /// What `hiddenRecurring` stores for a payment: an HMAC of its ID under a key derived from
    /// the database key. The ID carries the counterpart name; a plain hash could be confirmed by
    /// guessing names, so nothing in the preferences says anything without the database.
    func recurringHash(_ id: String) -> String {
        guard let key = recurringHashKey else { return Self.legacyRecurringHash(id) }
        return HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: key).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// `recurringHash` as a function that can leave the main actor (MCP `find_recurring`).
    func recurringHasher() -> @Sendable (String) -> String {
        guard let key = recurringHashKey else { return { Self.legacyRecurringHash($0) } }
        return { id in HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: key).prefix(12).map { String(format: "%02x", $0) }.joined() }
    }

    /// The unkeyed hash of the first builds of 0.5.0, only read to carry old entries over.
    nonisolated static func legacyRecurringHash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Entries hidden under the old hash get the keyed one.
    private func migrateHiddenRecurring(_ payments: [RecurringPayment]) {
        guard recurringHashKey != nil, !hiddenRecurring.isEmpty else { return }
        var hidden = hiddenRecurring
        for payment in payments {
            if hidden.remove(Self.legacyRecurringHash(payment.id)) != nil { hidden.insert(recurringHash(payment.id)) }
        }
        if hidden != hiddenRecurring { hiddenRecurring = hidden }
    }

    func isRecurringHidden(_ payment: RecurringPayment) -> Bool {
        hiddenRecurring.contains(recurringHash(payment.id))
    }

    func setRecurringHidden(_ hidden: Bool, _ payment: RecurringPayment) {
        let hash = recurringHash(payment.id)
        if hidden { hiddenRecurring.insert(hash) } else { hiddenRecurring.remove(hash) }
    }

    /// The account's list, searched for the counterpart.
    func showTransactions(of payment: RecurringPayment) {
        var query = TransactionQuery()
        // The bookings carry the bank's name, not the one the user gave the entry.
        query.text = payment.detected?.title ?? payment.title
        ledgerQuery = query
        selection = .account(payment.accountID)
    }
}

extension AppModel {
    /// An own entry, or the change of a detected payment. Returns an error text, `nil` on success.
    func saveRecurringEntry(_ entry: RecurringEntry) async -> String? {
        guard let store = backupStore else { return String(localized: "MFN ist gesperrt.") }
        do {
            try await store.upsertRecurringEntry(entry)
            return nil
        } catch {
            return String(localized: "Der Eintrag konnte nicht gespeichert werden: \(String(describing: error))")
        }
    }

    /// Deletes an own entry, or brings a changed payment back to what the bookings say.
    func removeRecurringEntry(_ id: UUID) async -> String? {
        guard let store = backupStore else { return String(localized: "MFN ist gesperrt.") }
        do {
            try await store.removeRecurringEntry(id)
            return nil
        } catch {
            return String(localized: "Der Eintrag konnte nicht entfernt werden: \(String(describing: error))")
        }
    }
}

/// What the editor sheet works on: a new own entry, an own entry, or a detected payment.
struct RecurringDraft: Identifiable, Equatable {
    let id = UUID()
    /// Entry in the store this draft changes.
    var entryID: UUID?
    var createdAt: Date?
    /// Detected payment this is about (`nil`: own entry).
    var seriesID: String?
    /// What the bookings say; the draft is saved as a change only where it differs.
    var detected: RecurringPayment.Detected?
    var isExpense = true
    var title = ""
    var amountText = ""
    var cadence = RecurringPayment.Cadence.monthly
    var accountID: AccountID?
    var date = BankDay.today.startDate.addingTimeInterval(12 * 3600)

    /// A new own entry.
    init(account: AccountID?, isExpense: Bool = true) {
        accountID = account
        self.isExpense = isExpense
    }

    /// - Parameter stored: the entry behind `payment` as it is in the store, if there is one: its
    ///   creation date stays (it orders the entries and anchors an own one without a date).
    init(_ payment: RecurringPayment, stored: RecurringEntry? = nil) {
        entryID = payment.entryID
        createdAt = stored?.createdAt
        isExpense = !payment.isIncome
        title = payment.title
        amountText = Self.text(payment.cents)
        cadence = payment.cadence
        accountID = payment.accountID
        if payment.isOwn {
            date = payment.next.startDate.addingTimeInterval(12 * 3600)
        } else {
            seriesID = payment.id
            detected = payment.detected ?? RecurringPayment.Detected(title: payment.title, cents: payment.cents, cadence: payment.cadence)
        }
    }

    var isOwn: Bool { seriesID == nil }
    var cents: Int? { BudgetSheet.parseCents(amountText).flatMap { $0 > 0 ? (isExpense ? -$0 : $0) : nil } }
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { cents != nil && !trimmedTitle.isEmpty && accountID != nil }

    /// A detected payment set back to exactly what the bookings say: nothing to store.
    var matchesDetected: Bool {
        guard let detected, let cents else { return false }
        return detected.title == trimmedTitle && detected.cents == cents && detected.cadence == cadence
    }

    var isEditedNow: Bool { detected != nil && entryID != nil }

    mutating func revert() {
        guard let detected else { return }
        title = detected.title
        amountText = Self.text(detected.cents)
        isExpense = detected.cents < 0
        cadence = detected.cadence
    }

    func entry(now: Date = Date()) -> RecurringEntry? {
        guard let cents, let accountID, !trimmedTitle.isEmpty else { return nil }
        return RecurringEntry(id: entryID ?? UUID(), seriesID: seriesID, accountID: accountID, title: trimmedTitle, amountCents: cents,
                              cadence: cadence, anchorDay: isOwn ? BankDay(date) : nil, createdAt: createdAt ?? now)
    }

    /// "1234,50" (or "1234.50", after the user's region) for the amount field.
    static func text(_ cents: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let value = abs(cents)
        let separator = locale.decimalSeparator.flatMap { $0 == "." ? "." : nil } ?? ","
        return value % 100 == 0 ? "\(value / 100)" : String(format: "%d%@%02d", value / 100, separator, value % 100)
    }
}

/// The list split the way the view shows it.
struct RecurringOverview: Equatable {
    var expenses: [RecurringPayment] = []
    var income: [RecurringPayment] = []
    var ended: [RecurringPayment] = []
    var hidden: [RecurringPayment] = []

    init(_ payments: [RecurringPayment], filter: RecurringFilter = RecurringFilter(), isHidden: (RecurringPayment) -> Bool) {
        defer {
            let shown = expenses + income + ended
            sides = (shown.contains { $0.isIncome }, shown.contains { !$0.isIncome })
            hiddenSides = (hidden.contains { $0.isIncome }, hidden.contains { !$0.isIncome })
        }
        for payment in payments where filter.matches(payment) {
            if isHidden(payment) {
                hidden.append(payment)
            } else if payment.isEnded {
                ended.append(payment)
            } else if payment.isIncome {
                income.append(payment)
            } else {
                expenses.append(payment)
            }
        }
    }

    /// Nothing to list. Hidden entries only count while they are shown.
    func isEmpty(showingHidden: Bool) -> Bool {
        expenses.isEmpty && income.isEmpty && ended.isEmpty && (hidden.isEmpty || !showingHidden)
    }
    /// Whether the listed (and the hidden) payments have income and expenses, computed once.
    private var sides = (income: false, expense: false)
    private var hiddenSides = (income: false, expense: false)

    static func == (lhs: RecurringOverview, rhs: RecurringOverview) -> Bool {
        lhs.expenses == rhs.expenses && lhs.income == rhs.income && lhs.ended == rhs.ended && lhs.hidden == rhs.hidden
    }

    /// Something to list on the expense side and on the income side.
    func hasBothSides(showingHidden: Bool) -> Bool {
        (sides.income || (showingHidden && hiddenSides.income)) && (sides.expense || (showingHidden && hiddenSides.expense))
    }

    /// Positive cents.
    var expensesPerMonth: Int { -expenses.reduce(0) { $0 + $1.monthlyCents } }
    var expensesPerYear: Int { -expenses.reduce(0) { $0 + $1.yearlyCents } }
    var incomePerMonth: Int { income.reduce(0) { $0 + $1.monthlyCents } }
    var incomePerYear: Int { income.reduce(0) { $0 + $1.yearlyCents } }
}

/// What the Fixkosten list is narrowed to. The sums at the top follow it.
struct RecurringFilter: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all, expenses, income
        var id: Self { self }
        var title: String {
            switch self {
            case .all: String(localized: "Alle")
            case .expenses: String(localized: "Ausgaben")
            case .income: String(localized: "Einnahmen")
            }
        }
    }

    var kind = Kind.all
    var cadence: RecurringPayment.Cadence?
    var account: AccountID?
    var text = ""

    var isActive: Bool { self != RecurringFilter() }

    func matches(_ payment: RecurringPayment) -> Bool {
        switch kind {
        case .all: break
        case .expenses: if payment.isIncome { return false }
        case .income: if !payment.isIncome { return false }
        }
        if let cadence, payment.cadence != cadence { return false }
        if let account, payment.accountID != account { return false }
        let needle = text.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || payment.title.localizedStandardContains(needle)
    }
}

extension RecurringPayment.Cadence {
    var title: String {
        switch self {
        case .monthly: String(localized: "Monatlich")
        case .quarterly: String(localized: "Vierteljährlich")
        case .halfYearly: String(localized: "Halbjährlich")
        case .yearly: String(localized: "Jährlich")
        }
    }
}
