import XCTest
@testable import EkiCore

final class ImportTests: XCTestCase {
    private func parse(_ json: String) throws -> ImportParseResult {
        try TaskImporter.parse(Data(json.utf8))
    }

    private func assertImportError(_ json: String, _ expected: ImportError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(json), file: file, line: line) { error in
            XCTAssertEqual(error as? ImportError, expected, file: file, line: line)
        }
    }

    // MARK: 契約どおりのファイル（設計書 §2）

    func testTheExampleFileFromTheSpecParses() throws {
        let result = try parse("""
        {
          "version": 1,
          "items": [
            {"store": "ダイソー", "item": "フィルム", "source": "LINE:友人", "date": "2026-09-14"},
            {"store": "無印良品", "item": "ファイルボックス", "source": "Notion:HQ", "date": "2026-09-20"}
          ]
        }
        """)
        XCTAssertEqual(result.rejected, [])
        XCTAssertEqual(result.items, [
            InflowItem(store: "ダイソー", item: "フィルム", source: "LINE:友人", date: CalendarDay(year: 2026, month: 9, day: 14)),
            InflowItem(store: "無印良品", item: "ファイルボックス", source: "Notion:HQ", date: CalendarDay(year: 2026, month: 9, day: 20)),
        ])
    }

    func testTenItemsFileAddsTenTasks() async throws {
        // 計画書 M4 の完了条件: 契約どおりのファイルで 10 件が入る。
        let rows = (1...10).map { #"{"store":"ダイソー","item":"品目\#($0)","source":"LINE:友人","date":"2026-09-\#(String(format: "%02d", $0))"}"# }
        let data = Data(#"{"version":1,"items":[\#(rows.joined(separator: ","))]}"#.utf8)
        let repo = try await LedgerRepository.open(store: InMemoryLedgerStore())
        let items = try await JSONDataInflow(data).fetchItems()
        let summary = try await repo.importItems(items, now: Date(timeIntervalSince1970: 1_791_193_320))
        XCTAssertEqual(summary.added.count, 10)
        XCTAssertEqual(summary.duplicates, 0)
        XCTAssertEqual(summary.chainsNeedingRegistration, ["ダイソー"])
        // 同じファイルをもう一度読み込んでも増えない。
        let again = try await repo.importItems(items)
        XCTAssertEqual(again.added.count, 0)
        XCTAssertEqual(again.duplicates, 10)
        let count = await repo.snapshot().tasks.count
        XCTAssertEqual(count, 10)
    }

    // MARK: ファイル全体のエラー

    func testUTF8BOMIsTolerated() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"version":1,"items":[{"store":"ダイソー","item":"フィルム"}]}"#.utf8))
        let result = try TaskImporter.parse(data)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].store, "ダイソー")
    }

    func testNotJSONIsAWholeFileError() {
        assertImportError("これは JSON ではない", .notJSON)
        assertImportError("", .notJSON)
        assertImportError("{ \"version\": 1, ", .notJSON)
        assertImportError("[]", .notJSON)
        assertImportError("42", .notJSON)
        assertImportError("\"version\"", .notJSON)
    }

    func testMissingOrUnsupportedVersionIsAWholeFileError() {
        assertImportError(#"{"items":[]}"#, .missingVersion)
        assertImportError(#"{"version":null,"items":[]}"#, .missingVersion)
        assertImportError(#"{"version":2,"items":[]}"#, .unsupportedVersion("2"))
        assertImportError(#"{"version":0,"items":[]}"#, .unsupportedVersion("0"))
        assertImportError(#"{"version":"1","items":[]}"#, .unsupportedVersion("\"1\""))
        assertImportError(#"{"version":true,"items":[]}"#, .unsupportedVersion("true"))
        assertImportError(#"{"version":1.5,"items":[]}"#, .unsupportedVersion("1.5"))
    }

    func testItemsMustBeAnArray() {
        assertImportError(#"{"version":1}"#, .itemsNotArray)
        assertImportError(#"{"version":1,"items":null}"#, .itemsNotArray)
        assertImportError(#"{"version":1,"items":{"store":"ダイソー","item":"フィルム"}}"#, .itemsNotArray)
        assertImportError(#"{"version":1,"items":"none"}"#, .itemsNotArray)
    }

    func testEmptyItemsArrayIsFine() throws {
        let result = try parse(#"{"version":1,"items":[]}"#)
        XCTAssertEqual(result, ImportParseResult(items: [], rejected: []))
    }

    // MARK: 行ごとの不備はファイルを失敗させない

    func testBadRowsAreRejectedWithTheirIndexAndGoodRowsStillImport() throws {
        let result = try parse("""
        {"version":1,"items":[
          {"store":"ダイソー","item":"フィルム"},
          {"item":"店がない"},
          {"store":"セリア"},
          {"store":"  ","item":"フィルム"},
          {"store":"セリア","item":" \\t"},
          "文字列の行",
          42,
          null,
          {"store":123,"item":"フィルム"},
          {"store":"セリア","item":["配列"]},
          {"store":"無印良品","item":"ファイルボックス"}
        ]}
        """)
        XCTAssertEqual(result.items.map(\.store), ["ダイソー", "無印良品"])
        XCTAssertEqual(result.rejected.map(\.index), [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertTrue(result.rejected.allSatisfy { !$0.reason.isEmpty })
        XCTAssertEqual(result.rejected[0].reason, "store がありません")
        XCTAssertEqual(result.rejected[1].reason, "item がありません")
        XCTAssertEqual(result.rejected[2].reason, "store が空です")
        XCTAssertEqual(result.rejected[3].reason, "item が空です")
    }

    func testDateMustBeStrictIsoOrTheRowIsRejected() throws {
        let bad = ["2026-9-14", "2026/09/14", "2026-02-30", "2026-13-01", "20260914", "yesterday", " 2026-09-14", "2026-09-14T00:00:00Z", "", "26-09-14"]
        for d in bad {
            let json = #"{"version":1,"items":[{"store":"ダイソー","item":"フィルム","date":"\#(d)"}]}"#
            let result = try parse(json)
            XCTAssertEqual(result.items, [], "date=\(d)")
            XCTAssertEqual(result.rejected.count, 1, "date=\(d)")
            XCTAssertEqual(result.rejected.first?.index, 0)
        }
        let nonString = try parse(#"{"version":1,"items":[{"store":"ダイソー","item":"フィルム","date":20260914}]}"#)
        XCTAssertEqual(nonString.rejected.count, 1)
    }

    func testDateIsOptionalAndNullIsTreatedAsMissing() throws {
        let result = try parse(#"{"version":1,"items":[{"store":"ダイソー","item":"a"},{"store":"ダイソー","item":"b","date":null,"source":null}]}"#)
        XCTAssertEqual(result.rejected, [])
        XCTAssertEqual(result.items.map(\.date), [nil, nil])
    }

    func testMissingBlankOrNullSourceBecomesJSONTorikomi() throws {
        let result = try parse(#"{"version":1,"items":[{"store":"ダイソー","item":"a"},{"store":"ダイソー","item":"b","source":"  "},{"store":"ダイソー","item":"c","source":null},{"store":"ダイソー","item":"d","source":" Notion:HQ "}]}"#)
        XCTAssertEqual(result.items.map(\.source), ["JSON取込", "JSON取込", "JSON取込", "Notion:HQ"])
        let wrongType = try parse(#"{"version":1,"items":[{"store":"ダイソー","item":"a","source":5}]}"#)
        XCTAssertEqual(wrongType.rejected.count, 1)
    }

    func testStoreAndItemAreTrimmed() throws {
        let result = try parse(#"{"version":1,"items":[{"store":"  ダイソー\n","item":"\tフィルム  "}]}"#)
        XCTAssertEqual(result.items.first?.store, "ダイソー")
        XCTAssertEqual(result.items.first?.item, "フィルム")
    }

    func testUnknownExtraKeysAreIgnoredAtEveryLevel() throws {
        let result = try parse("""
        {"version":1,"generatedBy":"extractor 0.3","meta":{"a":[1,2,3]},
         "items":[{"store":"ダイソー","item":"フィルム","confidence":0.4,"tags":["x"],"nested":{"k":null}}]}
        """)
        XCTAssertEqual(result.rejected, [])
        XCTAssertEqual(result.items.count, 1)
    }

    func testVersionOneWrittenAsOnePointZeroIsAccepted() throws {
        let result = try parse(#"{"version":1.0,"items":[]}"#)
        XCTAssertEqual(result.items, [])
    }

    func testUnicodeSurvives() throws {
        let result = try parse(#"{"version":1,"items":[{"store":"ＤＡＩＳＯ","item":"🎞️ フィルム（36枚）","source":"LINE:友人"}]}"#)
        XCTAssertEqual(result.items.first?.store, "ＤＡＩＳＯ")
        XCTAssertEqual(result.items.first?.item, "🎞️ フィルム（36枚）")
    }

    // MARK: TaskInflow

    func testJSONDataInflowReturnsGoodRowsAndThrowsOnWholeFileErrors() async throws {
        let ok = JSONDataInflow(Data(#"{"version":1,"items":[{"store":"ダイソー","item":"a"},{"item":"店なし"}]}"#.utf8))
        let items = try await ok.fetchItems()
        XCTAssertEqual(items.count, 1)

        let bad = JSONDataInflow(Data("nope".utf8))
        do { _ = try await bad.fetchItems(); XCTFail() }
        catch { XCTAssertEqual(error as? ImportError, .notJSON) }
    }

    func testErrorsHaveJapaneseDescriptions() {
        XCTAssertNotNil(ImportError.notJSON.errorDescription)
        XCTAssertTrue(ImportError.unsupportedVersion("2").errorDescription?.contains("2") == true)
    }

    // MARK: TaskDedupe の正規化

    func testNormalizedItemFoldsWidthCaseAndWhitespace() {
        XCTAssertEqual(TaskDedupe.normalizedItem("  Ｆｉｌｍ \t Case\n"), "film case")
        XCTAssertEqual(TaskDedupe.normalizedItem("ﾌｨﾙﾑ"), "フィルム")
        XCTAssertEqual(TaskDedupe.normalizedItem("フィルム　36枚"), "フィルム 36枚", "全角空白も畳む")
        XCTAssertEqual(TaskDedupe.normalizedItem("   "), "")
    }
}
