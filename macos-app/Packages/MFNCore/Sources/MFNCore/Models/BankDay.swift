import Foundation

/// A calendar day as banks use it (booking date, value date, statement period).
///
/// Banks speak in calendar days, not instants. Modelling them as `Date` invites time-zone bugs
/// (a booking on the 1st turning into the 31st), so MFN uses this value type for every banking date.
/// Instants (`asOf`, sync timestamps, `since`) stay `Date`.
public struct BankDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// The time zone all German banks book in.
    public static let bankTimeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BankDay.bankTimeZone
        return calendar
    }()

    /// Creates a day; returns `nil` for impossible dates such as 2025-02-30.
    public init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: Self.calendar) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The bank day containing `date` in the bank time zone (Europe/Berlin).
    public init(_ date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        // Calendar always yields these components for a gregorian calendar.
        self.year = parts.year ?? 1970
        self.month = parts.month ?? 1
        self.day = parts.day ?? 1
    }

    /// Parses `yyyy-MM-dd`.
    public init?(iso string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Midnight at the start of this day in the bank time zone.
    public var startDate: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public func adding(days: Int) -> BankDay {
        guard let date = Self.calendar.date(byAdding: .day, value: days, to: startDate) else { return self }
        return BankDay(date)
    }

    public func adding(months: Int) -> BankDay {
        guard let date = Self.calendar.date(byAdding: .month, value: months, to: startDate) else { return self }
        return BankDay(date)
    }

    /// Whole days from `self` to `other` (positive if `other` is later).
    public func days(to other: BankDay) -> Int {
        Self.calendar.dateComponents([.day], from: startDate, to: other.startDate).day ?? 0
    }

    /// 1 = Sunday … 7 = Saturday (gregorian convention).
    public var weekday: Int {
        Self.calendar.component(.weekday, from: startDate)
    }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso }

    public static func < (lhs: BankDay, rhs: BankDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static var today: BankDay { BankDay(Date()) }
}

extension BankDay: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = BankDay(iso: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid bank day \(string)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}
