import XCTest
@testable import EkiCore

/// 保存を失敗させられる偽ストア。
private final class FlakyLedgerStore: LedgerStore, @unchecked Sendable {
    struct SaveFailure: Error, Equatable {}
    private let lock = NSLock()
    private var failing = false
    let inner: InMemoryLedgerStore

    init(_ ledger: Ledger = Ledger()) { inner = InMemoryLedgerStore(ledger) }

    var failSaves: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }

    func load() throws -> Ledger { try inner.load() }
    func save(_ ledger: Ledger) throws {
        if failSaves { throw SaveFailure() }
        try inner.save(ledger)
    }
}

final class LedgerRepositoryTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-10-05 09:42:00 UTC = 18:42 JST（月曜）
    private let now = Date(timeIntervalSince1970: 1_791_193_320)

    private func jst(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func makeRepo(_ ledger: Ledger = Ledger()) async throws -> (LedgerRepository, InMemoryLedgerStore) {
        let store = InMemoryLedgerStore(ledger)
        return (try await LedgerRepository.open(store: store), store)
    }

    private func added(_ result: AddTaskResult, file: StaticString = #filePath, line: UInt = #line) throws -> TodoTask {
        guard case .added(let t) = result else {
            XCTFail("expected .added, got \(result)", file: file, line: line)
            throw XCTSkip("not added")
        }
        return t
    }

    // MARK: addTask と重複（D5）

    func testAddTaskTrimsAndStoresDefaults() async throws {
        let (repo, store) = try await makeRepo()
        let task = try added(try await repo.addTask(store: "  ダイソー ", item: "\n フィルム  ", now: now))
        XCTAssertEqual(task.store, "ダイソー")
        XCTAssertEqual(task.item, "フィルム")
        XCTAssertEqual(task.source, TodoTask.manualSource)
        XCTAssertEqual(task.status, .pending)
        XCTAssertEqual(task.createdAt, now)
        XCTAssertNil(task.sourceDate)
        XCTAssertEqual(store.stored.tasks, [task], "保存まで済んでいる")
    }

    func testAddTaskRejectsBlankStoreOrItemWithoutTouchingTheLedger() async throws {
        let (repo, store) = try await makeRepo()
        do { _ = try await repo.addTask(store: "   ", item: "フィルム"); XCTFail() }
        catch { XCTAssertEqual(error as? LedgerError, .emptyField("store")) }
        do { _ = try await repo.addTask(store: "ダイソー", item: "　\t"); XCTFail() }
        catch { XCTAssertEqual(error as? LedgerError, .emptyField("item")) }
        let snapshot = await repo.snapshot()
        XCTAssertEqual(snapshot, Ledger())
        XCTAssertEqual(store.saveCount, 0)
    }

    func testDuplicateIgnoresWidthCaseAndSpaces() async throws {
        let (repo, _) = try await makeRepo()
        let first = try added(try await repo.addTask(store: "ＤＡＩＳＯ", item: "Ｆｉｌｍ  Case", now: now))
        // 店: 全角/半角・大文字小文字。品目: 同上＋連続空白＋前後の空白。
        let dup = try await repo.addTask(store: "daiso", item: "  film case ", now: now)
        XCTAssertEqual(dup, .duplicate(existing: first))
        let kana = try await repo.addTask(store: "セリア", item: "ﾌｨﾙﾑ", now: now)
        _ = try added(kana)
        let kanaDup = try await repo.addTask(store: "セリア", item: "フィルム", now: now)
        XCTAssertEqual(kanaDup, .duplicate(existing: try added(kana)))
        let count = await repo.snapshot().tasks.count
        XCTAssertEqual(count, 2)
    }

    func testDifferentStoreOrDifferentItemIsNotADuplicate() async throws {
        let (repo, _) = try await makeRepo()
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        _ = try added(try await repo.addTask(store: "セリア", item: "フィルム"))
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム 36枚"))
    }

    func testIgnoredTaskCountsAsExistingButDoneDoesNot() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let b = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: false)
        try await repo.complete(taskIDs: [b.id], at: now)

        guard case .duplicate(let existing) = try await repo.addTask(store: "ダイソー", item: "フィルム") else {
            return XCTFail("無視中のタスクは“既にある”")
        }
        XCTAssertEqual(existing.id, a.id)
        let again = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        XCTAssertNotEqual(again.id, b.id, "完了済みは数えない。また買う")
    }

    func testSourceAndSourceDateAreKeptAndBlankSourceFallsBackToManual() async throws {
        let (repo, _) = try await makeRepo()
        let day = CalendarDay(year: 2026, month: 9, day: 14)
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム", source: " LINE:友人 ", sourceDate: day))
        XCTAssertEqual(a.source, "LINE:友人")
        XCTAssertEqual(a.sourceDate, day)
        let b = try added(try await repo.addTask(store: "ダイソー", item: "電池", source: "  "))
        XCTAssertEqual(b.source, TodoTask.manualSource)
    }

    // MARK: 完了・無視・戻す・削除

    func testCompleteSetsDoneAndTimestampAndKeepsFirstCompletionDate() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let b = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        try await repo.complete(taskIDs: [a.id], at: now)
        try await repo.complete(taskIDs: [a.id, UUID()], at: now.addingTimeInterval(3600))
        let tasks = await repo.snapshot().tasks
        XCTAssertEqual(tasks[0].status, .done)
        XCTAssertEqual(tasks[0].completedAt, now, "2 度目の完了で完了日が動かない")
        XCTAssertEqual(tasks[1].id, b.id)
        XCTAssertEqual(tasks[1].status, .pending)
    }

    func testIgnoreUntilTomorrowIsTheNextLocalMidnightInTokyo() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: true, now: jst(2026, 10, 5, 18, 42), timeZone: tokyo)
        let snap1 = await repo.snapshot()
        let t = try XCTUnwrap(snap1.tasks.first)
        XCTAssertEqual(t.status, .ignored)
        XCTAssertEqual(t.ignoredUntil, jst(2026, 10, 6, 0, 0, 0))
        // 境界: 0 時ちょうどで未完了に戻る（>=）。1 秒前はまだ無視。
        XCTAssertFalse(t.isPending(at: jst(2026, 10, 5, 23, 59, 59)))
        XCTAssertTrue(t.isPending(at: jst(2026, 10, 6, 0, 0, 0)))
    }

    func testIgnoreUntilTomorrowAtJustBeforeAndExactlyAtMidnight() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: true, now: jst(2026, 10, 5, 23, 59, 59), timeZone: tokyo)
        let snap2 = await repo.snapshot()
        var until = try XCTUnwrap(snap2.tasks.first?.ignoredUntil)
        XCTAssertEqual(until, jst(2026, 10, 6))
        // 0 時ちょうどに押したら、その日の分は今始まったばかりなので翌日 0 時まで。
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: true, now: jst(2026, 10, 6), timeZone: tokyo)
        let snap3 = await repo.snapshot()
        until = try XCTUnwrap(snap3.tasks.first?.ignoredUntil)
        XCTAssertEqual(until, jst(2026, 10, 7))
    }

    func testIgnoreUsesTheDeviceZoneNotUTC() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        // 2026-10-05 16:00 UTC = 2026-10-06 01:00 JST → 無視は 10-07 0:00 JST まで（UTC の翌 0 時 = JST 9 時ではない）。
        let sixteenUTC = Date(timeIntervalSince1970: 1_791_216_000)
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: true, now: sixteenUTC, timeZone: tokyo)
        let snap4 = await repo.snapshot()
        XCTAssertEqual(snap4.tasks.first?.ignoredUntil, jst(2026, 10, 7))
    }

    func testIgnoreIndefinitelyHasNoUntilAndNeverReturnsOnItsOwn() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: false, now: now, timeZone: tokyo)
        let snap5 = await repo.snapshot()
        let t = try XCTUnwrap(snap5.tasks.first)
        XCTAssertEqual(t.status, .ignored)
        XCTAssertNil(t.ignoredUntil)
        XCTAssertFalse(t.isPending(at: now.addingTimeInterval(365 * 86_400)))
    }

    func testIgnoreDoesNotUndoACompletedTask() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        try await repo.complete(taskIDs: [a.id], at: now)
        try await repo.ignore(taskIDs: [a.id], untilTomorrow: true, now: now, timeZone: tokyo)
        let snap6 = await repo.snapshot()
        let t = try XCTUnwrap(snap6.tasks.first)
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(t.completedAt, now)
        XCTAssertNil(t.ignoredUntil)
    }

    func testReopenClearsCompletionAndIgnoreUntil() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let b = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        try await repo.complete(taskIDs: [a.id], at: now)
        try await repo.ignore(taskIDs: [b.id], untilTomorrow: true, now: now, timeZone: tokyo)
        try await repo.reopen(taskIDs: [a.id, b.id])
        for t in await repo.snapshot().tasks {
            XCTAssertEqual(t.status, .pending)
            XCTAssertNil(t.completedAt)
            XCTAssertNil(t.ignoredUntil)
        }
    }

    func testDeleteRemovesOnlyThoseTasks() async throws {
        let (repo, _) = try await makeRepo()
        let a = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let b = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        try await repo.delete(taskIDs: [a.id, UUID()])
        let snap7 = await repo.snapshot()
        XCTAssertEqual(snap7.tasks.map(\.id), [b.id])
    }

    func testNoOpChangesDoNotSaveOrPublish() async throws {
        let (repo, store) = try await makeRepo()
        try await repo.complete(taskIDs: [UUID()])
        try await repo.delete(taskIDs: [UUID()])
        try await repo.registerChain("ダイソー")
        let saves = store.saveCount
        try await repo.registerChain("ＤＡＩＳＯ")  // ダイソー と別のキーなので追加になる
        try await repo.registerChain("ダイソー")     // 既にある
        XCTAssertEqual(store.saveCount, saves + 1)
    }

    // MARK: 駅

    private func branch(_ id: String, chain: String, stations: [(UUID, Double)]) -> Branch {
        Branch(
            id: id, chainName: chain, name: "\(chain) \(id)",
            coordinate: Coordinate(latitude: 35.34, longitude: 139.49),
            nearestStations: stations.map { StationDistance(stationID: $0.0, meters: $0.1) }
        )
    }

    func testUpsertStationAddsThenReplacesById() async throws {
        let (repo, _) = try await makeRepo()
        var s = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4899))
        try await repo.upsertStation(s)
        s.radiusMeters = 450
        s.isEnabled = false
        try await repo.upsertStation(s)
        let snap8 = await repo.snapshot()
        XCTAssertEqual(snap8.stations, [s])
    }

    func testRemoveStationCascadesToBranchesButKeepsHistoryAndOtherData() async throws {
        let fujisawa = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4899))
        let tsujido = Station(name: "辻堂駅", coordinate: Coordinate(latitude: 35.3337, longitude: 139.4486))
        let both = branch("both", chain: "ダイソー", stations: [(fujisawa.id, 320), (tsujido.id, 480)])
        let onlyFujisawa = branch("fuji", chain: "セリア", stations: [(fujisawa.id, 100)])
        let onlyTsujido = branch("tsuji", chain: "ダイソー", stations: [(tsujido.id, 200)])
        let orphanAlready = branch("none", chain: "無印良品", stations: [])
        let record = NotificationRecord(stationID: fujisawa.id, stationName: "藤沢駅", firedAt: now, result: .suppressedNoBranch)
        let task = TodoTask(store: "セリア", item: "ノート", createdAt: now)
        let (repo, _) = try await makeRepo(Ledger(
            tasks: [task], stations: [fujisawa, tsujido], branches: [both, onlyFujisawa, onlyTsujido, orphanAlready],
            history: [record], registeredChains: ["ダイソー", "セリア"]
        ))

        try await repo.removeStation(id: fujisawa.id)
        let l = await repo.snapshot()
        XCTAssertEqual(l.stations.map(\.id), [tsujido.id])
        XCTAssertEqual(l.branches.map(\.id), ["both", "tsuji", "none"], "藤沢だけの支店は消え、両駅の支店は辻堂だけが残る")
        XCTAssertEqual(l.branches[0].nearestStations, [StationDistance(stationID: tsujido.id, meters: 480)])
        XCTAssertEqual(l.history, [record], "履歴は駅名を持つので残す")
        XCTAssertEqual(l.tasks, [task])
        XCTAssertEqual(l.registeredChains, ["ダイソー", "セリア"])
    }

    // MARK: チェーン・支店

    func testRegisterChainKeepsFirstSpellingAndRejectsBlank() async throws {
        let (repo, _) = try await makeRepo()
        try await repo.registerChain("  ＤＡＩＳＯ ")
        try await repo.registerChain("daiso")
        try await repo.registerChain("DAISO")
        let snap9 = await repo.snapshot()
        XCTAssertEqual(snap9.registeredChains, ["ＤＡＩＳＯ"])
        do { try await repo.registerChain(" "); XCTFail() }
        catch { XCTAssertEqual(error as? LedgerError, .emptyField("chain")) }
    }

    func testUnregisterChainRemovesItsBranchesButNotTasks() async throws {
        let s = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4899))
        let daiso = branch("d1", chain: "ダイソー", stations: [(s.id, 100)])
        let seria = branch("s1", chain: "セリア", stations: [(s.id, 200)])
        let task = TodoTask(store: "ダイソー", item: "フィルム", createdAt: now)
        let (repo, _) = try await makeRepo(Ledger(tasks: [task], stations: [s], branches: [daiso, seria], registeredChains: ["ダイソー", "セリア"]))
        try await repo.unregisterChain(" ダイソー ")
        let l = await repo.snapshot()
        XCTAssertEqual(l.registeredChains, ["セリア"])
        XCTAssertEqual(l.branches.map(\.id), ["s1"])
        XCTAssertEqual(l.tasks, [task])
    }

    func testSetBranchAttributeSetsRemovesAndIgnoresUnknownBranch() async throws {
        let b = branch("d1", chain: "ダイソー", stations: [])
        let (repo, store) = try await makeRepo(Ledger(branches: [b]))
        try await repo.setBranchAttribute(branchID: "d1", key: " 規模 ", value: " 大型 ")
        let snap10 = await repo.snapshot()
        XCTAssertEqual(snap10.branches[0].attributes, ["規模": "大型"])
        try await repo.setBranchAttribute(branchID: "d1", key: "規模", value: nil)
        let snap11 = await repo.snapshot()
        XCTAssertEqual(snap11.branches[0].attributes, [:])
        try await repo.setBranchAttribute(branchID: "d1", key: "規模", value: "小型")
        try await repo.setBranchAttribute(branchID: "d1", key: "規模", value: "   ")
        let snap12 = await repo.snapshot()
        XCTAssertEqual(snap12.branches[0].attributes, [:], "空欄は消す")
        let saves = store.saveCount
        try await repo.setBranchAttribute(branchID: "unknown", key: "規模", value: "大型")
        XCTAssertEqual(store.saveCount, saves)
        do { try await repo.setBranchAttribute(branchID: "d1", key: " ", value: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? LedgerError, .emptyField("key")) }
    }

    // MARK: 履歴・設定

    func testHistoryCapDropsTheOldestRecords() async throws {
        let cap = Tuning.maxHistoryRecords
        let station = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4899))
        func record(_ i: Int) -> NotificationRecord {
            NotificationRecord(stationID: station.id, stationName: station.name, firedAt: now.addingTimeInterval(Double(i)), result: .notified, detail: "r\(i)")
        }
        let (repo, _) = try await makeRepo()
        try await repo.mutate { $0.history = (0..<(cap - 1)).map(record) }
        let snap13 = await repo.snapshot()
        XCTAssertEqual(snap13.history.count, cap - 1)
        for i in (cap - 1)..<(cap + 4) { try await repo.appendHistory(record(i)) }
        let history = await repo.snapshot().history
        XCTAssertEqual(history.count, cap, "ちょうど上限")
        XCTAssertEqual(history.first?.detail, "r4", "先頭の 4 件が落ちた")
        XCTAssertEqual(history.last?.detail, "r\(cap + 3)")
    }

    func testOpeningAnOversizedLedgerTrimsItInMemory() async throws {
        let cap = Tuning.maxHistoryRecords
        let sid = UUID()
        let history = (0..<(cap + 3)).map {
            NotificationRecord(stationID: sid, stationName: "藤沢駅", firedAt: now, result: .notified, detail: "r\($0)")
        }
        let (repo, _) = try await makeRepo(Ledger(history: history))
        let l = await repo.snapshot()
        XCTAssertEqual(l.history.count, cap)
        XCTAssertEqual(l.history.first?.detail, "r3")
    }

    func testUpdateSettings() async throws {
        let (repo, store) = try await makeRepo()
        try await repo.updateSettings { $0.frequency = .everyEntry; $0.diagnosticMode = true }
        let snap14 = await repo.snapshot()
        XCTAssertEqual(snap14.settings, Settings(frequency: .everyEntry, checkBusinessHours: true, diagnosticMode: true))
        XCTAssertEqual(store.stored.settings.frequency, .everyEntry)
    }

    // MARK: mutate の約束

    func testMutateReturnsBodyResultAndSavesBeforePublishing() async throws {
        let (repo, store) = try await makeRepo()
        let count: Int = try await repo.mutate { l in
            l.registeredChains.append("ダイソー")
            return l.registeredChains.count
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.stored.registeredChains, ["ダイソー"])
    }

    func testMutateBodyThatThrowsLeavesStateAndDiskUnchanged() async throws {
        struct Boom: Error {}
        let (repo, store) = try await makeRepo()
        do {
            try await repo.mutate { l in
                l.registeredChains.append("途中まで")
                throw Boom()
            }
            XCTFail()
        } catch { XCTAssertTrue(error is Boom) }
        let snap15 = await repo.snapshot()
        XCTAssertEqual(snap15, Ledger())
        XCTAssertEqual(store.saveCount, 0)
    }

    func testSaveFailureThrowsRollsBackAndDoesNotPublish() async throws {
        let flaky = FlakyLedgerStore()
        let repo = try await LedgerRepository.open(store: flaky)
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))

        let stream = await repo.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.tasks.count, 1)

        flaky.failSaves = true
        do {
            _ = try await repo.addTask(store: "ダイソー", item: "失敗する品目")
            XCTFail("保存の失敗は必ず投げる")
        } catch { XCTAssertEqual(error as? FlakyLedgerStore.SaveFailure, FlakyLedgerStore.SaveFailure()) }
        let afterFailure = await repo.snapshot()
        XCTAssertEqual(afterFailure.tasks.map(\.item), ["フィルム"], "メモリは元のまま")
        XCTAssertEqual(flaky.inner.stored.tasks.map(\.item), ["フィルム"], "ディスクも元のまま")

        flaky.failSaves = false
        _ = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        let next = await iterator.next()
        XCTAssertEqual(next?.tasks.map(\.item), ["フィルム", "電池"], "失敗した変更は購読者に流れていない")
    }

    func testEveryConvenienceSurfacesSaveFailure() async throws {
        let flaky = FlakyLedgerStore()
        let repo = try await LedgerRepository.open(store: flaky)
        let t = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let d = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        try await repo.complete(taskIDs: [d.id], at: now)
        flaky.failSaves = true
        let station = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4899))
        let record = NotificationRecord(stationID: station.id, stationName: "藤沢駅", firedAt: now, result: .notified)
        func expectFailure(_ label: String, _ op: () async throws -> Void) async {
            do { try await op(); XCTFail("\(label) swallowed the failure") }
            catch { XCTAssertTrue(error is FlakyLedgerStore.SaveFailure, label) }
        }
        await expectFailure("complete") { try await repo.complete(taskIDs: [t.id]) }
        await expectFailure("ignore") { try await repo.ignore(taskIDs: [t.id], untilTomorrow: true, now: self.now, timeZone: self.tokyo) }
        await expectFailure("reopen") { try await repo.reopen(taskIDs: [d.id]) }
        await expectFailure("delete") { try await repo.delete(taskIDs: [t.id]) }
        await expectFailure("upsertStation") { try await repo.upsertStation(station) }
        await expectFailure("registerChain") { try await repo.registerChain("セリア") }
        await expectFailure("appendHistory") { try await repo.appendHistory(record) }
        await expectFailure("updateSettings") { try await repo.updateSettings { $0.diagnosticMode = true } }
        await expectFailure("importItems") { _ = try await repo.importItems([InflowItem(store: "セリア", item: "ノート", source: "x")]) }
        let snapshot = await repo.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.status), [.pending, .done])
        XCTAssertTrue(snapshot.stations.isEmpty && snapshot.history.isEmpty && snapshot.registeredChains.isEmpty)
    }

    func testTwoHundredConcurrentAddsLoseNothing() async throws {
        let (repo, store) = try await makeRepo()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    _ = try? await repo.addTask(store: "ダイソー", item: "品目\(i)", now: Date(timeIntervalSince1970: 1_791_193_320))
                }
            }
        }
        let tasks = await repo.snapshot().tasks
        XCTAssertEqual(tasks.count, 200)
        XCTAssertEqual(Set(tasks.map(\.item)).count, 200)
        XCTAssertEqual(store.stored.tasks.count, 200, "保存側も同じ")
    }

    func testConcurrentIdenticalAddsYieldExactlyOneTask() async throws {
        let (repo, _) = try await makeRepo()
        let results = await withTaskGroup(of: AddTaskResult?.self, returning: [AddTaskResult].self) { group in
            for _ in 0..<50 {
                group.addTask { try? await repo.addTask(store: "ダイソー", item: "フィルム") }
            }
            var all: [AddTaskResult] = []
            for await r in group { if let r { all.append(r) } }
            return all
        }
        XCTAssertEqual(results.count, 50)
        XCTAssertEqual(results.filter { if case .added = $0 { return true } else { return false } }.count, 1)
        let snap16 = await repo.snapshot()
        XCTAssertEqual(snap16.tasks.count, 1)
    }

    func testConcurrentAddsThroughTheRealFileStoreSurviveAReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-repo-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json")
        let repo = try await LedgerRepository.open(store: JSONFileLedgerStore(url: url))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { _ = try? await repo.addTask(store: "ダイソー", item: "品目\(i)", now: Date(timeIntervalSince1970: 1_791_193_320)) }
            }
        }
        let reloaded = try JSONFileLedgerStore(url: url).load()
        XCTAssertEqual(reloaded.tasks.count, 40)
        let snap17 = await repo.snapshot()
        XCTAssertEqual(reloaded, snap17)
    }

    // MARK: updates()

    func testUpdatesYieldsTheCurrentSnapshotThenEveryChange() async throws {
        let (repo, _) = try await makeRepo()
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let stream = await repo.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.tasks.map(\.item), ["フィルム"], "購読直後に今の状態")
        _ = try added(try await repo.addTask(store: "ダイソー", item: "電池"))
        let second = await iterator.next()
        XCTAssertEqual(second?.tasks.map(\.item), ["フィルム", "電池"])
        try await repo.registerChain("ダイソー")
        let third = await iterator.next()
        XCTAssertEqual(third?.registeredChains, ["ダイソー"])
    }

    func testUpdatesSupportsMultipleSubscribers() async throws {
        let (repo, _) = try await makeRepo()
        let s1 = await repo.updates()
        let s2 = await repo.updates()
        var i1 = s1.makeAsyncIterator()
        var i2 = s2.makeAsyncIterator()
        _ = await i1.next()
        _ = await i2.next()
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let a = await i1.next()
        let b = await i2.next()
        XCTAssertEqual(a?.tasks.count, 1)
        XCTAssertEqual(b?.tasks.count, 1)
        let n = await repo.subscriberCount
        XCTAssertEqual(n, 2)
    }

    private func waitForSubscriberCount(_ expected: Int, in repo: LedgerRepository, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await repo.subscriberCount == expected { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await repo.subscriberCount
        XCTFail("subscriberCount is \(actual), expected \(expected)", file: file, line: line)
    }

    func testCancelledConsumerIsUnsubscribed() async throws {
        let (repo, _) = try await makeRepo()
        let stream = await repo.updates()
        let consumer = Task { () -> Int in
            var seen = 0
            for await _ in stream { seen += 1 }
            return seen
        }
        await waitForSubscriberCount(1, in: repo)
        consumer.cancel()
        _ = await consumer.value
        await waitForSubscriberCount(0, in: repo)
    }

    func testDroppedStreamIsUnsubscribed() async throws {
        let (repo, _) = try await makeRepo()
        do {
            let stream = await repo.updates()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            let during = await repo.subscriberCount
            XCTAssertEqual(during, 1)
        }
        await waitForSubscriberCount(0, in: repo)
        // 外れたあとの変更でクラッシュも蓄積もしない。
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
    }

    func testSlowSubscriberOnlyKeepsTheNewestSnapshot() async throws {
        let (repo, _) = try await makeRepo()
        let stream = await repo.updates()   // 初期スナップショットが溜まる
        for i in 0..<5 { _ = try added(try await repo.addTask(store: "ダイソー", item: "品目\(i)")) }
        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest?.tasks.count, 5)
    }

    // MARK: 取込（D5）

    func testImportItemsAppliesTheDuplicateRuleIncludingWithinOneBatch() async throws {
        let (repo, _) = try await makeRepo()
        let existing = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let done = try added(try await repo.addTask(store: "セリア", item: "ノート"))
        try await repo.complete(taskIDs: [done.id], at: now)
        let ignored = try added(try await repo.addTask(store: "無印良品", item: "ファイルボックス"))
        try await repo.ignore(taskIDs: [ignored.id], untilTomorrow: false)

        let day = CalendarDay(year: 2026, month: 9, day: 14)
        let summary = try await repo.importItems([
            InflowItem(store: "ＤＡＩＳＯ", item: "x", source: "LINE:友人", date: day),   // 新規（店の綴りだけ別）
            InflowItem(store: "ダイソー", item: " ﾌｨﾙﾑ ", source: "LINE:友人"),            // 重複: 半角カナ
            InflowItem(store: "セリア", item: "ノート", source: "Notion:HQ"),              // 完了済みなので追加
            InflowItem(store: "無印良品", item: "ファイルボックス", source: "Notion:HQ"),  // 無視中は重複
            InflowItem(store: "daiso", item: "X", source: "LINE:友人"),                   // バッチ内の重複
            InflowItem(store: "セリア", item: "ノート", source: "Notion:HQ"),              // バッチ内の重複
            InflowItem(store: " ", item: "空の店", source: "x"),                          // 不正
            InflowItem(store: "セリア", item: "", source: "x"),                           // 不正
        ], now: now)

        XCTAssertEqual(summary.added.map(\.item), ["x", "ノート"])
        XCTAssertEqual(summary.added[0].sourceDate, day)
        XCTAssertEqual(summary.added[0].source, "LINE:友人")
        XCTAssertEqual(summary.added[0].createdAt, now)
        XCTAssertEqual(summary.duplicates, 4)
        XCTAssertEqual(summary.invalid, 2)
        XCTAssertEqual(summary.chainsNeedingRegistration, ["ＤＡＩＳＯ", "ダイソー", "セリア", "無印良品"], "重複行のチェーンも含む。同じキーは初出の表記で 1 つ")
        let l = await repo.snapshot()
        XCTAssertEqual(l.tasks.count, 5)
        XCTAssertEqual(l.tasks.first?.id, existing.id)
    }

    func testImportReportsUnregisteredChainsOncePerChainInFirstSeenSpelling() async throws {
        let (repo, store) = try await makeRepo(Ledger(registeredChains: ["ダイソー"]))
        let summary = try await repo.importItems([
            InflowItem(store: "ダイソー", item: "a", source: "s"),
            InflowItem(store: "セリア", item: "b", source: "s"),
            InflowItem(store: "ＳＥＲＩＡ", item: "c", source: "s"),
            InflowItem(store: "seria", item: "d", source: "s"),
            InflowItem(store: " 無印良品 ", item: "e", source: "s"),
        ], now: now)
        XCTAssertEqual(summary.chainsNeedingRegistration, ["セリア", "ＳＥＲＩＡ", "無印良品"])
        XCTAssertEqual(store.stored.registeredChains, ["ダイソー"], "取込は名前の登録まではしない（Places の取得が要る）")
    }

    func testImportOfOnlyDuplicatesDoesNotSave() async throws {
        let (repo, store) = try await makeRepo()
        _ = try added(try await repo.addTask(store: "ダイソー", item: "フィルム"))
        let saves = store.saveCount
        let summary = try await repo.importItems([InflowItem(store: "ダイソー", item: "フィルム", source: "x")])
        XCTAssertTrue(summary.added.isEmpty)
        XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(store.saveCount, saves)
    }
}
