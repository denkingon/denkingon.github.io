import XCTest
@testable import EkiCore

/// 独立レビューで足した敵対テスト（判定・本文・監視計画・入域ハンドラ・今日の営業時間）。
final class ReviewExtraJudgeTests: XCTestCase {
    typealias F = JudgeFixtures

    private func ledger(
        tasks: [TodoTask], branches: [Branch], history: [NotificationRecord] = [],
        settings: Settings = Settings(), stations: [Station] = [F.fujisawa, F.tsujido]
    ) -> Ledger {
        Ledger(tasks: tasks, stations: stations, branches: branches, history: history, registeredChains: [], settings: settings)
    }

    private func judge(_ l: Ledger, station: Station = F.fujisawa, now: Date = F.at(2026, 10, 5, 15), tz: TimeZone = F.tokyo) -> JudgeOutcome {
        NotificationJudge.judge(F.context(l, station: station, now: now, tz: tz))
    }

    // MARK: 判定: 営業時間の境界と理由

    func test閉店まで30分ちょうどは通り_1秒足りないと止まり理由は29分() {
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", name: "ダイソー 藤沢店")])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 20, 30)).record.result, .notified)
        let o = judge(l, now: F.at(2026, 10, 5, 20, 30, 1))
        XCTAssertEqual(o.record.result, .suppressedClosed)
        XCTAssertEqual(o.record.detail, "ダイソー 藤沢店は閉店まで29分")
        XCTAssertNil(o.notification)
        XCTAssertEqual(o.record.branchIDs, ["b"])
    }

    func test閉店まで1分未満は1分未満と書く() {
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", name: "ダイソー 藤沢店")])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 20, 59, 30)).record.detail, "ダイソー 藤沢店は閉店まで1分未満")
        // 閉店ちょうど（含まない）は営業時間外
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 21)).record.detail, "ダイソー 藤沢店は営業時間外")
    }

    func test最寄りが閉まっていて2番目が開いていれば2番目の距離と閉店で通知する() {
        let near = F.branch("near", name: "ダイソー 近店", near: [(F.fujisawa, 100)], hours: F.daily(0, 60))
        let far = F.branch("far", name: "ダイソー 遠店", near: [(F.fujisawa, 480)])
        let o = judge(ledger(tasks: [F.task("ダイソー", "a")], branches: [near, far]))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 遠店（徒歩6分・21時まで）：a")
        XCTAssertEqual(o.record.branchIDs, ["far"])
    }

    func test営業時間チェックを切ると閉まっている最寄りでも通知し営業時間外と書く() {
        let b = F.branch("b", name: "ダイソー 藤沢店", hours: F.daily(0, 60))
        let o = judge(ledger(tasks: [F.task("ダイソー", "a")], branches: [b], settings: Settings(checkBusinessHours: false)))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・営業時間外）：a")
    }

    func test一部のチェーンだけ除外して残りを通知し_除外理由は出現順() {
        let tasks = [F.task("セリア", "s"), F.task("ダイソー", "d"), F.task("無印良品", "m")]
        let branches = [
            F.branch("d", chain: "ダイソー", name: "ダイソー 藤沢店", near: [(F.fujisawa, 400)], hours: F.daily(0, 60)),
            F.branch("m", chain: "無印良品", name: "無印良品 藤沢店", near: [(F.fujisawa, 100)]),
        ]
        let o = judge(ledger(tasks: tasks, branches: branches))
        XCTAssertEqual(o.record.result, .notified)
        XCTAssertEqual(o.notification?.body, "藤沢駅｜無印良品 藤沢店（徒歩2分・21時まで）：m")
        XCTAssertEqual(o.record.detail, "除外: セリア（支店なし）、ダイソー（営業時間外）")
        XCTAssertEqual(o.record.taskIDs, [tasks[2].id])   // 載った分だけ
    }

    func test表記ゆれのチェーンは1行にまとまる() {
        let tasks = [F.task("ダイソー", "フィルム"), F.task("ダイソー ", "電池")]
        let b = F.branch("b", chain: "ﾀﾞｲｿｰ", name: "ダイソー 藤沢店")
        let o = judge(ledger(tasks: tasks, branches: [b]))
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池")
    }

    func test営業時間不明の支店は開いている扱いで営業時間不明と書く_D4() {
        let o = judge(ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", name: "ダイソー 藤沢店", hours: nil)]),
                      now: F.at(2026, 10, 5, 3))
        XCTAssertEqual(o.notification?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・営業時間不明）：a")
    }

    // MARK: 判定: 今日の区切り

    func test東京0時ちょうどで日が変わる() {
        let notified = F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 23, 59, 59))
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", hours: F.daily(0, 1440))], history: [notified])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 5, 23, 59, 59)).record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 6, 0, 0, 0)).record.result, .notified)
    }

    func test今日の区切りは端末のタイムゾーン_UTCなら東京の朝9時で日が変わる() {
        // 10-05 23:59:59 JST = 10-05 14:59:59 UTC。10-06 00:00 JST = 10-05 15:00 UTC（まだ UTC では同じ日）。
        let notified = F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 23, 59, 59))
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", hours: F.daily(0, 1440))], history: [notified])
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 6, 0), tz: F.utc).record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(judge(l, now: F.at(2026, 10, 6, 9), tz: F.utc).record.result, .notified)
    }

    func test全駅で1日1回は他の駅の通知で止まり_詳細に駅名と時刻が出る() {
        let notified = F.record(F.tsujido, .notified, at: F.at(2026, 10, 5, 9, 5))
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b")], history: [notified], settings: Settings(frequency: .oncePerDay))
        let o = judge(l)
        XCTAssertEqual(o.record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(o.record.detail, "今日 9:05 に通知済（辻堂駅）")
    }

    func test入域のたびは今日の通知があっても通知する() {
        let notified = F.record(F.fujisawa, .notified, at: F.at(2026, 10, 5, 9))
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b")], history: [notified], settings: Settings(frequency: .everyEntry))
        XCTAssertEqual(judge(l).record.result, .notified)
    }

    func test抑制と失敗と実測の記録は今日を消費しない() {
        let today = F.at(2026, 10, 5, 9)
        let history = [NotificationResult.suppressedClosed, .suppressedNoBranch, .suppressedNoPendingTasks,
                       .suppressedAlreadyNotifiedToday, .failedToPost, .diagnosticNotified].map { F.record(F.fujisawa, $0, at: today) }
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b")], history: history)
        XCTAssertEqual(judge(l).record.result, .notified)
    }

    func test判定は入力の台帳を変えない() {
        let l = ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b")])
        _ = judge(l)
        XCTAssertEqual(l, ledger(tasks: l.tasks, branches: l.branches))
        XCTAssertTrue(l.history.isEmpty)
    }

    // MARK: 本文

    /// 毎日 open〜close（分）。close が 1440 超なら翌日に閉まる枠として組む。
    private func overnight(_ open: Int, _ close: Int) -> OpeningHours {
        OpeningHours(weekly: (0...6).map {
            WeeklyPeriod(openDay: $0, openMinute: open, closeDay: close > 1440 ? ($0 + 1) % 7 : $0, closeMinute: close > 1440 ? close - 1440 : close)
        })
    }

    func test閉店表記の端() {
        let now = F.at(2026, 10, 5, 15)
        func text(_ open: Int, _ close: Int) -> String { NotificationComposer.closingText(overnight(open, close), now: now) }
        XCTAssertEqual(text(600, 1440 - 0), "24時まで")                  // 24:00 ちょうど
        XCTAssertEqual(text(600, 1440 + 30), "翌0:30まで")
        XCTAssertEqual(text(600, 1440 + 60), "翌1時まで")
        XCTAssertEqual(text(600, 1440 + 90), "翌1:30まで")
        XCTAssertEqual(text(600, 21 * 60 + 5), "21:05まで")
        XCTAssertEqual(text(600, 16 * 60), "16時まで")
    }

    func test閉店が24時間より先なら24時間営業と書く() {
        // 毎日 0:00–24:00 を枠で書いた店（isAlwaysOpen ではない）。
        let h = F.daily(0, 1440)
        XCTAssertEqual(NotificationComposer.closingText(h, now: F.at(2026, 10, 5, 15)), "24時間営業")
        XCTAssertEqual(NotificationComposer.closingText(OpeningHours(isAlwaysOpen: true), now: F.at(2026, 10, 5, 15)), "24時間営業")
    }

    func test閉店の日付は店のタイムゾーンで数える() {
        // NY の店 10:00–22:00。NY 14:00 は東京では翌日 03:00 だが「22時まで」（翌ではない）。
        let h = F.daily(600, 1320, tz: "America/New_York")
        let now = F.at(2026, 10, 5, 14, tz: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(NotificationComposer.closingText(h, now: now), "22時まで")
    }

    func test深夜をまたぐ営業の0時台は同じ日の閉店として書く() {
        // 22:00〜翌2:00。now = 翌日 01:00 は前日開店の枠の中 → 「2時まで」（翌ではない）。
        let h = overnight(22 * 60, 26 * 60)
        XCTAssertEqual(NotificationComposer.closingText(h, now: F.at(2026, 10, 6, 1)), "2時まで")
        XCTAssertEqual(NotificationComposer.closingText(h, now: F.at(2026, 10, 5, 23)), "翌2時まで")
    }

    func test徒歩分数の境界() {
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: 0), 1)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: 0.1), 1)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: 80), 1)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: 80.01), 2)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: 160), 2)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: 500), 7)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: -5), 1)
        XCTAssertEqual(NotificationComposer.walkingMinutes(meters: .nan), 1)
    }

    func test同距離の行はチェーンの出現順_距離が近い行が先() {
        let s = F.fujisawa
        let b1 = F.branch("b1", chain: "ダイソー", name: "ダイソー 藤沢店", near: [(s, 200)])
        let b2 = F.branch("b2", chain: "無印良品", name: "無印良品 藤沢店", near: [(s, 200)])
        let b3 = F.branch("b3", chain: "セリア", name: "セリア 藤沢店", near: [(s, 100)])
        let lines = [BranchLine(branch: b1, meters: 200, tasks: [F.task("ダイソー", "a")]),
                     BranchLine(branch: b2, meters: 200, tasks: [F.task("無印良品", "b")]),
                     BranchLine(branch: b3, meters: 100, tasks: [F.task("セリア", "c")])]
        let c = NotificationComposer.compose(station: s, lines: lines, now: F.at(2026, 10, 5, 15), timeZone: F.tokyo)
        let names = c.body.split(separator: "\n").map { line -> String in
            let t = line.replacingOccurrences(of: "藤沢駅｜", with: "")
            return String(t.prefix(while: { $0 != "（" }))
        }
        XCTAssertEqual(names, ["セリア 藤沢店", "ダイソー 藤沢店", "無印良品 藤沢店"])
    }

    func test品目の完全一致の重複だけ消す() {
        let b = F.branch("b", name: "ダイソー 藤沢店")
        let tasks = [F.task("ダイソー", "電池"), F.task("ダイソー", "電池"), F.task("ダイソー", "でんち")]
        let c = NotificationComposer.compose(station: F.fujisawa, lines: [BranchLine(branch: b, meters: 320, tasks: tasks)], now: F.at(2026, 10, 5, 15), timeZone: F.tokyo)
        XCTAssertEqual(c.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：電池、でんち")
        XCTAssertEqual(c.taskIDs.count, 3)   // ボタンは載った全タスクが対象
    }

    // MARK: 監視計画

    private func station(_ i: Int, enabled: Bool = true, lat: Double? = nil, lon: Double? = nil) -> Station {
        Station(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!, name: "駅\(i)",
                coordinate: Coordinate(latitude: lat ?? 35.0 + Double(i) * 0.01, longitude: lon ?? 139.0), isEnabled: enabled)
    }

    func test監視はちょうど20駅なら全部で位置変化は購読しない_21駅の無効1つでも同じ() {
        let tasks = [F.task("ダイソー", "a")]
        let twenty = Ledger(tasks: tasks, stations: (1...20).map { station($0) })
        let p = MonitoringPlanner.plan(ledger: twenty, now: F.at(2026, 10, 5), deviceLocation: nil)
        XCTAssertEqual(p.stations.count, 20)
        XCTAssertFalse(p.tracksSignificantLocationChanges)
        let withDisabled = Ledger(tasks: tasks, stations: (1...20).map { station($0) } + [station(21, enabled: false)])
        XCTAssertEqual(MonitoringPlanner.plan(ledger: withDisabled, now: F.at(2026, 10, 5), deviceLocation: nil), p)
    }

    func test21駅で端末が動くと入れ替わり_同じ集合なら同じ計画() {
        let l = Ledger(tasks: [F.task("ダイソー", "a")], stations: (1...21).map { station($0) })
        let south = Coordinate(latitude: 35.0, longitude: 139.0)     // 駅1 付近 → 駅21 が落ちる
        let north = Coordinate(latitude: 35.3, longitude: 139.0)     // 駅21 付近 → 駅1 が落ちる
        let a = MonitoringPlanner.plan(ledger: l, now: F.at(2026, 10, 5), deviceLocation: south)
        let b = MonitoringPlanner.plan(ledger: l, now: F.at(2026, 10, 5), deviceLocation: north)
        XCTAssertTrue(a.tracksSignificantLocationChanges)
        XCTAssertFalse(a.stations.contains { $0.name == "駅21" })
        XCTAssertFalse(b.stations.contains { $0.name == "駅1" })
        XCTAssertEqual(a.stations.map(\.name), (1...20).map { "駅\($0)" })   // 台帳順
        XCTAssertEqual(MonitoringPlanner.plan(ledger: l, now: F.at(2026, 10, 5), deviceLocation: Coordinate(latitude: 35.001, longitude: 139.0)), a)
    }

    func test上限超えで端末位置が無ければ台帳の先頭から20() {
        let l = Ledger(tasks: [F.task("ダイソー", "a")], stations: (1...25).map { station($0) })
        let p = MonitoringPlanner.plan(ledger: l, now: F.at(2026, 10, 5), deviceLocation: nil)
        XCTAssertEqual(p.stations.map(\.name), (1...20).map { "駅\($0)" })
        XCTAssertTrue(p.tracksSignificantLocationChanges)
    }

    func test同距離の駅は台帳の並びが先_座標が壊れた駅は最後() {
        var stations = (1...20).map { station($0, lat: 35.0, lon: 139.0) }      // 全部同じ位置
        stations.append(station(21, lat: 35.0, lon: 139.0))
        stations.append(station(22, lat: .nan, lon: .nan))
        let l = Ledger(tasks: [F.task("ダイソー", "a")], stations: stations)
        let p = MonitoringPlanner.plan(ledger: l, now: F.at(2026, 10, 5), deviceLocation: Coordinate(latitude: 35.0, longitude: 139.0))
        XCTAssertEqual(p.stations.map(\.name), (1...20).map { "駅\($0)" })
    }

    func test無効な駅だけなら未完了があっても空の計画() {
        let l = Ledger(tasks: [F.task("ダイソー", "a")], stations: [station(1, enabled: false)])
        XCTAssertEqual(MonitoringPlanner.plan(ledger: l, now: F.at(2026, 10, 5), deviceLocation: nil), .stopped)
    }

    func test完了と無期限の無視だけなら止め_今日は無視は続ける_D13() {
        let s = [station(1)]
        let done = Ledger(tasks: [F.task("ダイソー", "a", status: .done), F.task("ダイソー", "b", status: .ignored)], stations: s)
        XCTAssertEqual(MonitoringPlanner.plan(ledger: done, now: F.at(2026, 10, 5), deviceLocation: nil), .stopped)
        let until = Ledger(tasks: [F.task("ダイソー", "b", status: .ignored, ignoredUntil: F.at(2026, 10, 6))], stations: s)
        XCTAssertEqual(MonitoringPlanner.plan(ledger: until, now: F.at(2026, 10, 5), deviceLocation: nil).stations.count, 1)
    }

    // MARK: 入域ハンドラ

    private func handler(_ l: Ledger, tz: TimeZone = F.tokyo, store: LedgerStore? = nil) async throws -> (StationEntryHandler, LedgerRepository, FakePoster) {
        let repo = try await LedgerRepository.open(store: store ?? InMemoryLedgerStore(l))
        let poster = FakePoster()
        return (StationEntryHandler(repository: repo, poster: poster, timeZone: { tz }), repo, poster)
    }

    private var base: Ledger {
        ledger(tasks: [F.task("ダイソー", "a")], branches: [F.branch("b", near: [(F.fujisawa, 320), (F.tsujido, 500)])])
    }

    func test全駅1日1回で2駅から同時に20入域しても1通() async throws {
        var l = base; l.settings.frequency = .oncePerDay
        let (h, repo, poster) = try await handler(l)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<20 {
                g.addTask { _ = try await h.handle(TriggerEvent(stationID: (i % 2 == 0 ? F.fujisawa : F.tsujido).id, firedAt: F.at(2026, 10, 5, 15, 0, i))) }
            }
            try await g.waitForAll()
        }
        XCTAssertEqual(poster.posted.count, 1)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.filter { $0.result == .notified }.count, 1)
    }

    func test駅ごと1日1回は2駅で2通() async throws {
        let (h, _, poster) = try await handler(base)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<10 {
                g.addTask { _ = try await h.handle(TriggerEvent(stationID: (i % 2 == 0 ? F.fujisawa : F.tsujido).id, firedAt: F.at(2026, 10, 5, 15, 0, i))) }
            }
            try await g.waitForAll()
        }
        XCTAssertEqual(poster.posted.count, 2)
    }

    func test入域のたびなら同時5入域は5通() async throws {
        var l = base; l.settings.frequency = .everyEntry
        let (h, _, poster) = try await handler(l)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<5 { g.addTask { _ = try await h.handle(TriggerEvent(stationID: F.fujisawa.id, firedAt: F.at(2026, 10, 5, 15, 0, i))) } }
            try await g.waitForAll()
        }
        XCTAssertEqual(poster.posted.count, 5)
    }

    func test履歴が上限でも通知失敗の書き換えが効く() async throws {
        let old = (0..<Tuning.maxHistoryRecords).map { F.record(F.tsujido, .suppressedNoBranch, at: F.at(2026, 9, 1, 0, 0, 0).addingTimeInterval(Double($0))) }
        var l = base; l.history = old
        let (h, repo, poster) = try await handler(l)
        poster.failure = FakePoster.Failure()
        let o = try await h.handle(TriggerEvent(stationID: F.fujisawa.id, firedAt: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(o?.record.result, .failedToPost)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, Tuning.maxHistoryRecords)
        XCTAssertEqual(history.last?.result, .failedToPost)
        XCTAssertEqual(history.last?.id, o?.record.id)
    }

    func test失敗した通知の後の再入域で通知が出て_履歴は2行() async throws {
        let (h, repo, poster) = try await handler(base)
        poster.failure = FakePoster.Failure()
        _ = try await h.handle(TriggerEvent(stationID: F.fujisawa.id, firedAt: F.at(2026, 10, 5, 15)))
        poster.failure = nil
        let o = try await h.handle(TriggerEvent(stationID: F.fujisawa.id, firedAt: F.at(2026, 10, 5, 15, 5)))
        XCTAssertEqual(o?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 1)
        let results = await repo.snapshot().history.map(\.result)
        XCTAssertEqual(results, [.failedToPost, .notified])
    }

    func test古いイベントでも判定は発火時刻で行う_昨日の営業時間外() async throws {
        let (h, _, poster) = try await handler(base)
        // 今は昼だが、イベントは 03:00（閉店中）。
        let o = try await h.handle(TriggerEvent(stationID: F.fujisawa.id, firedAt: F.at(2026, 10, 5, 3)))
        XCTAssertEqual(o?.record.result, .suppressedClosed)
        XCTAssertTrue(poster.posted.isEmpty)
    }

    // MARK: 今日の営業時間

    private func tokyoHours(weekly: [WeeklyPeriod] = [], special: [SpecialDay] = []) -> OpeningHours {
        OpeningHours(timeZoneID: "Asia/Tokyo", weekly: weekly, specialDays: special)
    }

    // 2026-10-05 は月曜 (1)。
    func test枠なしは休み() {
        XCTAssertEqual(tokyoHours().todayText(at: F.at(2026, 10, 5, 12)), "休み")
        XCTAssertEqual(tokyoHours(weekly: [WeeklyPeriod(openDay: 2, openMinute: 600, closeDay: 2, closeMinute: 1200)]).todayText(at: F.at(2026, 10, 5, 12)), "休み")
    }

    func test今日の日付は店のタイムゾーンで決まる() {
        // 10-05 16:00 UTC = 10-06 01:00 JST（火曜 = 2）。
        let h = tokyoHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1200),
                                    WeeklyPeriod(openDay: 2, openMinute: 660, closeDay: 2, closeMinute: 1260)])
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 5, 16, tz: F.utc)), "11:00–21:00")
    }

    func test前日から続く枠は今日の枠に出さない() {
        // 日曜 22:00 → 月曜 02:00。月曜の枠は 10:00–20:00 だけ。
        let h = tokyoHours(weekly: [WeeklyPeriod(openDay: 0, openMinute: 1320, closeDay: 1, closeMinute: 120),
                                    WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1200)])
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 5, 1)), "10:00–20:00")
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 4, 12)), "22:00–翌2:00")
    }

    func test24時閉店と翌々日と接触する枠() {
        let h = tokyoHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 2, closeMinute: 0)])
        XCTAssertEqual(h.todayText(at: F.at(2026, 10, 5, 12)), "10:00–24:00")
        let long = tokyoHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 3, closeMinute: 90)])
        XCTAssertEqual(long.todayText(at: F.at(2026, 10, 5, 12)), "10:00–翌々1:30")
        let touching = tokyoHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 840),
                                           WeeklyPeriod(openDay: 1, openMinute: 840, closeDay: 1, closeMinute: 1200),
                                           WeeklyPeriod(openDay: 1, openMinute: 1260, closeDay: 1, closeMinute: 1320)])
        XCTAssertEqual(touching.todayText(at: F.at(2026, 10, 5, 12)), "10:00–20:00、21:00–22:00")
    }

    func test特別日は週の枠を置き換え_空なら休み_不正な枠は捨てる() {
        let weekly = [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1200)]
        let day = CalendarDay(year: 2026, month: 10, day: 5)
        let replaced = tokyoHours(weekly: weekly, special: [SpecialDay(date: day, periods: [DayPeriod(openMinute: 720, closeMinute: 900)])])
        XCTAssertEqual(replaced.todayText(at: F.at(2026, 10, 5, 8)), "12:00–15:00")
        XCTAssertEqual(tokyoHours(weekly: weekly, special: [SpecialDay(date: day, periods: [])]).todayText(at: F.at(2026, 10, 5, 8)), "休み")
        let bad = tokyoHours(weekly: weekly, special: [SpecialDay(date: day, periods: [DayPeriod(openMinute: 900, closeMinute: 900), DayPeriod(openMinute: 1500, closeMinute: 1600)])])
        XCTAssertEqual(bad.todayText(at: F.at(2026, 10, 5, 8)), "休み")
        // 同じ日付の特別日が 2 件でも両方の枠を使う（評価と同じ）。
        let two = tokyoHours(weekly: weekly, special: [SpecialDay(date: day, periods: [DayPeriod(openMinute: 600, closeMinute: 700)]),
                                                         SpecialDay(date: day, periods: [DayPeriod(openMinute: 800, closeMinute: 900)])])
        XCTAssertEqual(two.todayText(at: F.at(2026, 10, 5, 8)), "10:00–11:40、13:20–15:00")
    }

    func test24時間営業フラグ() {
        XCTAssertEqual(OpeningHours(isAlwaysOpen: true).todayText(at: F.at(2026, 10, 5)), "24時間営業")
    }
}
