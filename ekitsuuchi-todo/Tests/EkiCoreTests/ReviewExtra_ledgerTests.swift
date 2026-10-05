import XCTest
@testable import EkiCore

/// 独立レビュー（ledger モジュール）で足した、壊しにいくテスト。
final class ReviewExtra_ledgerTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let now = Date(timeIntervalSince1970: 1_791_193_320)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func parse(_ json: String) throws -> ImportParseResult {
        try TaskImporter.parse(Data(json.utf8))
    }

    // MARK: 取込

    /// "+026" のような符号付き・桁の崩れた日付を Int() が通してしまうと、出典日が黙って別の日になる。
    func testImporterRejectsSignedOrOddDateComponents() throws {
        for bad in ["+026-09-14", "2026-+9-14", "2026-09-+4", "2026-9 -14", "2026-09-14 ", " 2026-09-14", "２０２６-09-14"] {
            let r = try parse(#"{"version":1,"items":[{"store":"a","item":"b","date":"\#(bad)"}]}"#)
            XCTAssertTrue(r.items.isEmpty, "date \(bad) は拒否される")
            XCTAssertEqual(r.rejected.count, 1, "date \(bad)")
        }
        let ok = try parse(#"{"version":1,"items":[{"store":"a","item":"b","date":"2026-02-28"},{"store":"a","item":"c","date":"2028-02-29"},{"store":"a","item":"d","date":"2026-02-29"}]}"#)
        XCTAssertEqual(ok.items.count, 2)
        XCTAssertEqual(ok.rejected.map(\.index), [2])
    }

    func testImporterDuplicateKeysDoNotCrashOrFailTheFile() throws {
        let r = try parse(#"{"version":1,"version":1,"items":[{"store":"a","store":"z","item":"b"}]}"#)
        XCTAssertEqual(r.items.count, 1)
    }

    /// 取り込む行と無関係な余計なキーが大きすぎる数でも、ファイル全体を失敗させない。
    func testImporterIgnoresHugeNumbersInUnknownKeys() throws {
        let r = try parse(#"{"version":1,"items":[{"store":"a","item":"b","qty":1e999},{"store":"c","item":"d"}]}"#)
        XCTAssertEqual(r.items.count, 2)
    }

    func testImporterTopLevelShapes() {
        for json in ["[]", "5", "\"x\"", "null", "", "   ", "{"] {
            XCTAssertThrowsError(try parse(json), json) { XCTAssertEqual($0 as? ImportError, .notJSON, json) }
        }
        XCTAssertThrowsError(try parse(#"{"version":2,"items":[]}"#)) {
            XCTAssertEqual($0 as? ImportError, .unsupportedVersion("2"))
        }
        XCTAssertThrowsError(try parse(#"{"version":1.5,"items":[]}"#))
        XCTAssertThrowsError(try parse(#"{"version":true,"items":[]}"#))
        XCTAssertThrowsError(try parse(#"{"version":1,"items":null}"#)) { XCTAssertEqual($0 as? ImportError, .itemsNotArray) }
    }

    func testImporterFullWidthSpaceOnlyIsBlank() throws {
        let r = try parse(#"{"version":1,"items":[{"store":"　","item":"x"},{"store":"a","item":" 　 "}]}"#)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.rejected.count, 2)
    }

    func testImporterBoolAndNumberAreNotStrings() throws {
        let r = try parse(#"{"version":1,"items":[{"store":true,"item":"x"},{"store":"a","item":1},{"store":"a","item":"b","source":1},{"store":"a","item":"b","date":20260914}]}"#)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.rejected.count, 4)
    }

    // MARK: 日時コーディング

    func testDateCodingRoundTripsManyMillisecondValues() {
        var x: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<20_000 {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            let ms = Int64(bitPattern: x >> 11) % 250_000_000_000_000 - 60_000_000_000_000   // およそ 1968..9000年台
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)
            let s = LedgerDateCoding.string(from: date)
            XCTAssertEqual(LedgerDateCoding.date(from: s), date, s)
        }
    }

    func testDateCodingRoundsHalfMillisecondCarryAcrossSecondsAndYears() {
        let d = Date(timeIntervalSince1970: 1_798_761_599.9996) // 2026-12-31T23:59:59.9996Z
        XCTAssertEqual(LedgerDateCoding.string(from: d), "2027-01-01T00:00:00.000Z")
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: -0.0004)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: -0.0006)), "1969-12-31T23:59:59.999Z")
    }

    func testDateCodingExtremesAndNonFiniteDoNotCrash() {
        _ = LedgerDateCoding.string(from: .distantPast)
        _ = LedgerDateCoding.string(from: .distantFuture)
        _ = LedgerDateCoding.string(from: Date(timeIntervalSince1970: .nan))
        _ = LedgerDateCoding.string(from: Date(timeIntervalSince1970: .infinity))
        XCTAssertNotNil(LedgerDateCoding.date(from: LedgerDateCoding.string(from: .distantFuture)))
    }

    func testDateCodingRejectsImpossibleFields() {
        for bad in ["2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-05T24:00:00Z", "2026-10-05T00:60:00Z",
                    "2026-10-05T00:00:00", "2026-10-05T00:00:00.Z", "2026-10-05T00:00:00Zjunk", "2026-10-05T00:00:00+24:00",
                    "2025-02-29T00:00:00Z", "2026-00-10T00:00:00Z", "2026-10-00T00:00:00Z", ""] {
            XCTAssertNil(LedgerDateCoding.date(from: bad), bad)
        }
        XCTAssertNotNil(LedgerDateCoding.date(from: "2028-02-29T00:00:00Z"))
        XCTAssertEqual(LedgerDateCoding.date(from: "2026-10-05T18:42:00+09:00"), LedgerDateCoding.date(from: "2026-10-05T09:42:00Z"))
        XCTAssertEqual(LedgerDateCoding.date(from: "2026-10-05T09:42:00.1239Z"), Date(timeIntervalSince1970: 1_791_193_320.123))
    }

    // MARK: ファイルストア

    func testDirectoryWhereTheFileShouldBeIsRethrownNotQuarantined() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = JSONFileLedgerStore(url: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertNil(error as? LedgerStoreError, "壊れた台帳ではないのでバックアップ扱いにしない: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewerSchemaWithUnreadableBodyIsStillNewerSchemaAndUntouched() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        let body = #"{"schemaVersion": 7, "tasks": "future shape", "weird": [1,2,3]}"#
        try Data(body.utf8).write(to: url)
        let store = JSONFileLedgerStore(url: url)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? LedgerStoreError, .newerSchema(found: 7, supported: Ledger.currentSchemaVersion))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data(body.utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["ledger.json"])
    }

    func testSavingNaNCoordinateThrowsAndNeverLeavesAPartialFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        let store = JSONFileLedgerStore(url: url)
        try store.save(Ledger())
        let before = try Data(contentsOf: url)
        var l = Ledger()
        l.stations = [Station(name: "x", coordinate: Coordinate(latitude: .nan, longitude: 0))]
        XCTAssertThrowsError(try store.save(l))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["ledger.json"])
    }

    func testJapaneseAndEmojiTextSurvivesTheFile() throws {
        let dir = try makeTempDir()
        let store = JSONFileLedgerStore(url: dir.appendingPathComponent("l.json"))
        var l = Ledger()
        l.tasks = [TodoTask(store: "ダイソー", item: "𠮷野家 🧴 \"quote\" \\ / \n改行", createdAt: now)]
        l.registeredChains = ["ｾﾘｱ"]
        try store.save(l)
        XCTAssertEqual(try store.load(), l)
    }

    // MARK: リポジトリ

    func testHistoryCapBoundaryExactlyAtCapKeepsEverything() async throws {
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore())
        let sid = UUID()
        let cap = Tuning.maxHistoryRecords
        let recs = (0..<cap).map {
            NotificationRecord(stationID: sid, stationName: "s", firedAt: Date(timeIntervalSince1970: Double($0)), result: .notified)
        }
        try await repo.mutate { $0.history = recs }
        let atCap = await repo.snapshot().history
        XCTAssertEqual(atCap.count, cap)
        let extra = NotificationRecord(stationID: sid, stationName: "s", firedAt: Date(timeIntervalSince1970: Double(cap)), result: .notified)
        try await repo.appendHistory(extra)
        let after = await repo.snapshot().history
        XCTAssertEqual(after.count, cap)
        XCTAssertEqual(after.first?.id, recs[1].id)
        XCTAssertEqual(after.last?.id, extra.id)
    }

    func testDedupeTreatsDecomposedKanaAndHalfWidthKatakanaAsEqual() async throws {
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore())
        _ = try await repo.addTask(store: "ダイソー", item: "ガムテープ")
        // か + 結合濁点、半角カナ
        let r1 = try await repo.addTask(store: "ﾀﾞｲｿｰ", item: "か\u{3099}むてーぷ".replacingOccurrences(of: "か\u{3099}むてーぷ", with: "カ\u{3099}ムテープ"))
        guard case .duplicate = r1 else { return XCTFail("\(r1)") }
        let r2 = try await repo.addTask(store: "ダイソー", item: "ｶﾞﾑﾃｰﾌﾟ")
        guard case .duplicate = r2 else { return XCTFail("\(r2)") }
    }

    func testIgnoreUntilTomorrowAcrossDSTChangeInNewYork() async throws {
        let ny = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ny
        // 2026-03-08 は NY が夏時間に入る日（その日は 23 時間）。
        let pressed = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1))!
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore())
        guard case .added(let t) = try await repo.addTask(store: "a", item: "b", now: pressed) else { return XCTFail() }
        try await repo.ignore(taskIDs: [t.id], untilTomorrow: true, now: pressed, timeZone: ny)
        let until = await repo.snapshot().tasks[0].ignoredUntil
        XCTAssertEqual(until, cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0)))
        XCTAssertEqual(until!.timeIntervalSince(pressed), 22 * 3600, "1:00 EST → 翌 0:00 EDT は 22 時間（その日は 23 時間）")
    }

    func testIgnoreOneMillisecondBeforeMidnightReturnsAtMidnight() async throws {
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore())
        guard case .added(let t) = try await repo.addTask(store: "a", item: "b") else { return XCTFail() }
        let jst = { (d: Int, h: Int, m: Int, s: Int) -> Date in
            var cal = Calendar(identifier: .gregorian); cal.timeZone = self.tokyo
            return cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m, second: s))!
        }
        let pressed = jst(5, 23, 59, 59).addingTimeInterval(0.999)
        try await repo.ignore(taskIDs: [t.id], untilTomorrow: true, now: pressed, timeZone: tokyo)
        let task = await repo.snapshot().tasks[0]
        XCTAssertEqual(task.ignoredUntil, jst(6, 0, 0, 0))
        XCTAssertFalse(task.isPending(at: jst(5, 23, 59, 59).addingTimeInterval(0.9995)))
        XCTAssertTrue(task.isPending(at: jst(6, 0, 0, 0)))
    }

    func testRemoveStationKeepsBranchStillNearAnotherStation() async throws {
        let s1 = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.33, longitude: 139.48))
        let s2 = Station(name: "辻堂駅", coordinate: Coordinate(latitude: 35.33, longitude: 139.45))
        let shared = Branch(id: "p1", chainName: "ダイソー", name: "x", coordinate: s1.coordinate,
                            nearestStations: [StationDistance(stationID: s1.id, meters: 100), StationDistance(stationID: s2.id, meters: 400)])
        let only = Branch(id: "p2", chainName: "ダイソー", name: "y", coordinate: s1.coordinate,
                          nearestStations: [StationDistance(stationID: s1.id, meters: 100)])
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(stations: [s1, s2], branches: [shared, only])))
        try await repo.removeStation(id: s1.id)
        let l = await repo.snapshot()
        XCTAssertEqual(l.branches.map(\.id), ["p1"])
        XCTAssertEqual(l.branches[0].nearestStations.map(\.stationID), [s2.id])
        XCTAssertEqual(l.stations.map(\.id), [s2.id])
    }

    func testBlankKeyThrowsEvenForUnknownBranchAndNothingChanges() async throws {
        let store = InMemoryLedgerStore()
        let repo = try await LedgerRepository.open(store: store)
        do {
            try await repo.setBranchAttribute(branchID: "nope", key: "  ", value: "x")
            XCTFail("throws")
        } catch {
            XCTAssertEqual(error as? LedgerError, .emptyField("key"))
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testUpdatesAreMonotonicAndEndWithTheFinalSnapshotUnderConcurrentWrites() async throws {
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore())
        let stream = await repo.updates()
        let collector = Task { () -> [Int] in
            var counts: [Int] = []
            for await l in stream {
                counts.append(l.tasks.count)
                if l.tasks.count == 100 { break }
            }
            return counts
        }
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<100 { g.addTask { _ = try? await repo.addTask(store: "s", item: "i\(i)") } }
        }
        let counts = await collector.value
        XCTAssertEqual(counts.last, 100)
        XCTAssertEqual(counts, counts.sorted(), "古い版が新しい版の後に届かない")
    }

    func testStreamEndsWhenRepositoryIsReleased() async throws {
        var repo: LedgerRepository? = try await LedgerRepository.open(store: InMemoryLedgerStore())
        let stream = await repo!.updates()
        var it = stream.makeAsyncIterator()
        _ = await it.next()
        repo = nil
        let end = await it.next()
        XCTAssertNil(end)
    }

    func testImportAgainstALargeLedgerIsFast() async throws {
        var tasks: [TodoTask] = []
        for i in 0..<2000 { tasks.append(TodoTask(store: "ダイソー", item: "品目\(i)", createdAt: now)) }
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(tasks: tasks)))
        let items = (0..<500).map { InflowItem(store: "ダイソー", item: "新品目\($0)", source: "x") }
        let t0 = Date()
        let summary = try await repo.importItems(items, now: now)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(summary.added.count, 500)
        XCTAssertLessThan(elapsed, 5, "2000 件 × 500 件の取込が \(elapsed) 秒")
    }

    func testImportReportsChainSpellingFromFirstValidRowAndSkipsInvalidFirst() async throws {
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore(Ledger(registeredChains: ["セリア"])))
        let s = try await repo.importItems([
            InflowItem(store: "  ", item: "x", source: ""),
            InflowItem(store: "ｄａｉｓｏ", item: "x", source: " "),
            InflowItem(store: "DAISO", item: "y", source: "s"),
            InflowItem(store: "ｾﾘｱ", item: "z", source: "s"),
        ])
        XCTAssertEqual(s.invalid, 1)
        XCTAssertEqual(s.added.count, 3)
        XCTAssertEqual(s.chainsNeedingRegistration, ["ｄａｉｓｏ"])
        XCTAssertEqual(s.added.map(\.source), [TaskImporter.defaultSource, "s", "s"])
    }
}
