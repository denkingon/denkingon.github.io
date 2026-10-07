import XCTest
@testable import EkiCore

// 店画面の「再取得」（register(chainName:refetchHours: true)）が既存の支店の営業時間も取り直す、という規則を固定する。

private final class RfSearch: StoreSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Double: [BranchCandidate]] = [:]
    func set(_ s: Station, _ c: [BranchCandidate]) { lock.withLock { answers[s.coordinate.latitude] = c } }
    func searchBranches(chainName: String, near center: Coordinate, radiusMeters: Double) async throws -> [BranchCandidate] {
        lock.withLock { answers[center.latitude] ?? [] }
    }
}

private final class RfHours: BusinessHoursProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<OpeningHours?, Error>] = [:]
    private var _calls: [String] = []
    /// 呼び出しの最中に走らせたい処理（途中でキャンセルする等）。
    var onCall: (@Sendable (String) -> Void)?
    var calls: [String] { lock.withLock { _calls } }
    func set(_ id: String, _ r: Result<OpeningHours?, Error>) { lock.withLock { answers[id] = r } }
    func openingHours(placeID: String) async throws -> OpeningHours? {
        let a: Result<OpeningHours?, Error>? = lock.withLock { _calls.append(placeID); return answers[placeID] }
        onCall?(placeID)
        try Task.checkCancellation()
        switch a {
        case .some(.success(let h)): return h
        case .some(.failure(let e)): throw e
        case .none: return nil
        }
    }
}

private struct RfBoom: LocalizedError { var errorDescription: String? { "通信失敗" } }

final class RefetchHoursTests: XCTestCase {
    private let day: TimeInterval = 86_400
    // 2026-10-05 09:42:00 UTC
    private let now = Date(timeIntervalSince1970: 1_791_193_320)
    private let oldHours = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1260)])
    private let newHours = OpeningHours(weekly: [WeeklyPeriod(openDay: 1, openMinute: 540, closeDay: 1, closeMinute: 1320)])
    private let fuji = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4896))

    private var oldFetched: Date { now.addingTimeInterval(-30 * day) }

    private func existing(_ id: String, chain: String = "ダイソー", name: String? = nil) -> Branch {
        Branch(
            id: id, chainName: chain, name: name ?? "\(chain) \(id)",
            coordinate: Coordinate(latitude: 35.3405, longitude: 139.4880),
            hours: oldHours, hoursFetchedAt: oldFetched,
            nearestStations: [StationDistance(stationID: fuji.id, meters: 200)],
            attributes: ["規模": "大型"]
        )
    }

    private func cand(_ b: Branch) -> BranchCandidate {
        BranchCandidate(placeID: b.id, name: b.name, coordinate: b.coordinate)
    }

    private struct Rig {
        var repo: LedgerRepository
        var search: RfSearch
        var hours: RfHours
        var registrar: ChainRegistrar
    }

    private func makeRig(branches: [Branch], search: [BranchCandidate]) async throws -> Rig {
        let ledger = Ledger(stations: [fuji], branches: branches, registeredChains: ["ダイソー"])
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(ledger))
        let s = RfSearch()
        s.set(fuji, search)
        let h = RfHours()
        let at = now
        return Rig(repo: repo, search: s, hours: h, registrar: ChainRegistrar(repository: repo, search: s, hours: h, now: { at }))
    }

    func test既定では既存の支店の営業時間を取り直さない() async throws {
        let b = existing("p1")
        let rig = try await makeRig(branches: [b], search: [cand(b)])
        rig.hours.set("p1", .success(newHours))
        _ = await rig.registrar.register(chainName: "ダイソー")
        XCTAssertTrue(rig.hours.calls.isEmpty)
        let after = await rig.repo.snapshot()
        XCTAssertEqual(after.branches.first?.hours, oldHours)
        XCTAssertEqual(after.branches.first?.hoursFetchedAt, oldFetched)
    }

    func test成功したら営業時間と取得日時を更新し属性は保つ() async throws {
        let b = existing("p1")
        let rig = try await makeRig(branches: [b], search: [cand(b)])
        rig.hours.set("p1", .success(newHours))

        let report = await rig.registrar.register(chainName: "ダイソー", refetchHours: true)

        XCTAssertEqual(rig.hours.calls, ["p1"])
        let snap = await rig.repo.snapshot()
        let after = try XCTUnwrap(snap.branches.first)
        XCTAssertEqual(after.hours, newHours)
        XCTAssertEqual(after.hoursFetchedAt, now)
        XCTAssertEqual(after.attributes, ["規模": "大型"])
        XCTAssertTrue(report.hoursFailures.isEmpty)
        XCTAssertEqual(report.branchesKept, 1)
    }

    func testnilの答えは古い営業時間を残し取得日時だけ進める() async throws {
        let b = existing("p1")
        let rig = try await makeRig(branches: [b], search: [cand(b)])
        rig.hours.set("p1", .success(nil))

        let report = await rig.registrar.register(chainName: "ダイソー", refetchHours: true)

        let snap = await rig.repo.snapshot()
        let after = try XCTUnwrap(snap.branches.first)
        XCTAssertEqual(after.hours, oldHours, "HoursRefresher と同じ: 「営業時間なし」の答えで古い営業時間を消さない")
        XCTAssertEqual(after.hoursFetchedAt, now)
        XCTAssertTrue(report.hoursFailures.isEmpty)
    }

    func test失敗したら古い営業時間も取得日時も残しhoursFailuresに載せる() async throws {
        let ok = existing("p-ok")
        let bad = existing("p-bad", name: "ダイソー 失敗店")
        let rig = try await makeRig(branches: [ok, bad], search: [cand(ok), cand(bad)])
        rig.hours.set("p-ok", .success(newHours))
        rig.hours.set("p-bad", .failure(RfBoom()))

        let report = await rig.registrar.register(chainName: "ダイソー", refetchHours: true)

        let after = await rig.repo.snapshot()
        let byID = Dictionary(uniqueKeysWithValues: after.branches.map { ($0.id, $0) })
        XCTAssertEqual(byID["p-ok"]?.hours, newHours, "1 件の失敗で他の支店を巻き込まない")
        XCTAssertEqual(byID["p-bad"]?.hours, oldHours)
        XCTAssertEqual(byID["p-bad"]?.hoursFetchedAt, oldFetched, "取得日時を進めない = 次回の週 1 更新で再試行される")
        XCTAssertEqual(report.hoursFailures, ["ダイソー 失敗店"])
    }

    func test新しい支店と既存の支店が混ざっても両方取る() async throws {
        let old = existing("p-old")
        let fresh = BranchCandidate(placeID: "p-new", name: "ダイソー 新店", coordinate: Coordinate(latitude: 35.3390, longitude: 139.4900))
        let bad = BranchCandidate(placeID: "p-new-bad", name: "ダイソー 新失敗店", coordinate: Coordinate(latitude: 35.3391, longitude: 139.4901))
        let rig = try await makeRig(branches: [old], search: [cand(old), fresh, bad])
        rig.hours.set("p-old", .success(newHours))
        rig.hours.set("p-new", .success(newHours))
        rig.hours.set("p-new-bad", .failure(RfBoom()))

        let report = await rig.registrar.register(chainName: "ダイソー", refetchHours: true)

        XCTAssertEqual(Set(rig.hours.calls), ["p-old", "p-new", "p-new-bad"])
        let after = await rig.repo.snapshot()
        let byID = Dictionary(uniqueKeysWithValues: after.branches.map { ($0.id, $0) })
        XCTAssertEqual(byID["p-old"]?.hours, newHours)
        XCTAssertEqual(byID["p-old"]?.hoursFetchedAt, now)
        XCTAssertEqual(byID["p-new"]?.hours, newHours)
        XCTAssertEqual(byID["p-new"]?.hoursFetchedAt, now)
        XCTAssertNil(byID["p-new-bad"]?.hours)
        XCTAssertNil(byID["p-new-bad"]?.hoursFetchedAt, "新しい支店の失敗は未取得のまま（今までどおり）")
        XCTAssertEqual(report.hoursFailures, ["ダイソー 新失敗店"])
    }

    func test検索に返らなかった支店は取り直さず消える() async throws {
        let gone = existing("p-gone")
        let stay = existing("p-stay")
        let rig = try await makeRig(branches: [gone, stay], search: [cand(stay)])
        rig.hours.set("p-stay", .success(newHours))
        _ = await rig.registrar.register(chainName: "ダイソー", refetchHours: true)
        XCTAssertEqual(rig.hours.calls, ["p-stay"])
        let after = await rig.repo.snapshot()
        XCTAssertEqual(after.branches.map(\.id), ["p-stay"])
    }

    func test別チェーンとして既にあるplaceIDは取り直さない() async throws {
        let other = existing("p-shared", chain: "セリア")
        let rig = try await makeRig(
            branches: [other],
            search: [BranchCandidate(placeID: "p-shared", name: "ダイソー 共有店", coordinate: other.coordinate)]
        )
        rig.hours.set("p-shared", .success(newHours))
        _ = await rig.registrar.register(chainName: "ダイソー", refetchHours: true)
        XCTAssertTrue(rig.hours.calls.isEmpty)
        let after = await rig.repo.snapshot()
        XCTAssertEqual(after.branches, [other])
    }

    func test駅を足したときの再実行は取り直さない() async throws {
        let b = existing("p1")
        let rig = try await makeRig(branches: [b], search: [cand(b)])
        _ = await rig.registrar.registerStation(id: fuji.id)
        XCTAssertTrue(rig.hours.calls.isEmpty)
    }

    func test取り直しの途中でキャンセルされたら何も反映しない() async throws {
        let a = existing("p-a")
        let b = existing("p-b")
        let rig = try await makeRig(branches: [a, b], search: [cand(a), cand(b)])
        rig.hours.set("p-a", .success(newHours))
        rig.hours.set("p-b", .success(newHours))
        rig.hours.onCall = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let registrar = rig.registrar

        let report = await Task { await registrar.register(chainName: "ダイソー", refetchHours: true) }.value

        XCTAssertEqual(rig.hours.calls.count, 1, "キャンセル後は次の支店を取りに行かない")
        XCTAssertTrue(report.hoursFailures.isEmpty, "キャンセルは営業時間の失敗ではない")
        let after = await rig.repo.snapshot()
        XCTAssertEqual(after.branches, [a, b], "途中までの結果は反映しない")
    }
}
