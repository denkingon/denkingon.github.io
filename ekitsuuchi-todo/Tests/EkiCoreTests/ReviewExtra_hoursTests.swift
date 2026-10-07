import XCTest
@testable import EkiCore

/// 独立レビューで足した敵対テスト（営業時間）。
final class ReviewExtraHoursTests: XCTestCase {
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, tz: String = "Asia/Tokyo") -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func daily(_ open: Int, _ close: Int, tz: String = "Asia/Tokyo") -> OpeningHours {
        OpeningHours(timeZoneID: tz, weekly: (0...6).map { WeeklyPeriod(openDay: $0, openMinute: open, closeDay: $0, closeMinute: close) })
    }

    func testSpringForwardClosesAtWallClockFourOClock() {
        // 2026-03-08 NY: 02:00 -> 03:00 が飛ぶ。日曜 01:00〜04:00 は実時間 2 時間。
        let h = OpeningHours(timeZoneID: "America/New_York",
                             weekly: [WeeklyPeriod(openDay: 0, openMinute: 60, closeDay: 0, closeMinute: 240)])
        let now = at(2026, 3, 8, 1, 30, tz: "America/New_York")
        XCTAssertEqual(h.status(at: now), .open(closesAt: at(2026, 3, 8, 4, 0, tz: "America/New_York")))
        XCTAssertEqual(at(2026, 3, 8, 4, tz: "America/New_York").timeIntervalSince(at(2026, 3, 8, 1, tz: "America/New_York")), 7200)
    }

    func testPeriodInsideSpringForwardGapDoesNotCrashOrInvert() {
        let h = OpeningHours(timeZoneID: "America/New_York",
                             weekly: [WeeklyPeriod(openDay: 0, openMinute: 135, closeDay: 0, closeMinute: 165)])
        let now = at(2026, 3, 8, 12, tz: "America/New_York")
        // 落ちないこと、nextOpenAt が来週以降か nil であること。
        switch h.status(at: now) {
        case .closed(let next): if let next { XCTAssertGreaterThan(next, now) }
        case .open: XCTFail()
        }
    }

    func testHalfHourDSTZoneLordHowe() {
        // Lord Howe は DST が 30 分。壁時計で組むので 21:00 閉店は 21:00 のまま。
        let h = daily(600, 1260, tz: "Australia/Lord_Howe")
        for d in [(2026, 10, 3), (2026, 10, 4), (2026, 10, 5), (2026, 4, 5), (2026, 4, 4)] {
            let now = at(d.0, d.1, d.2, 15, tz: "Australia/Lord_Howe")
            XCTAssertEqual(h.status(at: now), .open(closesAt: at(d.0, d.1, d.2, 21, tz: "Australia/Lord_Howe")), "\(d)")
        }
    }

    func testFractionalSecondsAtBoundaries() {
        let h = daily(600, 1260)
        let close = at(2026, 10, 5, 21)
        XCTAssertEqual(h.status(at: close.addingTimeInterval(-0.001)), .open(closesAt: close))
        XCTAssertEqual(h.status(at: close), .closed(nextOpenAt: at(2026, 10, 6, 10)))
        XCTAssertTrue(h.isOpen(at: at(2026, 10, 5, 20, 30), minimumRemainingMinutes: 30))
        XCTAssertFalse(h.isOpen(at: at(2026, 10, 5, 20, 30).addingTimeInterval(0.5), minimumRemainingMinutes: 30))
    }

    func testHugeMarginDoesNotOverflow() {
        let h = daily(600, 1260)
        XCTAssertFalse(h.isOpen(at: at(2026, 10, 5, 12), minimumRemainingMinutes: Int.max))
        XCTAssertTrue(h.isOpen(at: at(2026, 10, 5, 12), minimumRemainingMinutes: Int.min))
    }

    func testSevenBackToBack24hDaysIsOpenAndNeverNil() {
        let h = OpeningHours(weekly: (0...6).map { WeeklyPeriod(openDay: $0, openMinute: 0, closeDay: ($0 + 1) % 7, closeMinute: 0) })
        for hr in stride(from: 0, to: 24 * 9, by: 5) {
            let now = at(2026, 10, 5).addingTimeInterval(Double(hr) * 3600)
            XCTAssertTrue(h.isOpen(at: now, minimumRemainingMinutes: 30))
        }
    }

    func testSpecialDayAtFarEdgesOfWindow() {
        // 今日 +14 日の特別日の枠は nextOpenAt に出る / +15 日は出ない（週枠は空）。
        let now = at(2026, 10, 5, 12)
        let edge = OpeningHours(specialDays: [SpecialDay(date: CalendarDay(year: 2026, month: 10, day: 19), periods: [DayPeriod(openMinute: 600, closeMinute: 700)])])
        XCTAssertEqual(edge.status(at: now), .closed(nextOpenAt: at(2026, 10, 19, 10)))
        let beyond = OpeningHours(specialDays: [SpecialDay(date: CalendarDay(year: 2026, month: 10, day: 20), periods: [DayPeriod(openMinute: 600, closeMinute: 700)])])
        XCTAssertEqual(beyond.status(at: now), .closed(nextOpenAt: nil))
    }

    func testSpecialDayWithEmptyPeriodsDoesNotCutSpillFromWeekdayAndStillClosesItsOwnDay() {
        // 土 22:00→日 02:00。日曜が特別休業でも日曜 01:00 は営業、日曜に開く週枠は無視。
        let h = OpeningHours(
            weekly: [WeeklyPeriod(openDay: 6, openMinute: 22 * 60, closeDay: 0, closeMinute: 120),
                     WeeklyPeriod(openDay: 0, openMinute: 600, closeDay: 0, closeMinute: 1200)],
            specialDays: [SpecialDay(date: CalendarDay(year: 2026, month: 10, day: 4), periods: [])])
        XCTAssertEqual(h.status(at: at(2026, 10, 4, 1)), .open(closesAt: at(2026, 10, 4, 2)))
        XCTAssertEqual(h.status(at: at(2026, 10, 4, 12)), .closed(nextOpenAt: at(2026, 10, 10, 22)))
    }

    func testNextOpenAtWhenClosedByGapBetweenMergedRuns() {
        let h = OpeningHours(weekly: [
            WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 720),
            WeeklyPeriod(openDay: 1, openMinute: 780, closeDay: 1, closeMinute: 1200),
        ])
        XCTAssertEqual(h.status(at: at(2026, 10, 5, 12, 30)), .closed(nextOpenAt: at(2026, 10, 5, 13)))
        XCTAssertEqual(h.status(at: at(2026, 10, 5, 12)), .closed(nextOpenAt: at(2026, 10, 5, 13)))
    }

    func testSpecialDayDateInDifferentZoneUsesBranchLocalDate() {
        // 16:00 UTC の 10/4 = JST 10/5 01:00（月曜）。10/5 の特別日が適用される。
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 0, closeDay: 1, closeMinute: 1440)],
                             specialDays: [SpecialDay(date: CalendarDay(year: 2026, month: 10, day: 5), periods: [])])
        let now = at(2026, 10, 4, 16, tz: "UTC")
        XCTAssertEqual(h.status(at: now), .closed(nextOpenAt: at(2026, 10, 12)))
    }

    func testOpenMinuteBoundaryValues() {
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 1439, closeDay: 2, closeMinute: 0)])
        XCTAssertEqual(h.status(at: at(2026, 10, 5, 23, 59)), .open(closesAt: at(2026, 10, 6)))
        XCTAssertEqual(h.status(at: at(2026, 10, 6, 0, 0)), .closed(nextOpenAt: at(2026, 10, 12, 23, 59)))
    }
}
