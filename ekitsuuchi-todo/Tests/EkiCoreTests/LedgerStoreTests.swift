import XCTest
@testable import EkiCore

final class LedgerStoreTests: XCTestCase {
    // 2026-10-05 09:42:00 UTC = 18:42 JST
    private let t0 = Date(timeIntervalSince1970: 1_791_193_320)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func entries(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func sampleLedger() -> Ledger {
        let station = Station(name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4899), radiusMeters: 300)
        let hours = OpeningHours(
            weekly: [WeeklyPeriod(openDay: 5, openMinute: 1080, closeDay: 6, closeMinute: 120)],
            specialDays: [SpecialDay(date: CalendarDay(year: 2027, month: 1, day: 1), periods: [])]
        )
        let branch = Branch(
            id: "place-1",
            chainName: "ダイソー",
            name: "ダイソー 藤沢店",
            coordinate: Coordinate(latitude: 35.339, longitude: 139.49),
            hours: hours,
            hoursFetchedAt: Date(timeIntervalSince1970: 1_791_193_320.123),
            nearestStations: [StationDistance(stationID: station.id, meters: 320)],
            attributes: ["規模": "大型"]
        )
        let task = TodoTask(
            store: "ダイソー", item: "フィルム", source: "LINE:友人",
            sourceDate: CalendarDay(year: 2026, month: 9, day: 14),
            status: .ignored,
            createdAt: Date(timeIntervalSince1970: 1_791_193_320.5),
            completedAt: nil,
            ignoredUntil: Date(timeIntervalSince1970: 1_791_212_400)
        )
        let record = NotificationRecord(
            stationID: station.id, stationName: station.name, branchIDs: ["place-1"], taskIDs: [task.id],
            firedAt: Date(timeIntervalSince1970: 1_791_193_320.007), result: .suppressedClosed,
            location: LocationFix(coordinate: station.coordinate, horizontalAccuracy: 35, timestamp: Date(timeIntervalSince1970: 1_791_193_319)),
            detail: "閉店まで20分（ダイソー 藤沢店）"
        )
        return Ledger(
            tasks: [task], stations: [station], branches: [branch], history: [record],
            registeredChains: ["ダイソー"],
            settings: Settings(frequency: .everyEntry, checkBusinessHours: false, diagnosticMode: true)
        )
    }

    // MARK: 日時の表現

    func testDateCodingIsLosslessToTheMillisecond() {
        for ms in [0.0, 1.0, 7.0, 122.0, 123.0, 999.0] {
            let d = Date(timeIntervalSince1970: 1_791_193_320 + ms / 1000)
            let s = LedgerDateCoding.string(from: d)
            XCTAssertEqual(LedgerDateCoding.date(from: s), d, "ms=\(ms) via \(s)")
        }
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: 1_791_193_320.123)), "2026-10-05T09:42:00.123Z")
        // .123 が 0.12299… で保存されていても .122 に落ちない（丸める）。
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: 1_791_193_320.1229999)), "2026-10-05T09:42:00.123Z")
    }

    func testDateCodingHandlesEpochNegativeAndLeapDay() {
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: -1)), "1969-12-31T23:59:59.000Z")
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: -0.001)), "1969-12-31T23:59:59.999Z")
        // 2028-02-29 12:00:00 UTC
        XCTAssertEqual(LedgerDateCoding.date(from: "2028-02-29T12:00:00.000Z"), Date(timeIntervalSince1970: 1_835_438_400))
        XCTAssertEqual(LedgerDateCoding.string(from: Date(timeIntervalSince1970: 1_835_438_400)), "2028-02-29T12:00:00.000Z")
    }

    func testDateCodingAcceptsOffsetsAndMissingFraction() {
        let utc = LedgerDateCoding.date(from: "2026-10-05T09:42:00Z")
        XCTAssertEqual(utc, t0)
        XCTAssertEqual(LedgerDateCoding.date(from: "2026-10-05T18:42:00+09:00"), t0)
        XCTAssertEqual(LedgerDateCoding.date(from: "2026-10-05T18:42:00.000+0900"), t0)
        XCTAssertEqual(LedgerDateCoding.date(from: "2026-10-05T04:12:00-05:30"), t0)
        XCTAssertEqual(LedgerDateCoding.date(from: "2026-10-05T09:42:00.1234567Z"), Date(timeIntervalSince1970: 1_791_193_320.123))
    }

    func testDateCodingRejectsGarbage() {
        for bad in ["", "2026-10-05", "2026-10-05T09:42:00", "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z",
                    "2026-10-05T24:00:00Z", "2026-10-05T09:42:00.Z", "2026-10-05T09:42:00Zjunk", "yesterday"] {
            XCTAssertNil(LedgerDateCoding.date(from: bad), bad)
        }
    }

    // MARK: JSONFileLedgerStore

    func testRoundTripThroughTempDirectoryKeepsEverything() throws {
        let url = try makeTempDir().appendingPathComponent("ledger.json")
        let store = JSONFileLedgerStore(url: url)
        let ledger = sampleLedger()
        try store.save(ledger)
        XCTAssertEqual(try store.load(), ledger)
    }

    func testMissingFileLoadsAnEmptyLedger() throws {
        let url = try makeTempDir().appendingPathComponent("nothing.json")
        XCTAssertEqual(try JSONFileLedgerStore(url: url).load(), Ledger())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "load は読むだけで、ファイルを作らない")
    }

    func testSaveCreatesMissingParentDirectories() throws {
        let url = try makeTempDir().appendingPathComponent("a/b/c/ledger.json")
        try JSONFileLedgerStore(url: url).save(sampleLedger())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSavedFileIsPrettyPrintedWithSortedKeysAndIsoDatesWithFraction() throws {
        let url = try makeTempDir().appendingPathComponent("ledger.json")
        try JSONFileLedgerStore(url: url).save(sampleLedger())
        let text = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(text.contains("\n  "), "pretty printed")
        XCTAssertTrue(text.contains("\"createdAt\" : \"2026-10-05T09:42:00.500Z\""), text)
        let branches = try XCTUnwrap(text.range(of: "\"branches\""))
        let history = try XCTUnwrap(text.range(of: "\"history\""))
        let tasks = try XCTUnwrap(text.range(of: "\"tasks\""))
        XCTAssertTrue(branches.lowerBound < history.lowerBound && history.lowerBound < tasks.lowerBound, "sorted keys")
    }

    func testAtomicSaveLeavesOnlyTheLedgerFileAndReplacesItWholly() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        let store = JSONFileLedgerStore(url: url)
        try store.save(sampleLedger())
        try store.save(Ledger())
        XCTAssertEqual(try entries(in: dir), ["ledger.json"], "一時ファイルが残らない")
        XCTAssertEqual(try store.load(), Ledger())
    }

    func testSaveFailureThrowsAndLeavesNeighboursAlone() throws {
        let dir = try makeTempDir()
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        // 親がファイルなのでディレクトリを作れない。
        let store = JSONFileLedgerStore(url: blocker.appendingPathComponent("ledger.json"))
        XCTAssertThrowsError(try store.save(sampleLedger()))
        XCTAssertEqual(try Data(contentsOf: blocker), Data("x".utf8))
        XCTAssertEqual(try entries(in: dir), ["blocker"])
    }

    func testOlderSchemaFileIsLoadedAndRewrittenAsCurrent() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        try Data(#"{"schemaVersion":0,"tasks":[]}"#.utf8).write(to: url)
        let store = JSONFileLedgerStore(url: url)
        var ledger = try store.load()
        XCTAssertEqual(ledger.schemaVersion, 0)
        ledger.schemaVersion = 0
        try store.save(ledger)
        XCTAssertEqual(try store.load().schemaVersion, Ledger.currentSchemaVersion)
    }

    // MARK: 壊れたファイル

    func testCorruptFileIsMovedAsideNotOverwrittenAndNextLoadStartsFresh() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)
        let store = JSONFileLedgerStore(url: url, now: { Date(timeIntervalSince1970: 1_791_193_320) })

        var backupPath = ""
        XCTAssertThrowsError(try store.load()) { error in
            guard case .corrupt(let path)? = error as? LedgerStoreError else { return XCTFail("\(error)") }
            backupPath = path
        }
        XCTAssertEqual(URL(fileURLWithPath: backupPath).lastPathComponent, "ledger.json.corrupt-1791193320")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backupPath)), garbage, "中身はそのまま退避")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.load(), Ledger(), "次の load は空の台帳")
        XCTAssertEqual(try entries(in: dir), ["ledger.json.corrupt-1791193320"])
    }

    func testSecondCorruptionInTheSameSecondDoesNotClobberTheFirstBackup() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        let store = JSONFileLedgerStore(url: url, now: { Date(timeIntervalSince1970: 1_791_193_320) })
        try Data("first".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        try Data("second".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        let names = try entries(in: dir)
        XCTAssertEqual(names.count, 2)
        let contents = try names.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertEqual(Set(contents), ["first", "second"])
    }

    func testValidJSONOfTheWrongShapeAndEmptyFilesCountAsCorrupt() throws {
        for body in ["[]", "42", "", #"{"tasks":"nope"}"#, #"{"schemaVersion":"1"}"#,
                     #"{"tasks":[{"id":"not-a-uuid"}]}"#, #"{"history":[{"firedAt":"yesterday"}]}"#] {
            let dir = try makeTempDir()
            let url = dir.appendingPathComponent("ledger.json")
            try Data(body.utf8).write(to: url)
            XCTAssertThrowsError(try JSONFileLedgerStore(url: url).load(), body) { error in
                guard case .corrupt? = error as? LedgerStoreError else { return XCTFail("\(body): \(error)") }
            }
            XCTAssertEqual(try entries(in: dir).count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), body)
        }
    }

    func testNewerSchemaIsRefusedAndLeftUntouched() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        // 将来の版で型が変わっていても読めなくてよい（本体は読まない）。
        let body = Data(#"{"schemaVersion":99,"tasks":"a shape this app cannot read"}"#.utf8)
        try body.write(to: url)
        let store = JSONFileLedgerStore(url: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LedgerStoreError, .newerSchema(found: 99, supported: Ledger.currentSchemaVersion))
        }
        XCTAssertEqual(try Data(contentsOf: url), body)
        XCTAssertEqual(try entries(in: dir), ["ledger.json"])
        XCTAssertThrowsError(try store.load(), "何度読んでも同じ。退避も上書きもしない")
    }

    func testRepositoryOpenSurfacesCorruptionInsteadOfStartingEmptyOverIt() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ledger.json")
        try Data("garbage".utf8).write(to: url)
        let store = JSONFileLedgerStore(url: url)
        do {
            _ = try await LedgerRepository.open(store: store)
            XCTFail("open must throw")
        } catch let error as LedgerStoreError {
            guard case .corrupt(let path) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), "garbage")
        }
        // 退避後は開ける。
        let repo = try await LedgerRepository.open(store: store)
        let snapshot = await repo.snapshot()
        XCTAssertEqual(snapshot, Ledger())
    }

    // MARK: InMemoryLedgerStore

    func testInMemoryStoreRoundTripsAndCountsSaves() throws {
        let store = InMemoryLedgerStore()
        XCTAssertEqual(try store.load(), Ledger())
        let ledger = sampleLedger()
        try store.save(ledger)
        XCTAssertEqual(try store.load(), ledger)
        XCTAssertEqual(store.saveCount, 1)
    }
}
