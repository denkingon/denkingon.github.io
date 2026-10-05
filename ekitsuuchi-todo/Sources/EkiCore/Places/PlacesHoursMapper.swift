import Foundation

/// Places の営業時間応答 → `OpeningHours`。純粋関数（通信なし）。
/// 読めない枠は捨てる（1 枠の不正で店ごと使えなくならないように）。捨てた結果、何も残らなければ nil。
enum PlacesHoursMapper {
    static let defaultTimeZoneID = "Asia/Tokyo"

    static func map(_ response: PlacesAPI.PlaceHoursResponse) -> OpeningHours? {
        let regularPeriods = response.regularOpeningHours?.periods ?? []

        // 24 時間営業: 日曜 0:00 開店で close なしの 1 枠だけ（Places の表現）。
        let alwaysOpen: Bool = {
            guard regularPeriods.count == 1, let p = regularPeriods.first, p.close == nil, let open = p.open else { return false }
            return open.resolvedDay == 0 && open.resolvedHour == 0 && open.resolvedMinute == 0
        }()
        let weekly: [WeeklyPeriod] = alwaysOpen ? [] : regularPeriods.compactMap(weeklyPeriod).sorted {
            ($0.openDay, $0.openMinute) < ($1.openDay, $1.openMinute)
        }
        let specialDays = mapSpecialDays(response.currentOpeningHours)

        // 通常の営業時間が無い = Places にその店の営業時間が無い（特別日だけでは nil）。
        // 特別日だけ持たせると、評価器が「特別日以外は終日休み」と読んで通知を止めてしまう（D4: 不明は営業中扱い）。
        guard alwaysOpen || !weekly.isEmpty else { return nil }

        return OpeningHours(
            timeZoneID: timeZoneID(response.timeZone?.id),
            isAlwaysOpen: alwaysOpen,
            weekly: weekly,
            specialDays: specialDays
        )
    }

    // MARK: weekly

    private static func weeklyPeriod(_ p: PlacesAPI.Period) -> WeeklyPeriod? {
        guard let open = p.open, let close = p.close,
              let openMinute = minuteOfDay(open), let closeMinute = minuteOfDay(close),
              (0...6).contains(open.resolvedDay), (0...6).contains(close.resolvedDay) else { return nil }
        // 同じ曜日で閉店が開店以前 = 不正（1 週間ぶんの営業にはしない）。
        if open.resolvedDay == close.resolvedDay && closeMinute <= openMinute { return nil }
        return WeeklyPeriod(openDay: open.resolvedDay, openMinute: openMinute, closeDay: close.resolvedDay, closeMinute: closeMinute)
    }

    // MARK: special days

    private static func mapSpecialDays(_ block: PlacesAPI.HoursBlock?) -> [SpecialDay] {
        guard let block, let entries = block.specialDays, !entries.isEmpty else { return [] }
        let periods = block.periods ?? []
        // 枠に日付が 1 つも付いていないと、特別日の枠を日付に結び付けられない。
        // ここで「枠なし = 終日休み」と読むと誤って休みにしてしまい通知が止まるので、特別日ごと捨てる。
        if !periods.isEmpty && !periods.contains(where: { $0.open?.date != nil }) { return [] }

        var seen = Set<CalendarDay>()
        var result: [SpecialDay] = []
        for entry in entries {
            guard let day = calendarDay(entry.date), seen.insert(day).inserted else { continue }
            let dayPeriods = periods.compactMap { dayPeriod($0, on: day) }.sorted { $0.openMinute < $1.openMinute }
            result.append(SpecialDay(date: day, periods: dayPeriods))   // 枠なし = 終日休み
        }
        return result.sorted { $0.date < $1.date }
    }

    /// `period` が `day` に開く枠なら DayPeriod。閉店が翌日なら 1440 を足す。
    private static func dayPeriod(_ p: PlacesAPI.Period, on day: CalendarDay) -> DayPeriod? {
        guard let open = p.open, calendarDay(open.date) == day, let openMinute = minuteOfDay(open) else { return nil }
        guard let close = p.close else { return DayPeriod(openMinute: openMinute, closeMinute: 1440) }   // close 無し = その日の終わりまで
        guard let closeMinuteOfDay = minuteOfDay(close) else { return nil }

        let dayDiff: Int
        if let closeDate = calendarDay(close.date) {
            dayDiff = dayNumber(closeDate) - dayNumber(day)
        } else {
            guard (0...6).contains(open.resolvedDay), (0...6).contains(close.resolvedDay) else { return nil }
            dayDiff = (close.resolvedDay - open.resolvedDay + 7) % 7
        }
        let closeMinute = closeMinuteOfDay + 1440 * dayDiff
        guard dayDiff >= 0, closeMinute > openMinute, closeMinute <= 2880 else { return nil }
        return DayPeriod(openMinute: openMinute, closeMinute: closeMinute)
    }

    // MARK: helpers

    private static func minuteOfDay(_ p: PlacesAPI.Point) -> Int? {
        guard (0...23).contains(p.resolvedHour), (0...59).contains(p.resolvedMinute) else { return nil }
        return p.resolvedHour * 60 + p.resolvedMinute
    }

    /// 暦として存在しない日付（2026-02-30 など）は nil。
    private static func calendarDay(_ d: PlacesAPI.DateParts?) -> CalendarDay? {
        guard let d, let y = d.year, let m = d.month, let day = d.day else { return nil }
        return CalendarDay(isoString: String(format: "%04d-%02d-%02d", y, m, day))
    }

    private static func timeZoneID(_ id: String?) -> String {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              TimeZone(identifier: id) != nil else { return defaultTimeZoneID }
        return id
    }

    /// 1970-01-01 からの通し日数（グレゴリオ暦）。日付の差を Calendar なしで出す。
    private static func dayNumber(_ d: CalendarDay) -> Int {
        let y = d.month <= 2 ? d.year - 1 : d.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (d.month + 9) % 12
        let doy = (153 * mp + 2) / 5 + d.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
