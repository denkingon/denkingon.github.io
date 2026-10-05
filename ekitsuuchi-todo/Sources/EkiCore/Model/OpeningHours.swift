import Foundation

// 営業時間（曜日別＋特別日）。Google Places (New) の regularOpeningHours / currentOpeningHours の写し。
// 評価（今開いているか・いつ閉まるか）は Hours/OpeningHoursEvaluator.swift の `status(at:)`。
// 時刻はすべてその店のローカル時刻（timeZoneID）での「0 時からの分」。

/// 曜日別の営業枠。day は 0=日曜 … 6=土曜（Places と同じ）。閉店が翌日以降にまたがるときは closeDay が違う。
public struct WeeklyPeriod: Codable, Equatable, Sendable {
    public var openDay: Int
    public var openMinute: Int       // 0..<1440
    public var closeDay: Int
    public var closeMinute: Int      // 0..<1440 (24:00 閉店は closeDay が翌日の 0 分)

    public init(openDay: Int, openMinute: Int, closeDay: Int, closeMinute: Int) {
        self.openDay = openDay
        self.openMinute = openMinute
        self.closeDay = closeDay
        self.closeMinute = closeMinute
    }
}

/// 特別日の 1 日の中の営業枠。
public struct DayPeriod: Codable, Equatable, Sendable {
    public var openMinute: Int       // 0..<1440
    /// 1...2880. 1440 を超えたら翌日にまたがって閉まる（25:00 閉店 = 1500）。
    public var closeMinute: Int

    public init(openMinute: Int, closeMinute: Int) {
        self.openMinute = openMinute
        self.closeMinute = closeMinute
    }
}

/// 特別営業日。その日は weekly を使わずこの枠だけで判定する。periods が空なら終日休み。
public struct SpecialDay: Codable, Equatable, Sendable {
    public var date: CalendarDay
    public var periods: [DayPeriod]

    public init(date: CalendarDay, periods: [DayPeriod]) {
        self.date = date
        self.periods = periods
    }
}

public struct OpeningHours: Codable, Equatable, Sendable {
    /// IANA id. Places が返さないときは "Asia/Tokyo"（日本の店だけを扱うため）。
    public var timeZoneID: String
    /// 24 時間営業・年中無休（Places: 日曜 0:00 開店で close なしの 1 枠）。
    public var isAlwaysOpen: Bool
    public var weekly: [WeeklyPeriod]
    public var specialDays: [SpecialDay]

    public init(
        timeZoneID: String = "Asia/Tokyo",
        isAlwaysOpen: Bool = false,
        weekly: [WeeklyPeriod] = [],
        specialDays: [SpecialDay] = []
    ) {
        self.timeZoneID = timeZoneID
        self.isAlwaysOpen = isAlwaysOpen
        self.weekly = weekly
        self.specialDays = specialDays
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "Asia/Tokyo") ?? .current }
}

/// `OpeningHours.status(at:)` の結果。
public enum HoursStatus: Equatable, Sendable {
    /// 営業中。closesAt が nil なら閉店時刻なし（24 時間営業）。
    case open(closesAt: Date?)
    /// 営業時間外。nextOpenAt は次に開く時刻（分かれば）。
    case closed(nextOpenAt: Date?)
}
