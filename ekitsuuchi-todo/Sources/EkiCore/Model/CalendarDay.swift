import Foundation

/// 暦の日付（時刻・タイムゾーンを持たない）。出典日・特別営業日・「今日通知済」の判定に使う。
/// JSON では "yyyy-MM-dd" の文字列。Date と TimeZone の取り違えを型で防ぐ。
public struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The calendar day that `date` falls on in `timeZone`.
    public init(date: Date, timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Strict "yyyy-MM-dd". Returns nil for anything else, including impossible dates like 2026-02-30.
    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let candidate = CalendarDay(year: y, month: m, day: d)
        guard candidate.isValid else { return nil }
        self = candidate
    }

    public var isoString: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { isoString }

    private static var utc: TimeZone { TimeZone(identifier: "UTC")! }

    private var isValid: Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        guard let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return false }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return c.year == year && c.month == month && c.day == day
    }

    /// 0 = Sunday … 6 = Saturday (the Google Places convention).
    public var weekdayIndex: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
        return cal.component(.weekday, from: d) - 1
    }

    public func addingDays(_ n: Int) -> CalendarDay {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        guard let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              let shifted = cal.date(byAdding: .day, value: n, to: d) else { return self }
        return CalendarDay(date: shifted, timeZone: Self.utc)
    }

    /// The instant at which this day begins in `timeZone`.
    public func startOfDay(in timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

extension CalendarDay: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = CalendarDay(isoString: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected yyyy-MM-dd, got \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(isoString)
    }
}
