import XCTest
@testable import EkiCore

/// 店画面の「今日の営業時間」。基準: 2026-10-05 は月曜、10-04 日、10-03 土、10-02 金。
final class OpeningHoursSummaryTests: XCTestCase {
    typealias F = JudgeFixtures
    private let monday = F.at(2026, 10, 5, 15)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { CalendarDay(year: y, month: m, day: d) }

    func test普通の一日() {
        XCTAssertEqual(F.h10to21.todayText(at: monday), "10:00–21:00")
    }

    func test分と先頭ゼロ() {
        XCTAssertEqual(F.daily(9 * 60 + 5, 20 * 60 + 30).todayText(at: monday), "09:05–20:30")
    }

    func test昼休みなど複数枠() {
        let h = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 17 * 60, closeDay: 1, closeMinute: 22 * 60),
            WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 1, closeMinute: 14 * 60),
        ])
        XCTAssertEqual(h.todayText(at: monday), "10:00–14:00、17:00–22:00", "順不同の入力も開店順に")
    }

    func test接触する枠は1本にまとめる() {
        let h = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 1, closeMinute: 14 * 60),
            WeeklyPeriod(openDay: 1, openMinute: 14 * 60, closeDay: 1, closeMinute: 20 * 60),
        ])
        XCTAssertEqual(h.todayText(at: monday), "10:00–20:00")
    }

    func test閉店が翌0時なら24時() {
        XCTAssertEqual(F.daily(10 * 60, 1440).todayText(at: monday), "10:00–24:00")
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 2, closeMinute: 0)])
        XCTAssertEqual(h.todayText(at: monday), "10:00–24:00")
    }

    func test翌日にまたがる閉店() {
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 18 * 60, closeDay: 2, closeMinute: 2 * 60)])
        XCTAssertEqual(h.todayText(at: monday), "18:00–翌2:00")
        let half = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 18 * 60, closeDay: 2, closeMinute: 90)])
        XCTAssertEqual(half.todayText(at: monday), "18:00–翌1:30")
    }

    func test前日から続く深夜営業は今日の枠に出さない() {
        // 日曜 18:00→月曜 02:00。月曜に開く枠は無い。
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 0, openMinute: 18 * 60, closeDay: 1, closeMinute: 2 * 60)])
        XCTAssertEqual(h.todayText(at: monday), "休み")
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 4, 12)), "18:00–翌2:00")
    }

    func test24時間営業() {
        XCTAssertEqual(OpeningHours(isAlwaysOpen: true).todayText(at: monday), "24時間営業")
    }

    func test今日開く枠が無ければ休み_空の営業時間も() {
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 2, openMinute: 600, closeDay: 2, closeMinute: 1200)])
        XCTAssertEqual(h.todayText(at: monday), "休み")
        XCTAssertEqual(OpeningHours().todayText(at: monday), "休み")
    }

    func test曜日の対応_日曜は0() {
        let h = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 0, openMinute: 11 * 60, closeDay: 0, closeMinute: 19 * 60),
            WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 1, closeMinute: 21 * 60),
        ])
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 4, 12)), "11:00–19:00")
        XCTAssertEqual(h.todayText(at: monday), "10:00–21:00")
    }

    func test特別日は週枠を置き換える() {
        let h = OpeningHours(weekly: F.daily(10 * 60, 21 * 60).weekly, specialDays: [
            SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 10 * 60, closeMinute: 17 * 60)]),
        ])
        XCTAssertEqual(h.todayText(at: monday), "10:00–17:00")
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 6, 12)), "10:00–21:00")
    }

    func test特別日で終日休み() {
        let h = OpeningHours(weekly: F.daily(10 * 60, 21 * 60).weekly, specialDays: [SpecialDay(date: day(2026, 10, 5), periods: [])])
        XCTAssertEqual(h.todayText(at: monday), "休み")
    }

    func test特別日の翌日にまたがる枠() {
        let h = OpeningHours(specialDays: [SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 18 * 60, closeMinute: 1440 + 120)])])
        XCTAssertEqual(h.todayText(at: monday), "18:00–翌2:00")
    }

    func test今日の日付は店のタイムゾーンで決まる() {
        // 2026-10-04 16:00 UTC = 日曜 → 東京では月曜 01:00。
        let instant = F.at(2026, 10, 4, 16, tz: F.utc)
        let h = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 0, openMinute: 11 * 60, closeDay: 0, closeMinute: 19 * 60),
            WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 1, closeMinute: 21 * 60),
        ])
        XCTAssertEqual(h.todayText(at: instant), "10:00–21:00")
        var utcHours = h
        utcHours.timeZoneID = "UTC"
        XCTAssertEqual(utcHours.todayText(at: instant), "11:00–19:00")
    }

    func test日付の切れ目() {
        XCTAssertEqual(F.h10to21.todayText(at: F.at(2026, 10, 5, 23, 59, 59)), "10:00–21:00")
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 2, openMinute: 600, closeDay: 2, closeMinute: 1200)])
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 5, 23, 59, 59)), "休み")
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 6, 0, 0, 0)), "10:00–20:00")
    }

    func test不正な枠は無視して落ちない() {
        let h = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 600),     // 長さ 0
            WeeklyPeriod(openDay: 1, openMinute: 700, closeDay: 1, closeMinute: 600),     // 閉店 < 開店（同日）
            WeeklyPeriod(openDay: 9, openMinute: 600, closeDay: 1, closeMinute: 700),     // 曜日が範囲外
        ])
        XCTAssertEqual(h.todayText(at: monday), "休み")
    }
}
