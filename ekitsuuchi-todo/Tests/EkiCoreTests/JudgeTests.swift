import XCTest
@testable import EkiCore

/// Judge 系テスト共通の部品。基準: 2026-10-05（月）。10-04 日、10-03 土、10-02 金。
enum JudgeFixtures {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let utc = TimeZone(identifier: "UTC")!

    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, tz: TimeZone = tokyo) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    static let fujisawa = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
        name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4900)
    )
    static let tsujido = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!,
        name: "辻堂駅", coordinate: Coordinate(latitude: 35.3376, longitude: 139.4486)
    )

    /// 毎日 open〜close（分）。
    static func daily(_ open: Int, _ close: Int, tz: String = "Asia/Tokyo") -> OpeningHours {
        OpeningHours(timeZoneID: tz, weekly: (0...6).map { WeeklyPeriod(openDay: $0, openMinute: open, closeDay: $0, closeMinute: close) })
    }

    /// 10:00–21:00。
    static var h10to21: OpeningHours { daily(10 * 60, 21 * 60) }

    static func branch(
        _ id: String, chain: String = "ダイソー", name: String? = nil,
        near stations: [(Station, Double)] = [(fujisawa, 320)], hours: OpeningHours? = h10to21
    ) -> Branch {
        Branch(
            id: id, chainName: chain, name: name ?? "\(chain) \(id)",
            coordinate: Coordinate(latitude: 35.34, longitude: 139.49),
            hours: hours, hoursFetchedAt: nil,
            nearestStations: stations.map { StationDistance(stationID: $0.0.id, meters: $0.1) }
        )
    }

    static func task(_ store: String, _ item: String, status: TaskStatus = .pending, ignoredUntil: Date? = nil) -> TodoTask {
        TodoTask(store: store, item: item, status: status, createdAt: at(2026, 10, 1, 9), ignoredUntil: ignoredUntil)
    }

    static func record(
        _ station: Station, _ result: NotificationResult, at date: Date
    ) -> NotificationRecord {
        NotificationRecord(stationID: station.id, stationName: station.name, firedAt: date, result: result)
    }

    static func context(
        _ ledger: Ledger, station: Station = fujisawa, now: Date = at(2026, 10, 5, 15),
        tz: TimeZone = tokyo, location: LocationFix? = nil
    ) -> JudgeContext {
        JudgeContext(ledger: ledger, station: station, now: now, timeZone: tz, location: location)
    }
}

/// 駅入域時の判定（§4）と D2〜D9・D13・D14。
final class JudgeTests: XCTestCase {
    typealias F = JudgeFixtures
    private let fixedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func ledger(
        tasks: [TodoTask], branches: [Branch], history: [NotificationRecord] = [],
        settings: Settings = Settings(), stations: [Station] = [F.fujisawa, F.tsujido]
    ) -> Ledger {
        Ledger(tasks: tasks, stations: stations, branches: branches, history: history,
               registeredChains: [], settings: settings)
    }

    private func judge(_ l: Ledger, station: Station = F.fujisawa, now: Date = F.at(2026, 10, 5, 15),
                       tz: TimeZone = F.tokyo, location: LocationFix? = nil) -> JudgeOutcome {
        NotificationJudge.judge(F.context(l, station: station, now: now, tz: tz, location: location), recordID: fixedID)
    }

    // MARK: 基本の通知

    func test門を全部通ると設計書どおりの本文で通知する() {
        let t1 = F.task("ダイソー", "フィルム"), t2 = F.task("ダイソー", "電池")
        let b = F.branch("b1", name: "ダイソー 藤沢店")
        let o = judge(ledger(tasks: [t1, t2], branches: [b]))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池")
        XCTAssertEqual(o.notification?.title, "")
        XCTAssertEqual(o.notification?.stationID, F.fujisawa.id)
        XCTAssertEqual(o.notification?.taskIDs, [t1.id, t2.id])
        XCTAssertEqual(o.record.taskIDs, [t1.id, t2.id])
        XCTAssertEqual(o.record.branchIDs, ["b1"])
        XCTAssertNil(o.record.detail)
    }

    func test記録は常に1行_id_時刻_駅名_位置を持つ() {
        let fix = LocationFix(coordinate: Coordinate(latitude: 35.3, longitude: 139.4), horizontalAccuracy: 65, timestamp: F.at(2026, 10, 5, 14, 59))
        let now = F.at(2026, 10, 5, 15)
        for l in [
            ledger(tasks: [], branches: []),                                                   // 未完了なし
            ledger(tasks: [F.task("ダイソー", "a")], branches: []),                            // 支店なし
            ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", hours: F.daily(0, 60))]), // 営業時間外
            ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b")]),               // 通知
        ] {
            let o = judge(l, now: now, location: fix)
            XCTAssertEqual(o.record.id, fixedID)
            XCTAssertEqual(o.record.firedAt, now)
            XCTAssertEqual(o.record.stationName, "藤沢駅")
            XCTAssertEqual(o.record.stationID, F.fujisawa.id)
            XCTAssertEqual(o.record.location, fix)
        }
    }

    func test既定のrecordIDは毎回別() {
        let c = F.context(ledger(tasks: [], branches: []))
        XCTAssertNotEqual(NotificationJudge.judge(c).record.id, NotificationJudge.judge(c).record.id)
    }

    // MARK: 0. 実測モード（D8）

    func test実測モードは門を通さず駅名だけ通知する() {
        let fix = LocationFix(coordinate: Coordinate(latitude: 35.3, longitude: 139.4), horizontalAccuracy: 30, timestamp: F.at(2026, 10, 5, 15))
        let o = judge(ledger(tasks: [], branches: [], settings: Settings(diagnosticMode: true)), location: fix)
        XCTAssertEqual(o.record.result, .diagnosticNotified)
        XCTAssertEqual(o.notification?.body, "藤沢駅に入った")
        XCTAssertEqual(o.notification?.taskIDs, [])
        XCTAssertEqual(o.record.taskIDs, [])
        XCTAssertEqual(o.record.location, fix)
    }

    func test実測モードは通知済みでも毎回出し_今日通知済に数えない() {
        let today = F.at(2026, 10, 5, 9)
        var s = Settings(diagnosticMode: true)
        let l1 = ledger(tasks: [], branches: [], history: [F.record(F.fujisawa, .notified, at: today), F.record(F.fujisawa, .diagnosticNotified, at: today)], settings: s)
        XCTAssertEqual(judge(l1).record.result, .diagnosticNotified)
        // 実測の通知だけが今日ある → 実測を切ったら通常通知は出る（診断は消費ではない）
        s.diagnosticMode = false
        let l2 = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b")],
                        history: [F.record(F.fujisawa, .diagnosticNotified, at: today)], settings: s)
        XCTAssertEqual(judge(l2).record.result, .notified)
    }

    // MARK: 1. 未完了なし

    func test未完了なしは抑制() {
        let l = ledger(tasks: [F.task("ダイソー", "a", status: .done)], branches: [F.branch("b")])
        let o = judge(l)
        XCTAssertEqual(o.record.result, .suppressedNoPendingTasks)
        XCTAssertNil(o.notification)
        XCTAssertEqual(o.record.taskIDs, [])
    }

    func test無視は通知対象にならない_期限なしは永久_期限前は今日だけ() {
        let now = F.at(2026, 10, 5, 15)
        let tomorrow = F.at(2026, 10, 6)
        let l = ledger(tasks: [
            F.task("ダイソー", "indef", status: .ignored, ignoredUntil: nil),
            F.task("ダイソー", "today", status: .ignored, ignoredUntil: tomorrow),
        ], branches: [F.branch("b")])
        XCTAssertEqual(judge(l, now: now).record.result, .suppressedNoPendingTasks)
    }

    func test今日は無視は翌日0時ちょうどから戻る_境界は以上() {
        let until = F.at(2026, 10, 6)
        let l = ledger(tasks: [F.task("ダイソー", "x", status: .ignored, ignoredUntil: until)], branches: [F.branch("b")])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 23, 59, 59)).record.result, .suppressedNoPendingTasks)
        // 翌 0 時ちょうど: 営業時間外になるので、通知対象に戻った証拠として「未完了なし」ではないことを見る
        XCTAssertEqual(judge(l, now: until).record.result, .suppressedClosed)
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 6, 12)).record.result, .notified)
    }

    // MARK: 2. 支店なし（D12 の裏返し）

    func test駅に支店が無ければ抑制_全タスクを載せチェーン名を書く() {
        let t1 = F.task("ダイソー", "a"), t2 = F.task("無印良品", "b")
        // 辻堂にだけ支店がある → 藤沢では支店なし
        let l = ledger(tasks: [t1, t2], branches: [F.branch("b", near: [(F.tsujido, 100)])])
        let o = judge(l)
        XCTAssertEqual(o.record.result, .suppressedNoBranch)
        XCTAssertEqual(o.record.taskIDs, [t1.id, t2.id])
        XCTAssertEqual(o.record.branchIDs, [])
        XCTAssertTrue(o.record.detail?.contains("ダイソー") == true)
        XCTAssertTrue(o.record.detail?.contains("無印良品") == true)
        XCTAssertNil(o.notification)
    }

    func test一部のチェーンだけ支店が無いときはそのチェーンだけ落として通知する() {
        let daiso = F.task("ダイソー", "フィルム"), muji = F.task("無印良品", "ファイルボックス")
        let l = ledger(tasks: [daiso, muji], branches: [F.branch("b1", name: "ダイソー 藤沢店")])
        let o = judge(l)
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
        XCTAssertEqual(o.record.taskIDs, [daiso.id], "落としたチェーンのタスクは通知にも履歴にも載せない")
        XCTAssertEqual(o.record.detail, "除外: 無印良品（支店なし）")
    }

    // MARK: 3. 営業中

    func test全部時間外なら抑制_どの支店かと理由が1行() {
        let t = F.task("ダイソー", "a")
        let l = ledger(tasks: [t], branches: [F.branch("b", name: "ダイソー 藤沢店")])
        let o = judge(l, now: F.at(2026, 10, 5, 22))
        XCTAssertEqual(o.record.result, .suppressedClosed)
        XCTAssertEqual(o.record.detail, "ダイソー 藤沢店は営業時間外")
        XCTAssertEqual(o.record.branchIDs, ["b"])
        XCTAssertEqual(o.record.taskIDs, [t.id])
        XCTAssertNil(o.notification)
    }

    func test閉店まで30分ちょうどは通知_1秒足りなければ抑制() {
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", name: "ダイソー 藤沢店")])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 20, 30, 0)).record.result, .notified)
        let late = judge(l, now: F.at(2026, 10, 5, 20, 30, 1))
        XCTAssertEqual(late.record.result, .suppressedClosed)
        XCTAssertEqual(late.record.detail, "ダイソー 藤沢店は閉店まで29分")
        let twenty = judge(l, now: F.at(2026, 10, 5, 20, 40))
        XCTAssertEqual(twenty.record.detail, "ダイソー 藤沢店は閉店まで20分")
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 20, 59, 30)).record.detail, "ダイソー 藤沢店は閉店まで1分未満")
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 21, 0, 0)).record.detail, "ダイソー 藤沢店は営業時間外")
    }

    func test最寄りが閉まっていても次に近い開いている支店を選ぶ() {
        let near = F.branch("near", name: "ダイソー 近い店", near: [(F.fujisawa, 100)], hours: F.daily(0, 60))
        let far = F.branch("far", name: "ダイソー 遠い店", near: [(F.fujisawa, 410)])
        let o = judge(ledger(tasks: [F.task("ダイソー", "a")], branches: [near, far]))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.record.branchIDs, ["far"])
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 遠い店（徒歩6分・21時まで）：a")
    }

    func test両方開いていれば近い方() {
        let near = F.branch("near", name: "ダイソー 近い店", near: [(F.fujisawa, 100)])
        let far = F.branch("far", name: "ダイソー 遠い店", near: [(F.fujisawa, 410)])
        let o = judge(ledger(tasks: [F.task("ダイソー", "a")], branches: [far, near]))
        XCTAssertEqual(o.record.branchIDs, ["near"])
    }

    func test同じ距離の支店はidで決まる() {
        let a = F.branch("a", name: "ダイソー A", near: [(F.fujisawa, 200)])
        let b = F.branch("b", name: "ダイソー B", near: [(F.fujisawa, 200)])
        XCTAssertEqual(judge(ledger(tasks: [F.task("ダイソー", "x")], branches: [b, a])).record.branchIDs, ["a"])
    }

    func test営業時間不明は営業中とみなし_営業時間不明と書く_D4() {
        let l = ledger(tasks: [F.task("ダイソー", "フィルム")], branches: [F.branch("b", name: "ダイソー 藤沢店", hours: nil)])
        let o = judge(l, now: F.at(2026, 10, 5, 3))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・営業時間不明）：フィルム")
    }

    func test営業時間チェックを切ると時間外でも最寄りで通知する() {
        let l = ledger(tasks: [F.task("ダイソー", "a")],
                       branches: [F.branch("near", name: "ダイソー 近い店", near: [(F.fujisawa, 100)], hours: F.daily(0, 60)),
                                  F.branch("far", name: "ダイソー 遠い店", near: [(F.fujisawa, 410)])],
                       settings: Settings(checkBusinessHours: false))
        let o = judge(l, now: F.at(2026, 10, 5, 22))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.record.branchIDs, ["near"], "チェックを切ったら最寄りをそのまま使う")
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 近い店（徒歩2分・営業時間外）：a")
    }

    func test営業中の門は営業時間を店のタイムゾーンで見る() {
        // 店が LA（10:00–21:00 現地）。2026-10-05 15:00 JST = 10-04 23:00 PDT → 閉店後（東京の感覚なら営業中の時刻）。
        let la = F.daily(10 * 60, 21 * 60, tz: "America/Los_Angeles")
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", hours: la)])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 15)).record.result, .suppressedClosed)
        // 10-06 04:00 JST = 10-05 12:00 PDT → 営業中（東京の感覚なら未明）。本文の閉店も現地の 21 時。
        let o = judge(l, now: F.at(2026, 10, 6, 4))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertTrue(o.notification?.body.contains("21時まで") == true)
    }

    func test複数チェーンの片方だけ時間外なら除外して通知する() {
        let daiso = F.task("ダイソー", "フィルム"), seria = F.task("セリア", "付箋")
        let l = ledger(tasks: [daiso, seria], branches: [
            F.branch("d", chain: "ダイソー", name: "ダイソー 藤沢店"),
            F.branch("s", chain: "セリア", name: "セリア 藤沢店", near: [(F.fujisawa, 150)], hours: F.daily(10 * 60, 15 * 60 + 10)),
        ])
        let o = judge(l, now: F.at(2026, 10, 5, 15, 0))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.record.taskIDs, [daiso.id])
        XCTAssertEqual(o.record.detail, "除外: セリア（閉店まで10分）")
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
    }

    func test除外の記述はチェーンの出現順で支店なしと時間外が混ざる() {
        let l = ledger(tasks: [F.task("無印良品", "a"), F.task("セリア", "b"), F.task("ダイソー", "c")], branches: [
            F.branch("s", chain: "セリア", name: "セリア 藤沢店", hours: F.daily(0, 60)),
            F.branch("d", chain: "ダイソー", name: "ダイソー 藤沢店"),
        ])
        XCTAssertEqual(judge(l).record.detail, "除外: 無印良品（支店なし）、セリア（営業時間外）")
    }

    func test全部時間外で一部は支店なしのとき_理由に支店なしも添える() {
        let l = ledger(tasks: [F.task("ダイソー", "a"), F.task("無印良品", "b")],
                       branches: [F.branch("d", name: "ダイソー 藤沢店")])
        let o = judge(l, now: F.at(2026, 10, 5, 22))
        XCTAssertEqual(o.record.result, .suppressedClosed)
        XCTAssertEqual(o.record.detail, "ダイソー 藤沢店は営業時間外（支店なし: 無印良品）")
    }

    // MARK: 4. 今日通知済（D14）

    private func notifiedLedger(freq: NotifyFrequency, history: [NotificationRecord], hours: OpeningHours? = F.h10to21) -> Ledger {
        ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", near: [(F.fujisawa, 320), (F.tsujido, 90)], hours: hours)],
               history: history, settings: Settings(frequency: freq))
    }

    func test駅ごと1日1回_同じ駅の今日の通知があれば抑制() {
        let l = notifiedLedger(freq: .perStationPerDay, history: [F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 9, 15))])
        let o = judge(l)
        XCTAssertEqual(o.record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(o.record.detail, "今日 9:15 に通知済")
        XCTAssertEqual(o.record.branchIDs, ["b"], "鳴らしていたらどの支店だったかを残す")
        XCTAssertEqual(o.record.taskIDs.count, 1)
        XCTAssertNil(o.notification)
    }

    func test駅ごと1日1回_別の駅の通知は数えない() {
        let l = notifiedLedger(freq: .perStationPerDay, history: [F.record(F.tsujido, .notified, at: F.at(2026, 10, 5, 9))])
        XCTAssertEqual(judge(l).record.result, .notified)
    }

    func test全駅で1日1回_別の駅の通知も数える() {
        let l = notifiedLedger(freq: .oncePerDay, history: [F.record(F.tsujido, .notified, at: F.at(2026, 10, 5, 9))])
        let o = judge(l)
        XCTAssertEqual(o.record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(o.record.detail, "今日 9:00 に通知済（辻堂駅）")
    }

    func test入域のたびは何度でも通知する() {
        let l = notifiedLedger(freq: .everyEntry, history: [F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 14, 59))])
        XCTAssertEqual(judge(l).record.result, .notified)
    }

    func test抑制_失敗_実測は今日を消費しない() {
        let day = F.at(2026, 10, 5, 9)
        let history = NotificationResult.allCases.filter { $0 != .notified }.map { F.record(F.fujisawa, $0, at: day) }
        XCTAssertEqual(history.count, 6)
        for freq in NotifyFrequency.allCases {
            XCTAssertEqual(judge(notifiedLedger(freq: freq, history: history)).record.result, .notified, "\(freq)")
        }
    }

    func test昨日の通知は今日を消費しない_日付の切れ目は端末のタイムゾーンの0時() {
        // 23:59:59 と 翌 00:00:00（東京）
        let l = notifiedLedger(freq: .perStationPerDay, history: [F.record(F.fujisawa, .notified, at: F.at(2026, 10, 4, 23, 59, 59))], hours: OpeningHours(isAlwaysOpen: true))
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 0, 0, 0)).record.result, .notified)
        let same = notifiedLedger(freq: .perStationPerDay, history: [F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 0, 0, 0))], hours: OpeningHours(isAlwaysOpen: true))
        XCTAssertEqual(judge(same, now: F.at(2026, 10, 5, 23, 59, 59)).record.result, .suppressedAlreadyNotifiedToday)
    }

    func test今日の判定は店でなく端末のタイムゾーン_D14() {
        // 通知 10-05 08:00 JST = 10-04 23:00 UTC。判定 10-05 10:00 JST = 10-05 01:00 UTC。
        let l = notifiedLedger(freq: .perStationPerDay, history: [F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 8))])
        let now = F.at(2026, 10, 5, 10)
        XCTAssertEqual(judge(l, now: now, tz: F.tokyo).record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(judge(l, now: now, tz: F.utc).record.result, .notified)
    }

    // MARK: 門の優先順位

    func test優先順位_未完了なし_支店なし_営業時間外_今日通知済() {
        let notifiedToday = [F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 9))]
        let t = F.task("ダイソー", "a")
        let night = F.at(2026, 10, 5, 22)
        // 全部が該当 → 一番上の門で止まる
        XCTAssertEqual(judge(ledger(tasks: [], branches: [], history: notifiedToday), now: night).record.result, .suppressedNoPendingTasks)
        XCTAssertEqual(judge(ledger(tasks: [t], branches: [], history: notifiedToday), now: night).record.result, .suppressedNoBranch)
        XCTAssertEqual(judge(ledger(tasks: [t], branches: [F.branch("b")], history: notifiedToday), now: night).record.result, .suppressedClosed)
        XCTAssertEqual(judge(ledger(tasks: [t], branches: [F.branch("b")], history: notifiedToday)).record.result, .suppressedAlreadyNotifiedToday)
    }

    // MARK: 複数チェーン・表記ゆれ

    func test全角半角大文字小文字の違うタスクは同じチェーンとして1行にまとまる() {
        let t1 = F.task("Daiso", "フィルム"), t2 = F.task("ＤＡＩＳＯ ", "電池")
        let b = F.branch("b", chain: "daiso", name: "ダイソー 藤沢店")
        let o = judge(ledger(tasks: [t1, t2], branches: [b]))
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池")
        XCTAssertEqual(o.record.taskIDs, [t1.id, t2.id])
    }

    func test複数チェーンは近い順に行を分ける() {
        let l = ledger(tasks: [F.task("ダイソー", "フィルム"), F.task("無印良品", "ファイルボックス")], branches: [
            F.branch("d", chain: "ダイソー", name: "ダイソー 藤沢店", near: [(F.fujisawa, 320)]),
            F.branch("m", chain: "無印良品", name: "無印良品 藤沢", near: [(F.fujisawa, 85)], hours: F.daily(10 * 60, 20 * 60 + 30)),
        ])
        let o = judge(l, now: F.at(2026, 10, 5, 15))
        XCTAssertEqual(o.notification?.body, "藤沢駅｜無印良品 藤沢（徒歩2分・20:30まで）：ファイルボックス\nダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
        XCTAssertEqual(o.record.branchIDs, ["m", "d"])
        XCTAssertEqual(o.notification?.taskIDs, o.record.taskIDs)
    }

    func test期限切れの今日は無視は通知に載る() {
        let back = F.task("ダイソー", "戻った", status: .ignored, ignoredUntil: F.at(2026, 10, 5))
        let stay = F.task("ダイソー", "永久無視", status: .ignored)
        let o = judge(ledger(tasks: [back, stay], branches: [F.branch("b")]))
        XCTAssertEqual(o.record.taskIDs, [back.id])
    }

    func test別の駅の最寄りに登録された支店は使わない() {
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("t", near: [(F.tsujido, 50)])])
        XCTAssertEqual(judge(l, station: F.fujisawa).record.result, .suppressedNoBranch)
        XCTAssertEqual(judge(l, station: F.tsujido).record.result, .notified)
    }
}
