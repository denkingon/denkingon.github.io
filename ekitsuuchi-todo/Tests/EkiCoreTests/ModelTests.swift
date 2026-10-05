import XCTest
@testable import EkiCore

final class ModelTests: XCTestCase {
    func testHaversineFujisawaToKamakura() {
        // 藤沢駅 → 鎌倉駅 is about 5.8 km as the crow flies.
        let fujisawa = Coordinate(latitude: 35.3388, longitude: 139.4899)
        let kamakura = Coordinate(latitude: 35.3190, longitude: 139.5500)
        let d = fujisawa.distance(to: kamakura)
        XCTAssertEqual(d, 5_800, accuracy: 300)
        XCTAssertEqual(fujisawa.distance(to: fujisawa), 0, accuracy: 0.001)
    }

    func testCalendarDayParsingAndArithmetic() {
        XCTAssertEqual(CalendarDay(isoString: "2026-09-14"), CalendarDay(year: 2026, month: 9, day: 14))
        XCTAssertNil(CalendarDay(isoString: "2026-02-30"))
        XCTAssertNil(CalendarDay(isoString: "2026-9-14"))
        XCTAssertNil(CalendarDay(isoString: "yesterday"))
        XCTAssertNil(CalendarDay(isoString: "+026-09-14"), "符号付きは日付ではない")
        XCTAssertNil(CalendarDay(isoString: "2026-+9-14"))
        XCTAssertNil(CalendarDay(isoString: "2026-09-+4"))
        XCTAssertNil(CalendarDay(isoString: "２０２６-09-14"), "全角数字は受けない")
        XCTAssertEqual(CalendarDay(year: 2026, month: 12, day: 31).addingDays(1), CalendarDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(CalendarDay(year: 2026, month: 3, day: 1).addingDays(-1), CalendarDay(year: 2026, month: 2, day: 28))
        // 2026-10-05 is a Monday.
        XCTAssertEqual(CalendarDay(year: 2026, month: 10, day: 5).weekdayIndex, 1)
        XCTAssertEqual(CalendarDay(year: 2026, month: 10, day: 4).weekdayIndex, 0)
    }

    func testCalendarDayInTokyoCrossesMidnightBeforeUTC() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-10-05 16:00 UTC == 2026-10-06 01:00 JST
        let date = Date(timeIntervalSince1970: 1_791_216_000)
        XCTAssertEqual(CalendarDay(date: date, timeZone: tokyo), CalendarDay(year: 2026, month: 10, day: 6))
        XCTAssertEqual(CalendarDay(date: date, timeZone: TimeZone(identifier: "UTC")!), CalendarDay(year: 2026, month: 10, day: 5))
        let start = CalendarDay(year: 2026, month: 10, day: 6).startOfDay(in: tokyo)
        XCTAssertEqual(start.timeIntervalSince1970, 1_791_216_000 - 3_600, accuracy: 0.5)
    }

    func testCalendarDayCodableIsPlainString() throws {
        let data = try JSONEncoder().encode(["d": CalendarDay(year: 2026, month: 9, day: 14)])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"d":"2026-09-14"}"#)
        XCTAssertThrowsError(try JSONDecoder().decode([String: CalendarDay].self, from: Data(#"{"d":"nope"}"#.utf8)))
    }

    func testChainNameKeyFoldsWidthCaseAndSpace() {
        XCTAssertTrue(ChainName.matches("ＤＡＩＳＯ ", "daiso"))
        XCTAssertTrue(ChainName.matches("無印 良品", "無印良品"))
        XCTAssertFalse(ChainName.matches("ダイソー", "セリア"))
        XCTAssertFalse(ChainName.matches("", ""))
    }

    func testTaskIgnoredUntilExpires() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var t = TodoTask(store: "ダイソー", item: "フィルム", createdAt: now)
        XCTAssertTrue(t.isPending(at: now))
        t.status = .ignored
        XCTAssertFalse(t.isPending(at: now), "無期限の無視は通知しない")
        t.ignoredUntil = now.addingTimeInterval(3_600)
        XCTAssertFalse(t.isPending(at: now))
        XCTAssertTrue(t.isPending(at: now.addingTimeInterval(3_600)), "今日は無視 は翌日 0 時に戻る")
        t.status = .done
        XCTAssertFalse(t.isPending(at: now.addingTimeInterval(9_999_999)))
    }

    func testLedgerDecodesOldFileMissingNewFields() throws {
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data("{}".utf8))
        XCTAssertEqual(ledger, Ledger())
        XCTAssertEqual(ledger.settings.frequency, .perStationPerDay)
        XCTAssertTrue(ledger.settings.checkBusinessHours)
    }
}
