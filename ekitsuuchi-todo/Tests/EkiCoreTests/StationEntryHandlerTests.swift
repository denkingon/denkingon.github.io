import XCTest
@testable import EkiCore

/// 通知を記録する偽の差し替え口。`failure` を入れると post が投げる。
final class FakePoster: NotificationPosting, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "通知が許可されていません（設定 > 通知）" }
    }

    private let lock = NSLock()
    private var _posted: [NotificationContent] = []
    private var _failure: Error?

    var posted: [NotificationContent] { lock.lock(); defer { lock.unlock() }; return _posted }
    var failure: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); defer { lock.unlock() }; _failure = newValue }
    }

    func post(_ content: NotificationContent) async throws {
        await Task.yield()   // 実際の UNUserNotificationCenter と同じく中断点がある → 同時入域の割り込みを起こす
        if let failure { throw failure }
        lock.withLock { _posted.append(content) }
    }
}

/// open 後だけ保存を失敗させられる台帳ストア。
final class SwitchableFailingStore: LedgerStore, @unchecked Sendable {
    struct Boom: Error {}
    private let inner: InMemoryLedgerStore
    private let lock = NSLock()
    private var _failSaves = false
    var failSaves: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failSaves }
        set { lock.lock(); defer { lock.unlock() }; _failSaves = newValue }
    }
    init(_ ledger: Ledger) { inner = InMemoryLedgerStore(ledger) }
    func load() throws -> Ledger { try inner.load() }
    func save(_ ledger: Ledger) throws {
        if failSaves { throw Boom() }
        try inner.save(ledger)
    }
    var stored: Ledger { inner.stored }
}

final class StationEntryHandlerTests: XCTestCase {
    typealias F = JudgeFixtures

    private let daiso = F.task("ダイソー", "フィルム")
    private let battery = F.task("ダイソー", "電池")

    private func fujisawaBranch(hours: OpeningHours? = F.h10to21) -> Branch {
        F.branch("b1", name: "ダイソー 藤沢店", near: [(F.fujisawa, 320), (F.tsujido, 700)], hours: hours)
    }

    private func make(
        tasks: [TodoTask]? = nil, branches: [Branch]? = nil, settings: Settings = Settings(),
        stations: [Station] = [F.fujisawa, F.tsujido], tz: TimeZone = F.tokyo
    ) async throws -> (StationEntryHandler, LedgerRepository, FakePoster) {
        let ledger = Ledger(tasks: tasks ?? [daiso, battery], stations: stations,
                            branches: branches ?? [fujisawaBranch()], settings: settings)
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(ledger))
        let poster = FakePoster()
        return (StationEntryHandler(repository: repo, poster: poster, timeZone: { tz }), repo, poster)
    }

    private func enter(_ station: Station = F.fujisawa, at date: Date, location: LocationFix? = nil) -> TriggerEvent {
        TriggerEvent(stationID: station.id, firedAt: date, location: location)
    }

    // MARK: 通知する

    func test通知する_履歴1行_通知1通() async throws {
        let (handler, repo, poster) = try await make()
        let fix = LocationFix(coordinate: Coordinate(latitude: 35.339, longitude: 139.49), horizontalAccuracy: 40, timestamp: F.at(2026, 10, 5, 18, 41))
        let outcome = try await handler.handle(enter(at: F.at(2026, 10, 5, 18, 42), location: fix))
        XCTAssertEqual(outcome?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 1)
        XCTAssertEqual(poster.posted.first?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池")
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first, outcome?.record)
        XCTAssertEqual(history.first?.location, fix)
        XCTAssertEqual(history.first?.firedAt, F.at(2026, 10, 5, 18, 42))
    }

    func test通知は記録の後に出す() async throws {
        // post が呼ばれた時点で、履歴にはもう .notified が書かれている（原子性の裏づけ）。
        let ledger = Ledger(tasks: [daiso], stations: [F.fujisawa], branches: [fujisawaBranch()])
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(ledger))
        final class Probe: NotificationPosting, @unchecked Sendable {
            let repo: LedgerRepository
            private let lock = NSLock()
            private var _seen: [NotificationResult] = []
            init(_ r: LedgerRepository) { repo = r }
            var seen: [NotificationResult] { lock.lock(); defer { lock.unlock() }; return _seen }
            func post(_ content: NotificationContent) async throws {
                let r = await repo.snapshot().history.map(\.result)
                lock.withLock { _seen = r }
            }
        }
        let probe = Probe(repo)
        let handler = StationEntryHandler(repository: repo, poster: probe, timeZone: { F.tokyo })
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(probe.seen, [.notified])
    }

    // MARK: 抑制ごと

    func test抑制は通知を出さず履歴だけ残す() async throws {
        // 未完了なし
        var (handler, repo, poster) = try await make(tasks: [])
        var o = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(o?.record.result, .suppressedNoPendingTasks)
        XCTAssertEqual(poster.posted.count, 0)
        var history = await repo.snapshot().history
        XCTAssertEqual(history.map(\.result), [.suppressedNoPendingTasks])

        // 支店なし
        (handler, repo, poster) = try await make(branches: [])
        o = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(o?.record.result, .suppressedNoBranch)

        // 営業時間外
        (handler, repo, poster) = try await make()
        o = try await handler.handle(enter(at: F.at(2026, 10, 5, 22)))
        XCTAssertEqual(o?.record.result, .suppressedClosed)
        XCTAssertEqual(poster.posted.count, 0)
        history = await repo.snapshot().history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.detail, "ダイソー 藤沢店は営業時間外")
    }

    func test営業時間外の抑制は今日を消費しない() async throws {
        let (handler, repo, poster) = try await make()
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 8)))     // 開店前 → 抑制
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 12)))    // 営業中 → 通知
        XCTAssertEqual(poster.posted.count, 1)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.map(\.result), [.suppressedClosed, .notified])
    }

    // MARK: 今日通知済

    func test同じ駅の2回目は今日通知済で抑制_別の駅は通知() async throws {
        let (handler, repo, poster) = try await make()
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 10, 30)))
        let second = try await handler.handle(enter(at: F.at(2026, 10, 5, 18)))
        XCTAssertEqual(second?.record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(second?.record.detail, "今日 10:30 に通知済")
        let tsujido = try await handler.handle(enter(F.tsujido, at: F.at(2026, 10, 5, 18, 5)))
        XCTAssertEqual(tsujido?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 2)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.map(\.result), [.notified, .suppressedAlreadyNotifiedToday, .notified])
    }

    func test日付をまたぐと東京の0時で再び通知する() async throws {
        let (handler, _, poster) = try await make(branches: [F.branch("b1", name: "ダイソー 藤沢店", near: [(F.fujisawa, 320)], hours: OpeningHours(isAlwaysOpen: true))])
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 23, 59, 58)))
        let same = try await handler.handle(enter(at: F.at(2026, 10, 5, 23, 59, 59)))
        XCTAssertEqual(same?.record.result, .suppressedAlreadyNotifiedToday)
        let next = try await handler.handle(enter(at: F.at(2026, 10, 6, 0, 0, 0)))
        XCTAssertEqual(next?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 2)
    }

    func test端末のタイムゾーンが変わると今日の区切りも変わる_D14() async throws {
        // 同じ 2 つの入域でも、UTC の端末なら 10-04 と 10-05 の別の日。
        let hours = OpeningHours(isAlwaysOpen: true)
        let (handler, _, poster) = try await make(branches: [F.branch("b1", name: "ダイソー 藤沢店", near: [(F.fujisawa, 320)], hours: hours)], tz: F.utc)
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 8)))    // 10-04 23:00 UTC
        let o = try await handler.handle(enter(at: F.at(2026, 10, 5, 10)))  // 10-05 01:00 UTC
        XCTAssertEqual(o?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 2)
    }

    // MARK: 通知の失敗（D9）

    func test通知の失敗は履歴をfailedToPostにして返す_投げない() async throws {
        let (handler, repo, poster) = try await make()
        poster.failure = FakePoster.Failure()
        let o = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(o?.record.result, .failedToPost)
        XCTAssertEqual(o?.record.detail, "通知を出せませんでした: 通知が許可されていません（設定 > 通知）")
        XCTAssertNil(o?.notification)
        XCTAssertEqual(poster.posted.count, 0)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 1, "行を増やさず書き換える")
        XCTAssertEqual(history.first, o?.record)
        XCTAssertEqual(history.first?.taskIDs.count, 2, "何を通知しようとしたかは残る")
    }

    func test失敗した通知は今日を消費しない() async throws {
        let (handler, repo, poster) = try await make()
        poster.failure = FakePoster.Failure()
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 11)))
        poster.failure = nil   // 許可した
        let again = try await handler.handle(enter(at: F.at(2026, 10, 5, 12)))
        XCTAssertEqual(again?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 1)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.map(\.result), [.failedToPost, .notified])
    }

    func test失敗の理由が説明を持たない型でも書く() async throws {
        struct Plain: Error {}
        let (handler, _, poster) = try await make()
        poster.failure = Plain()
        let o = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(o?.record.result, .failedToPost)
        XCTAssertTrue(o?.record.detail?.hasPrefix("通知を出せませんでした: ") == true)
    }

    // MARK: 同時入域

    func test同時に2つの入域が来ても通知は1通() async throws {
        let (handler, repo, poster) = try await make()
        let results = try await withThrowingTaskGroup(of: NotificationResult?.self) { group in
            for i in 0..<2 {
                group.addTask { try await handler.handle(self.enter(at: F.at(2026, 10, 5, 15, 0, i))).map(\.record.result) }
            }
            var all: [NotificationResult?] = []
            for try await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(results.compactMap { $0 }.filter { $0 == .notified }.count, 1)
        XCTAssertEqual(results.compactMap { $0 }.filter { $0 == .suppressedAlreadyNotifiedToday }.count, 1)
        XCTAssertEqual(poster.posted.count, 1)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 2)
    }

    func test同時に20個来ても通知は1通() async throws {
        let (handler, repo, poster) = try await make()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try await handler.handle(self.enter(at: F.at(2026, 10, 5, 15, 0, i))) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(poster.posted.count, 1)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.filter { $0.result == .notified }.count, 1)
        XCTAssertEqual(history.count, 20)
    }

    // MARK: 駅の状態

    func test知らない駅は何も記録せずnil() async throws {
        let (handler, repo, poster) = try await make()
        let ghost = TriggerEvent(stationID: UUID(), firedAt: F.at(2026, 10, 5, 15))
        let o = try await handler.handle(ghost)
        XCTAssertNil(o)
        XCTAssertEqual(poster.posted.count, 0)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 0)
    }

    func test無効な駅の古いイベントは何も記録せずnil() async throws {
        var off = F.fujisawa
        off.isEnabled = false
        let (handler, repo, poster) = try await make(stations: [off, F.tsujido])
        let o = try await handler.handle(enter(off, at: F.at(2026, 10, 5, 15)))
        XCTAssertNil(o)
        XCTAssertEqual(poster.posted.count, 0)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 0)
    }

    // MARK: 実測モード・完了・無視

    func test実測モードは駅名だけ通知し_毎回出す() async throws {
        let (handler, repo, poster) = try await make(tasks: [], branches: [], settings: Settings(diagnosticMode: true))
        let fix = LocationFix(coordinate: Coordinate(latitude: 35.3, longitude: 139.4), horizontalAccuracy: 25, timestamp: F.at(2026, 10, 5, 15))
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 15), location: fix))
        _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 15, 5)))
        XCTAssertEqual(poster.posted.map(\.body), ["藤沢駅に入った", "藤沢駅に入った"])
        let history = await repo.snapshot().history
        XCTAssertEqual(history.map(\.result), [.diagnosticNotified, .diagnosticNotified])
        XCTAssertEqual(history.first?.location, fix)
    }

    func test実測の通知は失敗しても同じく記録する() async throws {
        let (handler, _, poster) = try await make(settings: Settings(diagnosticMode: true))
        poster.failure = FakePoster.Failure()
        let o = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
        XCTAssertEqual(o?.record.result, .failedToPost)
    }

    func test完了してから再入域すると未完了なしで抑制される() async throws {
        let (handler, repo, poster) = try await make(settings: Settings(frequency: .everyEntry))
        let first = try await handler.handle(enter(at: F.at(2026, 10, 5, 12)))
        XCTAssertEqual(first?.record.result, .notified)
        try await repo.complete(taskIDs: poster.posted[0].taskIDs, at: F.at(2026, 10, 5, 12, 1))
        let again = try await handler.handle(enter(at: F.at(2026, 10, 5, 13)))
        XCTAssertEqual(again?.record.result, .suppressedNoPendingTasks)
        XCTAssertEqual(poster.posted.count, 1)
    }

    func test今日は無視は翌日0時まで抑制し_翌日また通知する_D2() async throws {
        let (handler, repo, poster) = try await make(settings: Settings(frequency: .everyEntry))
        let now = F.at(2026, 10, 5, 12)
        try await repo.ignore(taskIDs: [daiso.id, battery.id], untilTomorrow: true, now: now, timeZone: F.tokyo)
        let today = try await handler.handle(enter(at: F.at(2026, 10, 5, 13)))
        XCTAssertEqual(today?.record.result, .suppressedNoPendingTasks)
        let tomorrow = try await handler.handle(enter(at: F.at(2026, 10, 6, 12)))
        XCTAssertEqual(tomorrow?.record.result, .notified)
        XCTAssertEqual(poster.posted.count, 1)
    }

    // MARK: 保存の失敗

    func test履歴を保存できなければ投げて通知も出さない() async throws {
        let store = SwitchableFailingStore(Ledger(tasks: [daiso], stations: [F.fujisawa], branches: [fujisawaBranch()]))
        let repo = try await LedgerRepository.open(store: store)
        let poster = FakePoster()
        let handler = StationEntryHandler(repository: repo, poster: poster, timeZone: { F.tokyo })
        store.failSaves = true
        do {
            _ = try await handler.handle(enter(at: F.at(2026, 10, 5, 15)))
            XCTFail("投げるはず")
        } catch is SwitchableFailingStore.Boom {}
        XCTAssertEqual(poster.posted.count, 0)
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, 0)
        // 直ったら通常どおり。
        store.failSaves = false
        let o = try await handler.handle(enter(at: F.at(2026, 10, 5, 15, 1)))
        XCTAssertEqual(o?.record.result, .notified)
    }

    func test判定はイベントの時刻で行い_履歴の発火時刻もそれ() async throws {
        let (handler, repo, _) = try await make()
        let when = F.at(2026, 10, 5, 12, 34, 56)
        _ = try await handler.handle(enter(at: when))
        let history = await repo.snapshot().history
        XCTAssertEqual(history.first?.firedAt, when)
    }
}
