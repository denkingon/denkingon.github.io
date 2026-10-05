import XCTest
@testable import EkiCore

/// 営業時間の評価（§4）。基準日: 2026-10-05 は月曜、10-02 金・10-03 土・10-04 日。
final class HoursTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    // MARK: helpers

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, tz: TimeZone? = nil) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? tokyo
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { CalendarDay(year: y, month: m, day: d) }

    /// 毎日 open〜close（分）。close <= 1440 で同日閉店。
    private func daily(_ open: Int, _ close: Int, tz: String = "Asia/Tokyo") -> OpeningHours {
        OpeningHours(timeZoneID: tz, weekly: (0...6).map { WeeklyPeriod(openDay: $0, openMinute: open, closeDay: $0, closeMinute: close) })
    }

    private let h10 = 10 * 60, h21 = 21 * 60

    // MARK: 基本

    func testInsideBeforeAfter() {
        let hours = daily(h10, h21)
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 15)), .open(closesAt: at(2026, 10, 5, 21)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 8)), .closed(nextOpenAt: at(2026, 10, 5, 10)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 22)), .closed(nextOpenAt: at(2026, 10, 6, 10)))
    }

    func testOpenBoundaryIsInclusive() {
        let hours = daily(h10, h21)
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 10, 0, 0)), .open(closesAt: at(2026, 10, 5, 21)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 9, 59, 59)), .closed(nextOpenAt: at(2026, 10, 5, 10)))
    }

    func testCloseBoundaryIsExclusive() {
        let hours = daily(h10, h21)
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 20, 59, 59)), .open(closesAt: at(2026, 10, 5, 21)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 21, 0, 0)), .closed(nextOpenAt: at(2026, 10, 6, 10)))
    }

    // MARK: 閉店までの余裕（§4 30 分）

    func testMarginThirtyMinutesBeforeClosing() {
        let hours = daily(h10, h21)
        XCTAssertTrue(hours.isOpen(at: at(2026, 10, 5, 20, 30, 0), minimumRemainingMinutes: 30), "ちょうど 30 分は足りる")
        XCTAssertFalse(hours.isOpen(at: at(2026, 10, 5, 20, 30, 1), minimumRemainingMinutes: 30))
        XCTAssertTrue(hours.isOpen(at: at(2026, 10, 5, 20, 29, 59), minimumRemainingMinutes: 30))
    }

    func testMarginZeroAndNegativeStillRespectClosing() {
        let hours = daily(h10, h21)
        XCTAssertTrue(hours.isOpen(at: at(2026, 10, 5, 20, 59, 59), minimumRemainingMinutes: 0))
        XCTAssertFalse(hours.isOpen(at: at(2026, 10, 5, 21, 0, 0), minimumRemainingMinutes: 0))
        XCTAssertFalse(hours.isOpen(at: at(2026, 10, 5, 21, 0, 0), minimumRemainingMinutes: -10))
        XCTAssertFalse(hours.isOpen(at: at(2026, 10, 5, 9, 59, 59), minimumRemainingMinutes: 0))
    }

    func testMarginAcrossMergedRunUsesFinalClose() {
        // 24:00 閉店 + 0:00 開店の続き: 23:50 でも終端は翌 03:00 なので 30 分の余裕がある。
        let hours = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: h10, closeDay: 2, closeMinute: 0),
            WeeklyPeriod(openDay: 2, openMinute: 0, closeDay: 2, closeMinute: 180),
        ])
        XCTAssertTrue(hours.isOpen(at: at(2026, 10, 5, 23, 50), minimumRemainingMinutes: 30))
    }

    // MARK: 深夜営業・24:00

    func testOvernightSpillFridayToSaturday() {
        // 金 18:00 → 土 02:00
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 5, openMinute: 18 * 60, closeDay: 6, closeMinute: 2 * 60)])
        XCTAssertEqual(hours.status(at: at(2026, 10, 3, 1, 0)), .open(closesAt: at(2026, 10, 3, 2)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 2, 17, 59, 59)), .closed(nextOpenAt: at(2026, 10, 2, 18)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 3, 2, 0, 0)), .closed(nextOpenAt: at(2026, 10, 9, 18)))
    }

    func testOvernightSpillAcrossSaturdayToSundayWrap() {
        // 土 22:00 → 日 02:00（週の折り返し）
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 6, openMinute: 22 * 60, closeDay: 0, closeMinute: 2 * 60)])
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 1, 0)), .open(closesAt: at(2026, 10, 4, 2)))
    }

    func testMidnightCloseIs24h() {
        // 月 10:00 → 火 0:00（24:00 閉店）。他に枠がなければ 0:00 ちょうどで閉まる。
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: h10, closeDay: 2, closeMinute: 0)])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 23, 59, 59)), .open(closesAt: at(2026, 10, 6, 0)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 0, 0, 0)), .closed(nextOpenAt: at(2026, 10, 12, 10)))
    }

    func testTouchingIntervalsMergeIntoOneRun() {
        let hours = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: h10, closeDay: 2, closeMinute: 0),
            WeeklyPeriod(openDay: 2, openMinute: 0, closeDay: 2, closeMinute: 3 * 60),
        ])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 23, 0)), .open(closesAt: at(2026, 10, 6, 3)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 0, 0, 0)), .open(closesAt: at(2026, 10, 6, 3)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 3, 0, 0)), .closed(nextOpenAt: at(2026, 10, 12, 10)))
    }

    func testOverlappingIntervalsMerge() {
        let hours = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 1, closeMinute: 15 * 60),
            WeeklyPeriod(openDay: 1, openMinute: 14 * 60, closeDay: 1, closeMinute: 18 * 60),
        ])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 11)), .open(closesAt: at(2026, 10, 5, 18)))
    }

    func testAnOverlongRunIsNotCutAtItsFirstPeriodsEnd() {
        // 大きい枠の中に小さい枠が入っていても終端は大きい方。
        let hours = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 1, closeMinute: 20 * 60),
            WeeklyPeriod(openDay: 1, openMinute: 11 * 60, closeDay: 1, closeMinute: 12 * 60),
        ])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 13)), .open(closesAt: at(2026, 10, 5, 20)))
    }

    // MARK: 特別日

    func testSpecialDayClosedAllDay() {
        // 年始休み: 2027-01-01（金）は終日休み。年またぎでも次の営業日を返す。
        var hours = daily(h10, h21)
        hours.specialDays = [SpecialDay(date: day(2027, 1, 1), periods: [])]
        XCTAssertEqual(hours.status(at: at(2027, 1, 1, 12)), .closed(nextOpenAt: at(2027, 1, 2, 10)))
        XCTAssertEqual(hours.status(at: at(2026, 12, 31, 22)), .closed(nextOpenAt: at(2027, 1, 2, 10)))
        XCTAssertFalse(hours.isOpen(at: at(2027, 1, 1, 12), minimumRemainingMinutes: 30))
        XCTAssertEqual(hours.status(at: at(2026, 12, 31, 12)), .open(closesAt: at(2026, 12, 31, 21)))
    }

    func testSpecialDayWithDifferentHoursReplacesWeekly() {
        var hours = daily(h10, h21)
        hours.specialDays = [SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 12 * 60, closeMinute: 15 * 60)])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 11)), .closed(nextOpenAt: at(2026, 10, 5, 12)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 13)), .open(closesAt: at(2026, 10, 5, 15)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 20)), .closed(nextOpenAt: at(2026, 10, 6, 10)), "週枠の 10-21 は無効")
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 11)), .open(closesAt: at(2026, 10, 6, 21)), "翌日は通常")
    }

    func testSpecialDayDoesNotCutPreviousDaysOvernightSpill() {
        // 土 22:00→日 02:00。日曜が特別休業でも、土曜に開いた枠の日曜 01:00 は営業中のまま。
        var hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 6, openMinute: 22 * 60, closeDay: 0, closeMinute: 2 * 60)])
        hours.specialDays = [SpecialDay(date: day(2026, 10, 4), periods: [])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 1)), .open(closesAt: at(2026, 10, 4, 2)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 12)), .closed(nextOpenAt: at(2026, 10, 10, 22)))
    }

    func testSpecialDayClosedOnTheDaySpillStartsSuppressesThatSpill() {
        // 土曜が特別休業なら、土曜に開く週枠（→日曜 02:00）は無い。日曜 01:00 も閉まっている。
        var hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 6, openMinute: 22 * 60, closeDay: 0, closeMinute: 2 * 60)])
        hours.specialDays = [SpecialDay(date: day(2026, 10, 3), periods: [])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 1)), .closed(nextOpenAt: at(2026, 10, 10, 22)))
    }

    func testSpecialDayPeriodCanSpillPastMidnight() {
        var hours = OpeningHours()
        hours.specialDays = [SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 18 * 60, closeMinute: 25 * 60)])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 0, 30)), .open(closesAt: at(2026, 10, 6, 1)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 1, 0, 0)), .closed(nextOpenAt: nil))
    }

    func testSpecialDayPeriodUpTo2880IsNextDayClose() {
        var hours = OpeningHours()
        hours.specialDays = [SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 600, closeMinute: 2880)])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 23, 59)), .open(closesAt: at(2026, 10, 7, 0)))
    }

    func testSpecialDayMultiplePeriodsUnsortedAndDuplicateEntriesCombine() {
        var hours = OpeningHours()
        hours.specialDays = [
            SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 17 * 60, closeMinute: 20 * 60), DayPeriod(openMinute: 10 * 60, closeMinute: 12 * 60)]),
            SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 13 * 60, closeMinute: 14 * 60)]),
        ]
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 11)), .open(closesAt: at(2026, 10, 5, 12)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 12, 30)), .closed(nextOpenAt: at(2026, 10, 5, 13)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 15)), .closed(nextOpenAt: at(2026, 10, 5, 17)))
    }

    // MARK: 常時営業・空・不正

    func testAlwaysOpen() {
        let hours = OpeningHours(isAlwaysOpen: true)
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 3)), .open(closesAt: nil))
        XCTAssertTrue(hours.isOpen(at: at(2026, 10, 5, 3), minimumRemainingMinutes: 100_000))
    }

    func testEmptyHoursAreClosedForever() {
        let hours = OpeningHours()
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 12)), .closed(nextOpenAt: nil))
        XCTAssertFalse(hours.isOpen(at: at(2026, 10, 5, 12), minimumRemainingMinutes: 0))
    }

    func testInvalidWeeklyPeriodsAreSkippedWithoutCrash() {
        let hours = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 600),     // 同日で長さ 0
            WeeklyPeriod(openDay: 1, openMinute: 900, closeDay: 1, closeMinute: 600),     // 同日で閉店 < 開店
            WeeklyPeriod(openDay: 9, openMinute: 600, closeDay: 1, closeMinute: 700),     // 曜日が範囲外
            WeeklyPeriod(openDay: 1, openMinute: -5, closeDay: 1, closeMinute: 700),
            WeeklyPeriod(openDay: 1, openMinute: 100, closeDay: 1, closeMinute: 9_999),
            WeeklyPeriod(openDay: 2, openMinute: 600, closeDay: 2, closeMinute: 700),     // これだけ有効
        ])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 10, 30)), .closed(nextOpenAt: at(2026, 10, 6, 10)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 6, 10, 30)), .open(closesAt: at(2026, 10, 6, 11, 40)))
    }

    func testInvalidSpecialPeriodsAreSkipped() {
        var hours = OpeningHours()
        hours.specialDays = [SpecialDay(date: day(2026, 10, 5), periods: [
            DayPeriod(openMinute: 600, closeMinute: 600),
            DayPeriod(openMinute: 700, closeMinute: 600),
            DayPeriod(openMinute: 600, closeMinute: 3000),
            DayPeriod(openMinute: 1440, closeMinute: 1500),
            DayPeriod(openMinute: 800, closeMinute: 900),
        ])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 12)), .closed(nextOpenAt: at(2026, 10, 5, 13, 20)))
    }

    // MARK: 曜日・時間帯

    func testSundayIsZero() {
        // 日曜（0）だけ 10-18。2026-10-04 が日曜。
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 0, openMinute: h10, closeDay: 0, closeMinute: 18 * 60)])
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 12)), .open(closesAt: at(2026, 10, 4, 18)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 12)), .closed(nextOpenAt: at(2026, 10, 11, 10)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 3, 12)), .closed(nextOpenAt: at(2026, 10, 4, 10)))
    }

    func testSaturdayIsSix() {
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 6, openMinute: h10, closeDay: 6, closeMinute: 18 * 60)])
        XCTAssertEqual(hours.status(at: at(2026, 10, 3, 12)), .open(closesAt: at(2026, 10, 3, 18)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 2, 12)), .closed(nextOpenAt: at(2026, 10, 3, 10)))
    }

    func testDifferentHoursPerWeekday() {
        // 平日 10-21、日曜だけ 11-19。
        var weekly = (1...6).map { WeeklyPeriod(openDay: $0, openMinute: h10, closeDay: $0, closeMinute: h21) }
        weekly.append(WeeklyPeriod(openDay: 0, openMinute: 11 * 60, closeDay: 0, closeMinute: 19 * 60))
        let hours = OpeningHours(weekly: weekly)
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 10, 30)), .closed(nextOpenAt: at(2026, 10, 4, 11)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 18)), .open(closesAt: at(2026, 10, 4, 19)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 20)), .open(closesAt: at(2026, 10, 5, 21)))
    }

    func testUnsortedInputPeriods() {
        let hours = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 3, openMinute: h10, closeDay: 3, closeMinute: h21),
            WeeklyPeriod(openDay: 1, openMinute: 17 * 60, closeDay: 1, closeMinute: h21),
            WeeklyPeriod(openDay: 2, openMinute: h10, closeDay: 2, closeMinute: h21),
            WeeklyPeriod(openDay: 1, openMinute: h10, closeDay: 1, closeMinute: 14 * 60),
        ])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 12)), .open(closesAt: at(2026, 10, 5, 14)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 15)), .closed(nextOpenAt: at(2026, 10, 5, 17)))
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 22)), .closed(nextOpenAt: at(2026, 10, 6, 10)))
    }

    // MARK: 時間帯・窓

    func testBranchTimeZoneIsUsedNotUTC() {
        // 2026-10-04 16:00 UTC（日曜）= 月曜 01:00 JST。月曜 0:00-3:00 の店は開いている。
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let instant = utcCal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 16))!
        XCTAssertEqual(instant, at(2026, 10, 5, 1, 0))
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 0, closeDay: 1, closeMinute: 180)])
        XCTAssertEqual(hours.status(at: instant), .open(closesAt: at(2026, 10, 5, 3)))
        // 同じ瞬間でもニューヨークの店では日曜の昼（12:00 EDT）。
        let nyZone = TimeZone(identifier: "America/New_York")!
        let ny = OpeningHours(timeZoneID: "America/New_York", weekly: [WeeklyPeriod(openDay: 0, openMinute: h10, closeDay: 0, closeMinute: 18 * 60)])
        XCTAssertEqual(ny.status(at: instant), .open(closesAt: at(2026, 10, 4, 18, tz: nyZone)))
    }

    func testSpecialDayIsInterpretedInBranchZone() {
        // 月曜 01:00 JST は UTC では日曜。特別日（月曜 = 10-05）は JST の暦で当たる。
        let instant = at(2026, 10, 5, 1, 0)
        var hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 0, openMinute: 0, closeDay: 0, closeMinute: 1439)])
        hours.specialDays = [SpecialDay(date: day(2026, 10, 5), periods: [DayPeriod(openMinute: 0, closeMinute: 120)])]
        XCTAssertEqual(hours.status(at: instant), .open(closesAt: at(2026, 10, 5, 2)))
    }

    func testDSTFallBackUsesWallClockNotFixedSeconds() {
        // 米東部は 2026-11-01 02:00 に夏時間が終わる。土 22:00→日 06:00 の枠は実時間で 9 時間。
        let ny = TimeZone(identifier: "America/New_York")!
        let hours = OpeningHours(timeZoneID: "America/New_York", weekly: [WeeklyPeriod(openDay: 6, openMinute: 22 * 60, closeDay: 0, closeMinute: 6 * 60)])
        let close = at(2026, 11, 1, 6, 0, tz: ny)
        XCTAssertEqual(hours.status(at: at(2026, 11, 1, 5, 30, tz: ny)), .open(closesAt: close))
        XCTAssertEqual(close.timeIntervalSince(at(2026, 10, 31, 22, 0, tz: ny)), 9 * 3600)
    }

    func testNextOpenAtWindowEdges() {
        // 窓は「今日 + 14 日」まで。それより先の特別日しか無ければ nil。
        let now = at(2026, 10, 5, 12)
        var inside = OpeningHours()
        inside.specialDays = [SpecialDay(date: day(2026, 10, 19), periods: [DayPeriod(openMinute: 600, closeMinute: 700)])]
        XCTAssertEqual(inside.status(at: now), .closed(nextOpenAt: at(2026, 10, 19, 10)))
        var outside = OpeningHours()
        outside.specialDays = [SpecialDay(date: day(2026, 10, 20), periods: [DayPeriod(openMinute: 600, closeMinute: 700)])]
        XCTAssertEqual(outside.status(at: now), .closed(nextOpenAt: nil))
    }

    func testLookBackCoversOldSpecialDayStillOpen() {
        // 前日開店の特別日が翌々日 0 時（2880）まで続く場合、今日がその翌日でも営業中。
        var hours = OpeningHours()
        hours.specialDays = [SpecialDay(date: day(2026, 10, 3), periods: [DayPeriod(openMinute: 600, closeMinute: 2880)])]
        XCTAssertEqual(hours.status(at: at(2026, 10, 4, 12)), .open(closesAt: at(2026, 10, 5, 0)))
    }

    func testNextOpenAtIsEarliestStartAfterNowNotAnEarlierFinishedRun() {
        let hours = daily(h10, h21)
        // 今日の枠はもう終わっている。次は明日（今日の 10:00 ではない）。
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 23)), .closed(nextOpenAt: at(2026, 10, 6, 10)))
    }

    func testHoursStatusAtYearBoundaryWithOvernight() {
        // 木 2026-12-31 18:00 → 金 2027-01-01 02:00
        let hours = OpeningHours(weekly: [WeeklyPeriod(openDay: 4, openMinute: 18 * 60, closeDay: 5, closeMinute: 120)])
        XCTAssertEqual(hours.status(at: at(2027, 1, 1, 1)), .open(closesAt: at(2027, 1, 1, 2)))
    }

    func testUnknownTimeZoneIDFallsBackToTokyo() {
        let hours = OpeningHours(timeZoneID: "Nowhere/Land", weekly: [WeeklyPeriod(openDay: 1, openMinute: 0, closeDay: 1, closeMinute: 180)])
        XCTAssertEqual(hours.status(at: at(2026, 10, 5, 1)), .open(closesAt: at(2026, 10, 5, 3)))
    }
}
