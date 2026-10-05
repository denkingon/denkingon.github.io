import XCTest
@testable import EkiCore

// MARK: - 偽物

/// 検索の偽物。駅の緯度で答えを決める（駅ごとに別の結果・失敗を返せる）。呼び出しを記録する。
private final class FakeSearch: StoreSearching, @unchecked Sendable {
    struct Call: Equatable { var chainName: String; var center: Coordinate; var radius: Double }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var answers: [Double: Result<[BranchCandidate], Error>] = [:]
    /// 呼び出しの最中に走らせたい処理（途中で台帳を触る・キャンセルする等）。
    var onCall: (@Sendable (Call) async -> Void)?

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func set(_ station: Station, _ result: Result<[BranchCandidate], Error>) {
        lock.lock(); defer { lock.unlock() }
        answers[station.coordinate.latitude] = result
    }

    func searchBranches(chainName: String, near center: Coordinate, radiusMeters: Double) async throws -> [BranchCandidate] {
        let call = Call(chainName: chainName, center: center, radius: radiusMeters)
        let answer: Result<[BranchCandidate], Error>? = lock.withLock { _calls.append(call); return answers[center.latitude] }
        await onCall?(call)
        switch answer {
        case .some(.success(let c)): return c
        case .some(.failure(let e)): throw e
        case .none: return []
        }
    }
}

/// 営業時間の偽物。placeID ごとに答え（営業時間／nil／失敗）を決める。既定は標準の営業時間。
private final class FakeHours: BusinessHoursProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var answers: [String: Result<OpeningHours?, Error>] = [:]
    var onCall: (@Sendable (String) async -> Void)?
    /// true なら、キャンセルされているときに CancellationError を投げる（本物の URLSession と同じ振る舞い）。
    var throwsWhenCancelled = false

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func set(_ id: String, _ result: Result<OpeningHours?, Error>) {
        lock.lock(); defer { lock.unlock() }
        answers[id] = result
    }

    func openingHours(placeID: String) async throws -> OpeningHours? {
        let answer: Result<OpeningHours?, Error>? = lock.withLock { _calls.append(placeID); return answers[placeID] }
        await onCall?(placeID)
        if throwsWhenCancelled { try Task.checkCancellation() }
        switch answer {
        case .some(.success(let h)): return h
        case .some(.failure(let e)): throw e
        case .none: return RegistrationTests.standardHours
        }
    }
}

/// 保存の回数を数え、失敗させられる台帳ストア。
private final class CountingStore: LedgerStore, @unchecked Sendable {
    struct SaveFailure: Error, Equatable {}
    private let lock = NSLock()
    private var ledger: Ledger
    private var _saves = 0
    private var _failing = false

    init(_ ledger: Ledger = Ledger()) { self.ledger = ledger }

    var saves: Int { lock.lock(); defer { lock.unlock() }; return _saves }
    var stored: Ledger { lock.lock(); defer { lock.unlock() }; return ledger }
    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); defer { lock.unlock() }; _failing = newValue }
    }

    func load() throws -> Ledger { lock.lock(); defer { lock.unlock() }; return ledger }
    func save(_ ledger: Ledger) throws {
        lock.lock(); defer { lock.unlock() }
        if _failing { throw SaveFailure() }
        self.ledger = ledger
        _saves += 1
    }
}

/// 通信の途中で止めておくための門。
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "通信失敗" }
}

// MARK: - 店登録

final class RegistrationTests: XCTestCase {
    static let standardHours = OpeningHours(
        weekly: (0...6).map { WeeklyPeriod(openDay: $0, openMinute: 600, closeDay: $0, closeMinute: 1260) }
    )
    private let nightHours = OpeningHours(
        weekly: (0...6).map { WeeklyPeriod(openDay: $0, openMinute: 540, closeDay: $0, closeMinute: 1320) }
    )

    // 2026-10-05 09:42:00 UTC
    private let fixedNow = Date(timeIntervalSince1970: 1_791_193_320)

    private let fujisawa = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4896))
    private let tsujido = Station(name: "辻堂駅", coordinate: Coordinate(latitude: 35.3369, longitude: 139.4478))
    private let kamakura = Station(name: "鎌倉駅", coordinate: Coordinate(latitude: 35.3190, longitude: 139.5509))

    private func candidate(_ id: String, _ name: String, lat: Double, lon: Double) -> BranchCandidate {
        BranchCandidate(placeID: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }

    private var daisoFujisawa: BranchCandidate { candidate("p-daiso-fuji", "ダイソー 藤沢店", lat: 35.3405, lon: 139.4880) }
    private var daisoTsujido: BranchCandidate { candidate("p-daiso-tsuji", "ダイソー 辻堂店", lat: 35.3380, lon: 139.4490) }

    private struct Rig {
        var repo: LedgerRepository
        var store: CountingStore
        var search: FakeSearch
        var hours: FakeHours
        var registrar: ChainRegistrar
    }

    private func makeRig(_ ledger: Ledger) async throws -> Rig {
        let store = CountingStore(ledger)
        let repo = try await LedgerRepository.open(store: store)
        let search = FakeSearch()
        let hours = FakeHours()
        let at = fixedNow
        let registrar = ChainRegistrar(repository: repo, search: search, hours: hours, now: { at })
        return Rig(repo: repo, store: store, search: search, hours: hours, registrar: registrar)
    }

    // MARK: register

    func test名前は通信より先に登録され駅が0件なら検索しない() async throws {
        let rig = try await makeRig(Ledger())
        let report = await rig.registrar.register(chainName: "  ダイソー ")
        XCTAssertEqual(report, RegistrationReport(chainName: "ダイソー"))
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
        XCTAssertTrue(rig.search.calls.isEmpty)
        XCTAssertTrue(rig.hours.calls.isEmpty)
    }

    func test空のチェーン名は登録しない() async throws {
        let rig = try await makeRig(Ledger())
        let report = await rig.registrar.register(chainName: " 　 ")
        XCTAssertNotNil(report.ledgerError)
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.registeredChains.isEmpty)
        XCTAssertEqual(rig.store.saves, 0)
    }

    func test検索は駅座標と既定の半径で有効な駅だけ順番に行う() async throws {
        var off = tsujido
        off.isEnabled = false
        let rig = try await makeRig(Ledger(stations: [fujisawa, off, kamakura]))
        _ = await rig.registrar.register(chainName: "ダイソー")
        XCTAssertEqual(rig.search.calls, [
            .init(chainName: "ダイソー", center: fujisawa.coordinate, radius: Tuning.branchSearchRadiusMeters),
            .init(chainName: "ダイソー", center: kamakura.coordinate, radius: Tuning.branchSearchRadiusMeters),
        ])
    }

    func test同じ支店が2駅から見えたら1件に両駅を持たせ距離は自前のhaversine() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido]))
        let shared = candidate("p-shared", "ダイソー 湘南店", lat: 35.338, lon: 139.469)
        rig.search.set(fujisawa, .success([shared, daisoFujisawa]))
        rig.search.set(tsujido, .success([shared, daisoTsujido]))

        let report = await rig.registrar.register(chainName: "ダイソー")

        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id), ["p-shared", "p-daiso-fuji", "p-daiso-tsuji"])
        let merged = try XCTUnwrap(ledger.branches.first { $0.id == "p-shared" })
        XCTAssertEqual(merged.nearestStations.count, 2)
        XCTAssertEqual(merged.distance(to: fujisawa.id) ?? -1, fujisawa.coordinate.distance(to: shared.coordinate), accuracy: 0.001)
        XCTAssertEqual(merged.distance(to: tsujido.id) ?? -1, tsujido.coordinate.distance(to: shared.coordinate), accuracy: 0.001)
        XCTAssertNotEqual(merged.distance(to: fujisawa.id), merged.distance(to: tsujido.id))
        XCTAssertEqual(ledger.branches.first { $0.id == "p-daiso-fuji" }?.nearestStations.map(\.stationID), [fujisawa.id])
        XCTAssertEqual(report.stationsSearched, 2)
        XCTAssertEqual(report.branchesKept, 3)
        XCTAssertTrue(report.stationFailures.isEmpty)
        XCTAssertNil(report.ledgerError)
    }

    func test同じ駅の結果に重複があっても1件() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        rig.search.set(fujisawa, .success([daisoFujisawa, daisoFujisawa, candidate("", "空ID", lat: 35.34, lon: 139.49)]))
        _ = await rig.registrar.register(chainName: "ダイソー")
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.count, 1, "重複と空の placeID は 1 件にも 0 件にも数えない")
        XCTAssertEqual(ledger.branches[0].nearestStations.count, 1)
        XCTAssertEqual(rig.hours.calls, ["p-daiso-fuji"], "営業時間の取得も 1 回")
    }

    func test新しい支店の営業時間は成功nil失敗で取得日時が違う() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        let ok = daisoFujisawa
        let none = candidate("p-none", "ダイソー 無時間店", lat: 35.3390, lon: 139.4900)
        let bad = candidate("p-bad", "ダイソー 失敗店", lat: 35.3391, lon: 139.4901)
        rig.search.set(fujisawa, .success([ok, none, bad]))
        rig.hours.set("p-daiso-fuji", .success(nightHours))
        rig.hours.set("p-none", .success(nil))
        rig.hours.set("p-bad", .failure(Boom()))

        let report = await rig.registrar.register(chainName: "ダイソー")

        let ledger = await rig.repo.snapshot()
        let byID = Dictionary(uniqueKeysWithValues: ledger.branches.map { ($0.id, $0) })
        XCTAssertEqual(byID["p-daiso-fuji"]?.hours, nightHours)
        XCTAssertEqual(byID["p-daiso-fuji"]?.hoursFetchedAt, fixedNow)
        XCTAssertNil(byID["p-none"]?.hours)
        XCTAssertEqual(byID["p-none"]?.hoursFetchedAt, fixedNow, "「営業時間なし」も取得済み: 毎回は聞き直さない")
        XCTAssertNil(byID["p-bad"]?.hours)
        XCTAssertNil(byID["p-bad"]?.hoursFetchedAt, "失敗は未取得のまま = 次回すぐ再取得")
        XCTAssertEqual(report.hoursFailures, ["ダイソー 失敗店"])
        XCTAssertEqual(report.branchesKept, 3, "営業時間が取れなくても支店は残る")
    }

    func test1駅の失敗は他の駅を巻き込まず失敗した駅の古いデータは触らない() async throws {
        let oldFujisawa = Branch(
            id: "p-old", chainName: "ダイソー", name: "ダイソー 旧藤沢店",
            coordinate: Coordinate(latitude: 35.34, longitude: 139.49),
            hours: nightHours, hoursFetchedAt: fixedNow.addingTimeInterval(-86_400),
            nearestStations: [StationDistance(stationID: fujisawa.id, meters: 250)],
            attributes: ["規模": "大型"]
        )
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido], branches: [oldFujisawa], registeredChains: ["ダイソー"]))
        rig.search.set(fujisawa, .failure(PlacesError.rateLimited))
        rig.search.set(tsujido, .success([daisoTsujido]))

        let report = await rig.registrar.register(chainName: "ダイソー")

        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.first { $0.id == "p-old" }, oldFujisawa, "失敗した駅の分は一切変えない")
        XCTAssertNotNil(ledger.branches.first { $0.id == "p-daiso-tsuji" })
        XCTAssertEqual(report.stationsSearched, 2)
        XCTAssertEqual(Array(report.stationFailures.keys), ["藤沢駅"])
        XCTAssertEqual(report.stationFailures["藤沢駅"], PlacesError.rateLimited.errorDescription)
    }

    func test全駅が失敗しても名前は登録済みで台帳は保存しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        rig.search.set(fujisawa, .failure(Boom()))
        let savesAfterOpen = rig.store.saves
        let report = await rig.registrar.register(chainName: "ダイソー")
        XCTAssertEqual(report.stationFailures, ["藤沢駅": "通信失敗"])
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
        XCTAssertEqual(rig.store.saves, savesAfterOpen + 1, "名前の登録の 1 回だけ")
    }

    func test再登録は属性と営業時間を保ち名前と座標だけ更新し営業時間を取り直さない() async throws {
        let existing = Branch(
            id: "p-daiso-fuji", chainName: "ダイソー", name: "旧名",
            coordinate: Coordinate(latitude: 0, longitude: 0),
            hours: nightHours, hoursFetchedAt: fixedNow.addingTimeInterval(-3 * 86_400),
            nearestStations: [StationDistance(stationID: fujisawa.id, meters: 1)],
            attributes: ["規模": "大型"]
        )
        let rig = try await makeRig(Ledger(stations: [fujisawa], branches: [existing], registeredChains: ["ダイソー"]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))

        let report = await rig.registrar.register(chainName: "ダイソー")

        let after = await rig.repo.snapshot()
        let b = try XCTUnwrap(after.branches.first)
        XCTAssertEqual(b.name, "ダイソー 藤沢店")
        XCTAssertEqual(b.coordinate, daisoFujisawa.coordinate)
        XCTAssertEqual(b.hours, nightHours)
        XCTAssertEqual(b.hoursFetchedAt, existing.hoursFetchedAt)
        XCTAssertEqual(b.attributes, ["規模": "大型"])
        XCTAssertEqual(b.distance(to: fujisawa.id) ?? -1, fujisawa.coordinate.distance(to: daisoFujisawa.coordinate), accuracy: 0.001)
        XCTAssertTrue(rig.hours.calls.isEmpty)
        XCTAssertEqual(report.branchesKept, 1)
    }

    func test返らなくなった支店は消え他の駅から見える支店は駅だけ外れる() async throws {
        let gone = Branch(id: "p-gone", chainName: "ダイソー", name: "閉店した店", coordinate: fujisawa.coordinate,
                          nearestStations: [StationDistance(stationID: fujisawa.id, meters: 100)])
        let both = Branch(id: "p-both", chainName: "ダイソー", name: "両駅の店", coordinate: fujisawa.coordinate,
                          nearestStations: [StationDistance(stationID: fujisawa.id, meters: 100),
                                            StationDistance(stationID: tsujido.id, meters: 200)])
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido], branches: [gone, both], registeredChains: ["ダイソー"]))
        rig.search.set(fujisawa, .success([]))                       // 藤沢からは何も見えなくなった
        rig.search.set(tsujido, .success([candidate("p-both", "両駅の店", lat: 35.3388, lon: 139.4896)]))

        let report = await rig.registrar.register(chainName: "ダイソー")

        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id), ["p-both"])
        XCTAssertEqual(ledger.branches[0].nearestStations.map(\.stationID), [tsujido.id])
        XCTAssertEqual(report.branchesKept, 1)
    }

    func test失敗した駅の紐づきは残り成功した駅の紐づきだけ消える() async throws {
        let both = Branch(id: "p-both", chainName: "ダイソー", name: "両駅の店", coordinate: fujisawa.coordinate,
                          nearestStations: [StationDistance(stationID: fujisawa.id, meters: 100),
                                            StationDistance(stationID: tsujido.id, meters: 200)])
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido], branches: [both], registeredChains: ["ダイソー"]))
        rig.search.set(fujisawa, .failure(Boom()))
        rig.search.set(tsujido, .success([]))

        _ = await rig.registrar.register(chainName: "ダイソー")

        let after = await rig.repo.snapshot()
        let b = try XCTUnwrap(after.branches.first)
        XCTAssertEqual(b.nearestStations, [StationDistance(stationID: fujisawa.id, meters: 100)])
    }

    func test他のチェーンの支店には触れない() async throws {
        let muji = Branch(id: "p-muji", chainName: "無印良品", name: "無印良品 藤沢店", coordinate: fujisawa.coordinate,
                          nearestStations: [StationDistance(stationID: fujisawa.id, meters: 90)])
        let rig = try await makeRig(Ledger(stations: [fujisawa], branches: [muji], registeredChains: ["無印良品"]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        _ = await rig.registrar.register(chainName: "ダイソー")
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(Set(ledger.branches.map(\.id)), ["p-muji", "p-daiso-fuji"])
        XCTAssertEqual(ledger.branches.first { $0.id == "p-muji" }, muji)
    }

    func test別チェーンとして既にあるplaceIDは奪わない() async throws {
        let other = Branch(id: "p-daiso-fuji", chainName: "セリア", name: "セリア 藤沢店", coordinate: fujisawa.coordinate,
                           nearestStations: [StationDistance(stationID: fujisawa.id, meters: 90)])
        let rig = try await makeRig(Ledger(stations: [fujisawa], branches: [other], registeredChains: ["セリア"]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        _ = await rig.registrar.register(chainName: "ダイソー")
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches, [other])
        XCTAssertTrue(rig.hours.calls.isEmpty)
    }

    func test保存される支店のチェーン名は登録済みの表記() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa], registeredChains: ["ＤＡＩＳＯ"]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        let report = await rig.registrar.register(chainName: "daiso")
        XCTAssertEqual(report.chainName, "ＤＡＩＳＯ")
        XCTAssertEqual(rig.search.calls.first?.chainName, "ＤＡＩＳＯ")
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.registeredChains, ["ＤＡＩＳＯ"])
        XCTAssertEqual(ledger.branches.map(\.chainName), ["ＤＡＩＳＯ"])
    }

    func test反映は1回の保存だけ() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido, kamakura]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        rig.search.set(tsujido, .success([daisoTsujido]))
        let before = rig.store.saves
        _ = await rig.registrar.register(chainName: "ダイソー")
        XCTAssertEqual(rig.store.saves - before, 2, "名前の登録 1 回 + 支店の反映 1 回")
    }

    // MARK: 通信は台帳の外・反映時のズレ

    func test通信中も台帳は動き通信前のコピーで上書きしない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        let gate = Gate()
        let entered = Gate()
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        rig.search.onCall = { _ in
            await entered.release()
            await gate.wait()
        }
        let registrar = rig.registrar
        let task = Task { await registrar.register(chainName: "ダイソー") }
        await entered.wait()
        // 検索が止まっている間に別の変更が入る（mutate がロックを持ったまま通信していたらここで詰まる）
        let added = try await rig.repo.addTask(store: "ダイソー", item: "フィルム", now: fixedNow)
        guard case .added = added else { return XCTFail("追加できるはず") }
        await gate.release()
        _ = await task.value

        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.tasks.count, 1, "通信中に入ったタスクが消えていない")
        XCTAssertEqual(ledger.branches.count, 1)
    }

    func test通信中に登録解除されたチェーンには反映しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        let repo = rig.repo
        rig.search.onCall = { _ in try? await repo.unregisterChain("ダイソー") }
        _ = await rig.registrar.register(chainName: "ダイソー")
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty)
        XCTAssertTrue(ledger.registeredChains.isEmpty)
    }

    func test通信中に消された駅には反映しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        rig.search.set(tsujido, .success([daisoTsujido]))
        let repo = rig.repo
        let doomed = tsujido.id
        // 1 駅目の検索中に 2 駅目が消される
        rig.search.onCall = { call in
            if call.center == self.fujisawa.coordinate { try? await repo.removeStation(id: doomed) }
        }
        _ = await rig.registrar.register(chainName: "ダイソー")
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.map(\.id), ["p-daiso-fuji"])
        XCTAssertEqual(rig.search.calls.count, 1, "通信中に消えた駅は検索しない")
    }

    func test保存の失敗はレポートに載り台帳は変わらない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        let store = rig.store
        rig.search.onCall = { _ in store.failing = true }
        let report = await rig.registrar.register(chainName: "ダイソー")
        XCTAssertNotNil(report.ledgerError)
        XCTAssertEqual(report.branchesKept, 0)
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty)
    }

    // MARK: キャンセル

    func test検索の途中でキャンセルされたら次の駅は検索せず何も反映しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido, kamakura]))
        rig.search.set(fujisawa, .success([daisoFujisawa]))
        rig.search.onCall = { _ in withUnsafeCurrentTask { $0?.cancel() } }   // 1 駅目の最中にキャンセルされる
        let registrar = rig.registrar
        let report = await Task { await registrar.register(chainName: "ダイソー") }.value

        XCTAssertEqual(rig.search.calls.count, 1)
        XCTAssertTrue(rig.hours.calls.isEmpty)
        XCTAssertEqual(report.stationFailures["辻堂駅"], "キャンセルされました")
        XCTAssertEqual(report.stationFailures["鎌倉駅"], "キャンセルされました")
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty, "途中までの結果は反映しない")
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"], "名前の登録は残る")
    }

    func test検索がCancellationErrorを投げたら失敗ではなくキャンセル扱い() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido]))
        rig.search.set(fujisawa, .failure(CancellationError()))
        _ = await rig.registrar.register(chainName: "ダイソー")
        XCTAssertEqual(rig.search.calls.count, 1)
    }

    func test開始前にキャンセル済みなら検索しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        let registrar = rig.registrar
        let task = Task { () -> RegistrationReport in
            while !Task.isCancelled { await Task.yield() }
            return await registrar.register(chainName: "ダイソー")
        }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(rig.search.calls.isEmpty)
        XCTAssertEqual(report.stationFailures["藤沢駅"], "キャンセルされました")
        XCTAssertEqual(report.stationsSearched, 0)
    }

    func test営業時間の取得中にキャンセルされたら反映しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        rig.search.set(fujisawa, .success([daisoFujisawa, daisoTsujido]))
        rig.hours.throwsWhenCancelled = true
        rig.hours.onCall = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let registrar = rig.registrar
        let report = await Task { await registrar.register(chainName: "ダイソー") }.value
        XCTAssertEqual(rig.hours.calls.count, 1, "キャンセル後は次の支店を取りに行かない")
        XCTAssertTrue(report.hoursFailures.isEmpty, "キャンセルは営業時間の失敗ではない")
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty)
    }

    // MARK: ensureRegistered

    func test未登録のチェーンだけ登録し登録済みは再取得しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa], registeredChains: ["ダイソー"]))
        let reports = await rig.registrar.ensureRegistered(chains: ["ダイソー", "無印良品", " 無印良品 ", "", "  ", "セリア"])
        XCTAssertEqual(reports.map(\.chainName), ["無印良品", "セリア"])
        XCTAssertEqual(rig.search.calls.map(\.chainName), ["無印良品", "セリア"], "登録済みのダイソーも空・重複も検索しない")
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.registeredChains, ["ダイソー", "無印良品", "セリア"])
    }

    func test登録済み判定は全角半角大小を無視する() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa], registeredChains: ["ＤＡＩＳＯ"]))
        let reports = await rig.registrar.ensureRegistered(chains: ["daiso", "Daiso "])
        XCTAssertTrue(reports.isEmpty)
        XCTAssertTrue(rig.search.calls.isEmpty)
    }

    func test全部登録済みなら何も保存しない() async throws {
        let rig = try await makeRig(Ledger(registeredChains: ["ダイソー"]))
        let before = rig.store.saves
        let reports = await rig.registrar.ensureRegistered(chains: ["ダイソー"])
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(rig.store.saves, before)
    }

    func test登録の途中でキャンセルされたら残りのチェーンは登録しない() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa]))
        rig.search.onCall = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let registrar = rig.registrar
        let reports = await Task { await registrar.ensureRegistered(chains: ["ダイソー", "セリア"]) }.value
        XCTAssertEqual(reports.map(\.chainName), ["ダイソー"])
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
    }

    // MARK: registerStation

    func test駅を足したらその駅だけを登録済みの全チェーンで検索する() async throws {
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido], registeredChains: ["ダイソー", "セリア"]))
        rig.search.set(tsujido, .success([daisoTsujido]))

        let reports = await rig.registrar.registerStation(id: tsujido.id)

        XCTAssertEqual(reports.map(\.chainName), ["ダイソー", "セリア"])
        XCTAssertEqual(rig.search.calls.map(\.center), [tsujido.coordinate, tsujido.coordinate], "藤沢は検索しない")
        XCTAssertEqual(rig.search.calls.map(\.chainName), ["ダイソー", "セリア"])
    }

    func test駅の再実行は他の駅の紐づきに触れず新しい支店を足す() async throws {
        let onFujisawa = Branch(id: "p-daiso-fuji", chainName: "ダイソー", name: "ダイソー 藤沢店", coordinate: daisoFujisawa.coordinate,
                                hours: nightHours, hoursFetchedAt: fixedNow,
                                nearestStations: [StationDistance(stationID: fujisawa.id, meters: 123)], attributes: ["規模": "小型"])
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido], branches: [onFujisawa], registeredChains: ["ダイソー"]))
        // 藤沢の支店は辻堂からも見えた。藤沢側の距離 123 は変えない。
        rig.search.set(tsujido, .success([daisoFujisawa, daisoTsujido]))

        let reports = await rig.registrar.registerStation(id: tsujido.id)

        XCTAssertEqual(reports.count, 1)
        let ledger = await rig.repo.snapshot()
        let fuji = try XCTUnwrap(ledger.branches.first { $0.id == "p-daiso-fuji" })
        XCTAssertEqual(fuji.distance(to: fujisawa.id), 123)
        XCTAssertNotNil(fuji.distance(to: tsujido.id))
        XCTAssertEqual(fuji.attributes, ["規模": "小型"])
        XCTAssertEqual(fuji.hours, nightHours)
        XCTAssertEqual(ledger.branches.first { $0.id == "p-daiso-tsuji" }?.nearestStations.map(\.stationID), [tsujido.id])
        XCTAssertEqual(rig.hours.calls, ["p-daiso-tsuji"], "新しい支店だけ営業時間を取る")
    }

    func test駅の再実行でその駅から消えた支店は他駅に無ければ消える() async throws {
        let onTsujido = Branch(id: "p-gone", chainName: "ダイソー", name: "消える店", coordinate: tsujido.coordinate,
                               nearestStations: [StationDistance(stationID: tsujido.id, meters: 10)])
        let rig = try await makeRig(Ledger(stations: [fujisawa, tsujido], branches: [onTsujido], registeredChains: ["ダイソー"]))
        _ = await rig.registrar.registerStation(id: tsujido.id)
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty)
    }

    func test知らない駅と無効な駅と登録チェーン無しは何もしない() async throws {
        var off = tsujido
        off.isEnabled = false
        let rig = try await makeRig(Ledger(stations: [fujisawa, off], registeredChains: ["ダイソー"]))
        let unknown = await rig.registrar.registerStation(id: UUID())
        let disabled = await rig.registrar.registerStation(id: off.id)
        XCTAssertTrue(unknown.isEmpty)
        XCTAssertTrue(disabled.isEmpty)

        let rig2 = try await makeRig(Ledger(stations: [fujisawa]))
        let none = await rig2.registrar.registerStation(id: fujisawa.id)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(rig.search.calls.isEmpty && rig2.search.calls.isEmpty)
    }
}

// MARK: - 週 1 更新

final class HoursRefresherTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_791_193_320)
    private let oldHours = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1260)])
    private let newHours = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 540, closeDay: 1, closeMinute: 1320)])

    private func branch(_ id: String, chain: String = "ダイソー", fetched: Date?) -> Branch {
        Branch(id: id, chainName: chain, name: "\(chain) \(id)", coordinate: Coordinate(latitude: 35.34, longitude: 139.49),
               hours: oldHours, hoursFetchedAt: fetched,
               nearestStations: [StationDistance(stationID: UUID(), meters: 100)])
    }

    private func task(_ store: String, _ status: TaskStatus = .pending) -> TodoTask {
        TodoTask(store: store, item: "フィルム", status: status, createdAt: now)
    }

    private struct Rig {
        var repo: LedgerRepository
        var store: CountingStore
        var hours: FakeHours
        var refresher: HoursRefresher
    }

    private func makeRig(_ ledger: Ledger) async throws -> Rig {
        let store = CountingStore(ledger)
        let repo = try await LedgerRepository.open(store: store)
        let hours = FakeHours()
        let at = now
        return Rig(repo: repo, store: store, hours: hours,
                   refresher: HoursRefresher(repository: repo, hours: hours, now: { at }))
    }

    func test7日ちょうどは期限内で7日と1秒は期限切れ() async throws {
        let exactly = branch("exact", fetched: now.addingTimeInterval(-7 * day))
        let over = branch("over", fetched: now.addingTimeInterval(-7 * day - 1))
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [exactly, over]))
        rig.hours.set("over", .success(newHours))

        let report = await rig.refresher.refreshStale()

        XCTAssertEqual(rig.hours.calls, ["over"])
        XCTAssertEqual(report, RefreshReport(refreshed: 1, failed: [:], skipped: 1))
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.first { $0.id == "exact" }, exactly)
        let refreshed = try XCTUnwrap(ledger.branches.first { $0.id == "over" })
        XCTAssertEqual(refreshed.hours, newHours)
        XCTAssertEqual(refreshed.hoursFetchedAt, now)
    }

    func test未取得は期限切れ() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("never", fetched: nil)]))
        let due = await rig.refresher.isDue()
        XCTAssertTrue(due)
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 1)
    }

    func test未来の取得日時は期限切れにしない() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("future", fetched: now.addingTimeInterval(3600))]))
        let due = await rig.refresher.isDue()
        XCTAssertFalse(due)
    }

    func test使っていないチェーンと完了だけのチェーンは更新しない() async throws {
        let rig = try await makeRig(Ledger(
            tasks: [task("ダイソー"), task("セリア", .done)],
            branches: [
                branch("daiso", chain: "ダイソー", fetched: nil),
                branch("seria", chain: "セリア", fetched: nil),
                branch("muji", chain: "無印良品", fetched: nil),
            ]
        ))
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(rig.hours.calls, ["daiso"])
        XCTAssertEqual(report, RefreshReport(refreshed: 1, failed: [:], skipped: 2))
    }

    func test無視中のタスクのチェーンは使用中として更新する() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー", .ignored)], branches: [branch("daiso", fetched: nil)]))
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 1)
    }

    func testチェーンの突き合わせは全角半角を無視する() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ＤＡＩＳＯ")], branches: [branch("daiso", chain: "daiso", fetched: nil)]))
        let due = await rig.refresher.isDue()
        XCTAssertTrue(due)
    }

    func test失敗は古い営業時間と取得日時を残しfailedに載せ他は続ける() async throws {
        let oldFetched = now.addingTimeInterval(-8 * day)
        let bad = branch("bad", fetched: oldFetched)
        let good = branch("good", fetched: oldFetched)
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [bad, good]))
        rig.hours.set("bad", .failure(PlacesError.server(503)))
        rig.hours.set("good", .success(newHours))

        let report = await rig.refresher.refreshStale()

        XCTAssertEqual(report.refreshed, 1)
        XCTAssertEqual(report.failed, ["bad": PlacesError.server(503).errorDescription ?? ""])
        XCTAssertEqual(report.skipped, 0)
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.first { $0.id == "bad" }, bad, "失敗した支店は一切変えない")
        XCTAssertEqual(ledger.branches.first { $0.id == "good" }?.hours, newHours)
    }

    func test失敗した支店は次回もまた対象() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("bad", fetched: nil)]))
        rig.hours.set("bad", .failure(Boom()))
        _ = await rig.refresher.refreshStale()
        let due = await rig.refresher.isDue()
        XCTAssertTrue(due)
    }

    func testnilの答えは古い営業時間を残し取得日時だけ進める() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("b", fetched: now.addingTimeInterval(-9 * day))]))
        rig.hours.set("b", .success(nil))
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 1)
        let after = await rig.repo.snapshot()
        let b = try XCTUnwrap(after.branches.first)
        XCTAssertEqual(b.hours, oldHours)
        XCTAssertEqual(b.hoursFetchedAt, now)
        let due = await rig.refresher.isDue()
        XCTAssertFalse(due, "叩き続けない")
    }

    func testisDueは通信せず対象が無ければ偽() async throws {
        let rig = try await makeRig(Ledger(
            tasks: [task("ダイソー")],
            branches: [branch("fresh", fetched: now.addingTimeInterval(-1 * day)), branch("m", chain: "無印良品", fetched: nil)]
        ))
        let due = await rig.refresher.isDue()
        XCTAssertFalse(due, "無印良品は使っていないので数えない")
        XCTAssertTrue(rig.hours.calls.isEmpty)
        let empty = try await makeRig(Ledger())
        let emptyDue = await empty.refresher.isDue()
        XCTAssertFalse(emptyDue)
    }

    func test反映は1回の保存だけ() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [
            branch("a", fetched: nil), branch("b", fetched: nil), branch("c", fetched: nil),
        ]))
        let before = rig.store.saves
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 3)
        XCTAssertEqual(rig.store.saves - before, 1)
    }

    func test対象が無ければ保存しない() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("a", fetched: now)]))
        let before = rig.store.saves
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report, RefreshReport(refreshed: 0, failed: [:], skipped: 1))
        XCTAssertEqual(rig.store.saves, before)
    }

    func test通信中に消えた支店は反映せずskippedに数える() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("gone", fetched: nil), branch("stay", fetched: nil)]))
        let repo = rig.repo
        rig.hours.onCall = { _ in try? await repo.unregisterChain("ダイソー") }   // ダイソーの支店は全部消える
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 0)
        XCTAssertEqual(report.skipped, 2)
        let ledger = await rig.repo.snapshot()
        XCTAssertTrue(ledger.branches.isEmpty, "消えた支店を復活させない")
    }

    func test通信中に入ったタスクの変更は失われない() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("a", fetched: nil)]))
        let repo = rig.repo
        let gate = Gate()
        let entered = Gate()
        rig.hours.onCall = { _ in
            await entered.release()
            await gate.wait()
        }
        let refresher = rig.refresher
        let run = Task { await refresher.refreshStale() }
        await entered.wait()
        _ = try await repo.addTask(store: "セリア", item: "電池", now: now)
        await gate.release()
        _ = await run.value
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.tasks.count, 2)
        XCTAssertEqual(ledger.branches.first?.hoursFetchedAt, now)
    }

    func test保存の失敗は全件failedに載り台帳は変わらない() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("a", fetched: nil)]))
        let store = rig.store
        rig.hours.onCall = { _ in store.failing = true }
        let report = await rig.refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 0)
        XCTAssertEqual(report.failed.keys.sorted(), ["a"])
        let ledger = await rig.repo.snapshot()
        XCTAssertNil(ledger.branches.first?.hoursFetchedAt)
    }

    func test途中でキャンセルされたら取れた分だけ反映し残りは未着手() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [
            branch("a", fetched: nil), branch("b", fetched: nil), branch("c", fetched: nil),
        ]))
        rig.hours.set("a", .success(newHours))
        rig.hours.onCall = { id in
            if id == "a" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let refresher = rig.refresher
        let report = await Task { await refresher.refreshStale() }.value

        XCTAssertEqual(rig.hours.calls, ["a"], "キャンセル後は次を取りに行かない")
        XCTAssertEqual(report, RefreshReport(refreshed: 1, failed: [:], skipped: 2))
        let ledger = await rig.repo.snapshot()
        XCTAssertEqual(ledger.branches.first { $0.id == "a" }?.hours, newHours)
        XCTAssertNil(ledger.branches.first { $0.id == "b" }?.hoursFetchedAt)
    }

    func testキャンセルによるCancellationErrorは失敗に数えない() async throws {
        let rig = try await makeRig(Ledger(tasks: [task("ダイソー")], branches: [branch("a", fetched: nil), branch("b", fetched: nil)]))
        rig.hours.throwsWhenCancelled = true
        rig.hours.onCall = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let refresher = rig.refresher
        let report = await Task { await refresher.refreshStale() }.value
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.refreshed, 0)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(rig.hours.calls.count, 1)
    }
}
