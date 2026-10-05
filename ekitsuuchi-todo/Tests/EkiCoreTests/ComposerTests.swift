import XCTest
@testable import EkiCore

/// 通知本文の形（§3）と閉店の表記、徒歩分数（D6）。
final class ComposerTests: XCTestCase {
    typealias F = JudgeFixtures

    private func line(_ name: String, meters: Double, items: [String], chain: String = "ダイソー", hours: OpeningHours? = F.h10to21) -> BranchLine {
        BranchLine(
            branch: F.branch(name, chain: chain, name: name, hours: hours),
            meters: meters,
            tasks: items.map { F.task(chain, $0) }
        )
    }

    private func compose(_ lines: [BranchLine], now: Date = F.at(2026, 10, 5, 15)) -> NotificationContent {
        NotificationComposer.compose(station: F.fujisawa, lines: lines, now: now, timeZone: F.tokyo)
    }

    // MARK: 本文

    func test設計書の例そのまま() {
        let c = compose([line("ダイソー 藤沢店", meters: 320, items: ["フィルム", "電池"])])
        XCTAssertEqual(c.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池")
        XCTAssertEqual(c.title, "")
        XCTAssertEqual(c.stationID, F.fujisawa.id)
    }

    func test複数支店は距離の近い順に改行で並べ_同距離は渡された順() {
        let c = compose([
            line("セリア 藤沢店", meters: 200, items: ["付箋"], chain: "セリア"),
            line("ダイソー 藤沢店", meters: 120, items: ["フィルム"]),
            line("無印良品 藤沢", meters: 200, items: ["ファイルボックス"], chain: "無印良品"),
        ])
        XCTAssertEqual(c.body, """
        藤沢駅｜ダイソー 藤沢店（徒歩2分・21時まで）：フィルム
        セリア 藤沢店（徒歩3分・21時まで）：付箋
        無印良品 藤沢（徒歩3分・21時まで）：ファイルボックス
        """)
    }

    func testtaskIDsは表示した全タスクを表示順で() {
        let far = line("遠い店", meters: 400, items: ["a"])
        let near = line("近い店", meters: 100, items: ["b", "c"])
        let c = compose([far, near])
        XCTAssertEqual(c.taskIDs, near.tasks.map(\.id) + far.tasks.map(\.id))
    }

    func test完全に同じ品目は1つにする_順序はタスク順() {
        let c = compose([line("ダイソー 藤沢店", meters: 80, items: ["電池", "フィルム", "電池"])])
        XCTAssertEqual(c.body, "藤沢駅｜ダイソー 藤沢店（徒歩1分・21時まで）：電池、フィルム")
    }

    func test重複を除いてもtaskIDsには全タスクを残す() {
        let l = line("ダイソー 藤沢店", meters: 80, items: ["電池", "電池"])
        XCTAssertEqual(compose([l]).taskIDs, l.tasks.map(\.id), "完了ボタンは両方を完了にする")
    }

    func test行が無いときは駅名だけ() {
        XCTAssertEqual(compose([]).body, "藤沢駅")
        XCTAssertEqual(compose([]).taskIDs, [])
    }

    // MARK: 徒歩（D6）

    func test徒歩分数は80mごとに切り上げ_最低1分() {
        let m = NotificationComposer.walkingMinutes(meters:)
        XCTAssertEqual(m(0), 1)
        XCTAssertEqual(m(1), 1)
        XCTAssertEqual(m(80), 1)
        XCTAssertEqual(m(80.01), 2)
        XCTAssertEqual(m(160), 2)
        XCTAssertEqual(m(320), 4)
        XCTAssertEqual(m(321), 5)
        XCTAssertEqual(m(500), 7)
        XCTAssertEqual(m(-5), 1)
        XCTAssertEqual(m(.nan), 1)
        XCTAssertEqual(m(.infinity), 1)
    }

    // MARK: 閉店の表記

    private func closing(_ hours: OpeningHours?, _ now: Date) -> String {
        NotificationComposer.closingText(hours, now: now)
    }

    func test営業時間なしは営業時間不明() {
        XCTAssertEqual(closing(nil, F.at(2026, 10, 5, 15)), "営業時間不明")
    }

    func test同じ日の閉店は時と分_分は0のとき省く_時は先頭ゼロなし() {
        XCTAssertEqual(closing(F.daily(9 * 60, 21 * 60), F.at(2026, 10, 5, 15)), "21時まで")
        XCTAssertEqual(closing(F.daily(9 * 60, 21 * 60 + 30), F.at(2026, 10, 5, 15)), "21:30まで")
        XCTAssertEqual(closing(F.daily(9 * 60, 21 * 60 + 5), F.at(2026, 10, 5, 15)), "21:05まで")
        XCTAssertEqual(closing(F.daily(1 * 60, 9 * 60), F.at(2026, 10, 5, 3)), "9時まで")
    }

    func test閉店が翌日なら翌を付ける() {
        // 金 18:00 → 土 02:00
        let night = OpeningHours(weekly: [WeeklyPeriod(openDay: 5, openMinute: 18 * 60, closeDay: 6, closeMinute: 2 * 60)])
        XCTAssertEqual(closing(night, F.at(2026, 10, 2, 19)), "翌2時まで")          // 金 19:00
        XCTAssertEqual(closing(night, F.at(2026, 10, 3, 1)), "2時まで")             // 土 01:00（もう同じ日付）
        let half = OpeningHours(weekly: [WeeklyPeriod(openDay: 5, openMinute: 18 * 60, closeDay: 6, closeMinute: 90)])
        XCTAssertEqual(closing(half, F.at(2026, 10, 2, 19)), "翌1:30まで")
    }

    func test閉店がちょうど翌0時なら24時まで() {
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 10 * 60, closeDay: 2, closeMinute: 0)])
        XCTAssertEqual(closing(h, F.at(2026, 10, 5, 15)), "24時まで")
    }

    func test24時間営業は閉店なしか24時間より先() {
        XCTAssertEqual(closing(OpeningHours(isAlwaysOpen: true), F.at(2026, 10, 5, 15)), "24時間営業")
        // 毎日 0:00–24:00 は 1 本の連続営業にマージされ、閉店は窓の果て
        XCTAssertEqual(closing(F.daily(0, 1440), F.at(2026, 10, 5, 15)), "24時間営業")
    }

    func test閉店がちょうど24時間後なら日付で書き_1秒でも超えれば24時間営業() {
        // 月 09:00 開店 → 火 10:00 閉店（25 時間の営業）
        let h = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 9 * 60, closeDay: 2, closeMinute: 10 * 60)])
        XCTAssertEqual(closing(h, F.at(2026, 10, 5, 10, 0, 0)), "翌10時まで")        // ちょうど 24h
        XCTAssertEqual(closing(h, F.at(2026, 10, 5, 9, 59, 59)), "24時間営業")       // 24h + 1s
    }

    func test閉店の日付は店のタイムゾーンで数える() {
        // LA の店 10:00–21:00。now = 2026-10-06 04:00 JST = 10-05 12:00 PDT。日本の日付なら「翌日」だが現地では同日。
        let la = F.daily(10 * 60, 21 * 60, tz: "America/Los_Angeles")
        XCTAssertEqual(closing(la, F.at(2026, 10, 6, 4)), "21時まで")
    }

    func test営業時間外は営業時間外() {
        XCTAssertEqual(closing(F.daily(10 * 60, 21 * 60), F.at(2026, 10, 5, 22)), "営業時間外")
    }

    func test閉店表記は本文に反映される() {
        let h = F.daily(10 * 60, 20 * 60 + 30)
        XCTAssertTrue(compose([line("ダイソー 藤沢店", meters: 320, items: ["a"], hours: h)]).body.contains("（徒歩4分・20:30まで）"))
        XCTAssertTrue(compose([line("ダイソー 藤沢店", meters: 320, items: ["a"], hours: nil)]).body.contains("（徒歩4分・営業時間不明）"))
    }
}
