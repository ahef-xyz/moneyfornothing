import Foundation
import MFNCore

/// Service calls at YAXI per calendar month, counted on this Mac (docs/v0.7.0.md section 6). YAXI's
/// free tier is 1,000 calls a month per access. Holds only numbers, so plain `UserDefaults`.
///
/// At `pauseShare` of the free calls automatic syncs over YAXI pause until the next month; syncs the
/// user starts still run.
public final class YAXIUsage: @unchecked Sendable {
    public static let shared = YAXIUsage()
    public static let freeCalls = 1_000
    public static let pauseShare = 0.9

    // `UserDefaults` is thread-safe; the lock keeps read-increment-write atomic.
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    static func key(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: BankDay.bankTimeZone, from: date)
        return String(format: "yaxi.calls.%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Calls this month.
    public var thisMonth: Int { lock.withLock { defaults.integer(forKey: Self.key(for: now())) } }

    public func record(_ count: Int = 1) {
        lock.withLock {
            let key = Self.key(for: now())
            defaults.set(defaults.integer(forKey: key) + count, forKey: key)
        }
    }

    /// Automatic syncs wait for the next month.
    public var pausesAutomaticSyncs: Bool {
        Double(thisMonth) >= Double(Self.freeCalls) * Self.pauseShare
    }

    /// Seconds until the first day of next month (Europe/Berlin), for `rateLimited(retryAfter:)`.
    public var untilNextMonth: TimeInterval {
        let today = BankDay(now())
        guard let first = BankDay(year: today.month == 12 ? today.year + 1 : today.year, month: today.month == 12 ? 1 : today.month + 1, day: 1) else {
            return 24 * 60 * 60
        }
        return max(60, first.startDate.timeIntervalSince(now()))
    }
}
