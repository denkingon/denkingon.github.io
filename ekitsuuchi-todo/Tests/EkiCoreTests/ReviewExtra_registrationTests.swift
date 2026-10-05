import XCTest
@testable import EkiCore

// レビュー（独立）で足した、登録処理を壊しにいくテスト。

private final class RxSearch: StoreSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Double: Result<[BranchCandidate], Error>] = [:]
    private var _calls = 0
    var onCall: (@Sendable () async -> Void)?

    var calls: Int { lock.withLock { _calls } }
    func set(_ s: Station, _ r: Result<[BranchCandidate], Error>) { lock.withLock { answers[s.coordinate.latitude] = r } }

    func searchBranches(chainName: String, near center: Coordinate, radiusMeters: Double) async throws -> [BranchCandidate] {
        let a: Result<[BranchCandidate], Error>? = lock.withLock { _calls += 1; return answers[center.latitude] }
        await onCall?()
        switch a {
        case .some(.success(let c)): return c
        case .some(.failure(let e)): throw e
        case .none: return []
        }
    }
}

private final class RxHours: BusinessHoursProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<OpeningHours?, Error>] = [:]
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func set(_ id: String, _ r: Result<OpeningHours?, Error>) { lock.withLock { answers[id] = r } }
    func openingHours(placeID: String) async throws -> OpeningHours? {
        let a: Result<OpeningHours?, Error>? = lock.withLock { _calls.append(placeID); return answers[placeID] }
        switch a {
        case .some(.success(let h)): return h
        case .some(.failure(let e)): throw e
        case .none: return OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1200)])
        }
    }
}

private struct RxBoom: LocalizedError { var errorDescription: String? { "boom" } }

final class ReviewExtraRegistrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_193_320)
    private let fuji = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4896))
    private let tsuji = Station(name: "辻堂駅", coordinate: Coordinate(latitude: 35.3369, longitude: 139.4478))

    private func cand(_ id: String, lat: Double = 35.3400, lon: Double = 139.4900, name: String = "ダイソー 店") -> BranchCandidate {
        BranchCandidate(placeID: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }

    private func rig(_ ledger: Ledger, store: LedgerStore? = nil) async throws
        -> (LedgerRepository, RxSearch, RxHours, ChainRegistrar) {
        let repo = try await LedgerRepository.open(store: store ?? InMemoryLedgerStore(ledger))
        let s = RxSearch(), h = RxHours()
        let at = now
        return (repo, s, h, ChainRegistrar(repository: repo, search: s, hours: h, now: { at }))
    }

    /// 非有限の座標は JSON に載らず、1 件のせいで保存が丸ごと失敗していた。
    func test非有限の座標の候補は捨てて他の支店は保存される() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileLedgerStore(url: dir.appendingPathComponent("ledger.json"))
        let (repo, search, _, registrar) = try await rig(Ledger(), store: store)
        try await repo.upsertStation(fuji)
        search.set(fuji, .success([
            cand("p-nan", lat: .nan, lon: 139.49),
            cand("p-inf", lat: 35.34, lon: .infinity),
            cand("p-ok"),
        ]))
        let report = await registrar.register(chainName: "ダイソー")
        XCTAssertNil(report.ledgerError)
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id), ["p-ok"])
        XCTAssertEqual(report.branchesKept, 1)
    }

    /// 同じチェーンを同時に 2 回登録しても支店が重複しない。
    func test同時の二重登録でも支店は重複しない() async throws {
        let (repo, search, _, registrar) = try await rig(Ledger(stations: [fuji, tsuji]))
        search.set(fuji, .success([cand("p1"), cand("p2")]))
        search.set(tsuji, .success([cand("p2", lat: 35.3375, lon: 139.4480)]))
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<6 { g.addTask { _ = await registrar.register(chainName: "ダイソー") } }
        }
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id).sorted(), ["p1", "p2"])
        XCTAssertEqual(ledger.branches.first { $0.id == "p2" }?.nearestStations.count, 2)
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
    }

    /// register と registerStation が重なっても、駅の紐づきが重複しない。
    func test登録と駅の再実行が重なっても紐づきは重複しない() async throws {
        let (repo, search, _, registrar) = try await rig(Ledger(stations: [fuji], registeredChains: ["ダイソー"]))
        search.set(fuji, .success([cand("p1")]))
        await withTaskGroup(of: Void.self) { g in
            g.addTask { _ = await registrar.register(chainName: "ダイソー") }
            g.addTask { _ = await registrar.registerStation(id: self.fuji.id) }
            g.addTask { _ = await registrar.registerStation(id: self.fuji.id) }
        }
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.branches.count, 1)
        XCTAssertEqual(ledger.branches[0].nearestStations.count, 1)
    }

    /// 通信中に無効にされた駅は検索しない。
    func test通信中に無効にされた駅は検索しない() async throws {
        let (repo, search, _, registrar) = try await rig(Ledger(stations: [fuji, tsuji]))
        search.set(fuji, .success([cand("p1")]))
        search.set(tsuji, .success([cand("p2")]))
        let off = tsuji
        search.onCall = { [repo] in
            var s = off
            s.isEnabled = false
            try? await repo.upsertStation(s)
        }
        let report = await registrar.register(chainName: "ダイソー")
        XCTAssertEqual(search.calls, 1)
        XCTAssertEqual(report.stationsSearched, 1)
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id), ["p1"])
    }

    /// 同名の駅が 2 つ失敗しても、失敗は 2 件残る。
    func test同名の駅の失敗は上書きしない() async throws {
        let a = Station(name: "同名駅", coordinate: Coordinate(latitude: 35.1, longitude: 139.1))
        let b = Station(name: "同名駅", coordinate: Coordinate(latitude: 35.2, longitude: 139.2))
        let (_, search, _, registrar) = try await rig(Ledger(stations: [a, b]))
        search.set(a, .failure(RxBoom()))
        search.set(b, .failure(RxBoom()))
        let report = await registrar.register(chainName: "ダイソー")
        XCTAssertEqual(report.stationFailures.count, 2)
        XCTAssertEqual(report.stationsSearched, 2)
    }

    /// 全角・半角違いで登録済みのチェーンに、別の表記で再登録しても名前は増えず、支店は最初の表記で保存される。
    func test別の表記で再登録しても名前は増えない() async throws {
        let (repo, search, _, registrar) = try await rig(Ledger(stations: [fuji], registeredChains: ["ダイソー"]))
        search.set(fuji, .success([cand("p1")]))
        let report = await registrar.register(chainName: " ﾀﾞｲｿｰ ")
        XCTAssertEqual(report.chainName, "ダイソー")
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
        XCTAssertEqual(ledger.branches.map(\.chainName), ["ダイソー"])
    }

    /// 駅に紐づく支店が 0 件の既存支店（手で作った等）は、検索に出なくても消さない。
    func test最初から駅を持たない既存支店は検索に出なくても消さない() async throws {
        let orphan = Branch(id: "p-orphan", chainName: "ダイソー", name: "ダイソー 孤立店", coordinate: Coordinate(latitude: 35, longitude: 139))
        let (repo, search, _, registrar) = try await rig(Ledger(stations: [fuji], branches: [orphan], registeredChains: ["ダイソー"]))
        search.set(fuji, .success([]))
        _ = await registrar.register(chainName: "ダイソー")
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id), ["p-orphan"])
    }

    /// 営業時間の取得が CancellationError を（キャンセルされていないのに）投げた場合も何も反映しない。
    func test営業時間がCancellationErrorなら名前だけ残して反映しない() async throws {
        let (repo, search, hours, registrar) = try await rig(Ledger(stations: [fuji]))
        search.set(fuji, .success([cand("p1")]))
        hours.set("p1", .failure(CancellationError()))
        let report = await registrar.register(chainName: "ダイソー")
        XCTAssertTrue(report.hoursFailures.isEmpty)
        let ledger = await repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty)
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
    }

    /// ensureRegistered: 表記違いの重複と空白だけの名前。
    func testensureRegisteredは表記違いの重複と空を1回にまとめる() async throws {
        let (repo, search, _, registrar) = try await rig(Ledger(stations: [fuji]))
        search.set(fuji, .success([cand("p1")]))
        let reports = await registrar.ensureRegistered(chains: ["ダイソー", "ﾀﾞｲｿｰ", "  ", "ＤＡＩＳＯ", "daiso"])
        XCTAssertEqual(reports.map(\.chainName), ["ダイソー", "ＤＡＩＳＯ"], "ダイソー と daiso は別のチェーン（key が違う）")
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.registeredChains.count, 2)
    }

    // MARK: 週 1 更新

    private func branch(_ id: String, chain: String = "ダイソー", fetched: Date?) -> Branch {
        Branch(id: id, chainName: chain, name: id, coordinate: Coordinate(latitude: 35.34, longitude: 139.49),
               hours: nil, hoursFetchedAt: fetched, nearestStations: [StationDistance(stationID: UUID(), meters: 100)])
    }

    /// 同じ支店 id を持つ重複タスク・複数タスクでも 1 回しか通信しない。
    func test同じチェーンのタスクが複数あっても支店ごとに1回だけ取得する() async throws {
        let tasks = (0..<3).map { TodoTask(store: "ダイソー", item: "品\($0)", createdAt: now) }
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(tasks: tasks, branches: [branch("b1", fetched: nil)])))
        let h = RxHours()
        let r = HoursRefresher(repository: repo, hours: h, now: { self.now })
        let report = await r.refreshStale()
        XCTAssertEqual(h.calls, ["b1"])
        XCTAssertEqual(report, RefreshReport(refreshed: 1, failed: [:], skipped: 0))
    }

    /// 2 つの refreshStale が同時に走っても台帳が壊れない（どちらも同じ結果を書く）。
    func test同時の更新でも台帳は整合する() async throws {
        let tasks = [TodoTask(store: "ダイソー", item: "x", createdAt: now)]
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(tasks: tasks, branches: [branch("b1", fetched: nil), branch("b2", fetched: nil)])))
        let h = RxHours()
        let r = HoursRefresher(repository: repo, hours: h, now: { self.now })
        async let a = r.refreshStale()
        async let b = r.refreshStale()
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra.refreshed, 2)
        XCTAssertEqual(rb.refreshed, 2)
        let ledger = await repo.snapshot()
        XCTAssertEqual(ledger.branches.count, 2)
        XCTAssertTrue(ledger.branches.allSatisfy { $0.hoursFetchedAt == now && $0.hours != nil })
        let due = await r.isDue()
        XCTAssertFalse(due)
    }

    /// 失敗と成功が混ざったときの件数の合計 = 支店数。
    func test件数の合計は支店数に一致する() async throws {
        let tasks = [TodoTask(store: "ダイソー", item: "x", createdAt: now)]
        let branches = [
            branch("fresh", fetched: now),
            branch("bad", fetched: nil),
            branch("ok", fetched: nil),
            branch("other", chain: "セリア", fetched: nil),
        ]
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(tasks: tasks, branches: branches)))
        let h = RxHours()
        h.set("bad", .failure(RxBoom()))
        let r = HoursRefresher(repository: repo, hours: h, now: { self.now })
        let report = await r.refreshStale()
        XCTAssertEqual(report.refreshed, 1)
        XCTAssertEqual(report.failed, ["bad": "boom"])
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(report.refreshed + report.failed.count + report.skipped, branches.count)
    }

    /// 店の表記の揺れ（全角・空白）でも使用中と判定する。
    func test使用中の判定はタスクの店の空白や全角を無視する() async throws {
        let tasks = [TodoTask(store: " ＤＡＩＳＯ ", item: "x", createdAt: now)]
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(tasks: tasks, branches: [branch("b1", chain: "daiso", fetched: nil)])))
        let r = HoursRefresher(repository: repo, hours: RxHours(), now: { self.now })
        let due = await r.isDue()
        XCTAssertTrue(due)
    }
}
