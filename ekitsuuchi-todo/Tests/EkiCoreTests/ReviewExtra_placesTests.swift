import XCTest
import EkiCore

// 独立レビューで足した Places の追加テスト（壊しにいく側）。PlacesTests と重ならない境界・異常系だけ。

private struct RXFailure: Error, Equatable { var tag: String }

private final class RXTransport: HTTPTransport, @unchecked Sendable {   // NSLock で守る
    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, Error>]
    private let repeating: Result<HTTPResponse, Error>?
    private var recorded: [HTTPRequest] = []

    init(_ responses: [Result<HTTPResponse, Error>]) { queue = responses; repeating = nil }
    init(status: Int = 200, body: String) {
        queue = []
        repeating = .success(HTTPResponse(status: status, body: Data(body.utf8)))
    }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try next(for: request).get()
    }

    private func next(for request: HTTPRequest) -> Result<HTTPResponse, Error> {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        if let repeating { return repeating }
        return queue.isEmpty ? .failure(RXFailure(tag: "empty")) : queue.removeFirst()
    }
}

private let rxKey = "AIzaSyREVIEW_KEY_xyz_987"
private let rxCenter = Coordinate(latitude: 35.3388, longitude: 139.4900)

private func rxPoint(_ day: Int, _ hour: Int, _ minute: Int, date: String? = nil) -> String {
    var s = "{\"day\": \(day), \"hour\": \(hour), \"minute\": \(minute)"
    if let date {
        let p = date.split(separator: "-").map { Int($0) ?? 0 }
        s += ", \"date\": {\"year\": \(p[0]), \"month\": \(p[1]), \"day\": \(p[2])}"
    }
    return s + "}"
}

private func rxPeriod(_ open: String, _ close: String?) -> String {
    close.map { "{\"open\": \(open), \"close\": \($0)}" } ?? "{\"open\": \(open)}"
}

private func rxDaily() -> [String] {
    (0...6).map { rxPeriod(rxPoint($0, 10, 0), rxPoint($0, 21, 0)) }
}

private func rxHours(regular: [String]?, current: [String]? = nil, special: [String] = [], tz: String = "Asia/Tokyo") -> String {
    var parts: [String] = []
    if let regular { parts.append("\"regularOpeningHours\": {\"periods\": [\(regular.joined(separator: ","))]}") }
    if current != nil || !special.isEmpty {
        var inner = "\"periods\": [\((current ?? []).joined(separator: ","))]"
        if !special.isEmpty {
            let days = special.map { d -> String in
                let p = d.split(separator: "-").map { Int($0) ?? 0 }
                return "{\"date\": {\"year\": \(p[0]), \"month\": \(p[1]), \"day\": \(p[2])}}"
            }
            inner += ", \"specialDays\": [\(days.joined(separator: ","))]"
        }
        parts.append("\"currentOpeningHours\": {\(inner)}")
    }
    parts.append("\"timeZone\": {\"id\": \"\(tz)\"}")
    return "{" + parts.joined(separator: ",") + "}"
}

final class ReviewExtraPlacesTests: XCTestCase {
    private func client(_ t: RXTransport) -> PlacesClient { PlacesClient(apiKey: rxKey, transport: t) }

    private func hours(_ json: String) async throws -> OpeningHours? {
        try await client(RXTransport(body: json)).openingHours(placeID: "X")
    }

    private func sdPeriods(_ json: String) async throws -> [DayPeriod]? {
        try await hours(json)?.specialDays.first?.periods
    }

    // MARK: search: 壊れた/奇妙な応答

    func test1件の位置が壊れていても他の店は読める() async throws {
        // 緯度経度の片方が無い・空オブジェクト・null の場所が混ざっても、全体を malformed にしない。
        let json = """
        {"places": [
          {"id": "A", "displayName": {"text": "ダイソー 藤沢店"}, "location": {"latitude": 35.3395}},
          {"id": "B", "displayName": {"text": "ダイソー 藤沢店"}, "location": {}},
          {"id": "C", "displayName": {"text": "ダイソー 藤沢店"}, "location": null},
          {"id": "D", "displayName": {"text": "ダイソー 藤沢駅前店"}, "location": {"latitude": 35.3392, "longitude": 139.4902}}
        ]}
        """
        let r = try await client(RXTransport(body: json)).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500)
        XCTAssertEqual(r.map(\.placeID), ["D"])
    }

    func test座標が有限でない中心は_PlacesErrorで返す() async {
        let t = RXTransport(body: "{}")
        do {
            _ = try await client(t).searchBranches(chainName: "ダイソー", near: Coordinate(latitude: .nan, longitude: 139), radiusMeters: 500)
            XCTFail("should throw")
        } catch is PlacesError {
            XCTAssertTrue(t.requests.isEmpty)
        } catch {
            XCTFail("non-Places error leaked: \(error)")
        }
    }

    func test半径が非有限なら問い合わせず空() async throws {
        let t = RXTransport(body: "{}")
        let a = try await client(t).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: .nan)
        let b = try await client(t).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: .infinity)
        XCTAssertEqual(a, [])
        XCTAssertEqual(b, [])
        XCTAssertTrue(t.requests.isEmpty)
    }

    func test同距離の店は_idの順で安定して並ぶ() async throws {
        let json = """
        {"places": [
          {"id": "Z", "displayName": {"text": "ダイソー 1"}, "location": {"latitude": 35.3400, "longitude": 139.4900}},
          {"id": "A", "displayName": {"text": "ダイソー 2"}, "location": {"latitude": 35.3400, "longitude": 139.4900}}
        ]}
        """
        let r = try await client(RXTransport(body: json)).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500)
        XCTAssertEqual(r.map(\.placeID), ["A", "Z"])
    }

    func test全角空白だけのチェーン名と空idの場所() async throws {
        let t = RXTransport(body: "{}")
        let r = try await client(t).searchBranches(chainName: "\u{3000}\n", near: rxCenter, radiusMeters: 500)
        XCTAssertEqual(r, [])
        XCTAssertTrue(t.requests.isEmpty)

        let json = #"{"places": [{"id": "", "displayName": {"text": "ダイソー"}, "location": {"latitude": 35.3395, "longitude": 139.4905}}, {"displayName": {"text": "ダイソー"}, "location": {"latitude": 35.3395, "longitude": 139.4905}}]}"#
        let r2 = try await client(RXTransport(body: json)).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500)
        XCTAssertEqual(r2, [])
    }

    func testplacesがnullでも空配列() async throws {
        let r = try await client(RXTransport(body: #"{"places": null}"#)).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500)
        XCTAssertEqual(r, [])
    }

    func test合成文字や異体のチェーン名でも一致する() async throws {
        // 濁点が結合文字（ダ = タ + U+3099）の店名と、全角空白入りの店名。
        let json = """
        {"places": [
          {"id": "A", "displayName": {"text": "タ\u{3099}イソー 藤沢店"}, "location": {"latitude": 35.3395, "longitude": 139.4905}},
          {"id": "B", "displayName": {"text": "ダイ\u{3000}ソー 藤沢店"}, "location": {"latitude": 35.3396, "longitude": 139.4905}}
        ]}
        """
        let r = try await client(RXTransport(body: json)).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500)
        XCTAssertEqual(Set(r.map(\.placeID)), ["A", "B"])
    }

    func test並行して使っても結果が混ざらない() async throws {
        let json = """
        {"places": [{"id": "A", "displayName": {"text": "ダイソー 藤沢店"}, "location": {"latitude": 35.3395, "longitude": 139.4905}}]}
        """
        let t = RXTransport(body: json)
        let c = client(t)
        try await withThrowingTaskGroup(of: [String].self) { group in
            for _ in 0..<50 {
                group.addTask { try await c.searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500).map(\.placeID) }
            }
            for try await ids in group { XCTAssertEqual(ids, ["A"]) }
        }
        XCTAssertEqual(t.requests.count, 50)
    }

    // MARK: errors

    func testエラー本文がJSONでなくても分類できる() async {
        for (status, body, expected) in [
            (500, "<html>Bad gateway</html>", PlacesError.server(500)),
            (502, "", PlacesError.server(502)),
            (403, "forbidden", PlacesError.permissionDenied("HTTP 403")),
            (302, "", PlacesError.badRequest("HTTP 302")),
            (418, #"{"error":{}}"#, PlacesError.badRequest("HTTP 418")),
            (404, #"{"error":{"message":"   ","status":"NOT_FOUND"}}"#, PlacesError.notFound("NOT_FOUND")),
        ] {
            do {
                _ = try await client(RXTransport(status: status, body: body)).openingHours(placeID: "X")
                XCTFail("status \(status) should throw")
            } catch let e as PlacesError {
                XCTAssertEqual(e, expected, "status \(status)")
            } catch { XCTFail("\(error)") }
        }
    }

    func test長い日本語メッセージは300文字で切りキーは出ない() async {
        let long = String(repeating: "あ", count: 400) + rxKey
        let body = #"{"error":{"message":"\#(long)"}}"#
        do {
            _ = try await client(RXTransport(status: 400, body: body)).openingHours(placeID: "X")
            XCTFail()
        } catch let PlacesError.badRequest(m) {
            XCTAssertEqual(m.count, 300)
            XCTAssertFalse(m.contains(rxKey))
        } catch { XCTFail("\(error)") }

        // 切り口にキーがまたがっても、先に伏せてから切るので断片が残らない。
        let straddle = String(repeating: "x", count: 295) + rxKey
        do {
            _ = try await client(RXTransport(status: 400, body: #"{"error":{"message":"\#(straddle)"}}"#)).openingHours(placeID: "X")
            XCTFail()
        } catch let PlacesError.badRequest(m) {
            XCTAssertFalse(m.contains(String(rxKey.prefix(5))))
        } catch { XCTFail("\(error)") }
    }

    func test壊れた2xxのmalformedメッセージにもキーは出ない() async {
        do {
            _ = try await client(RXTransport(body: "not json \(rxKey)")).openingHours(placeID: "X")
            XCTFail()
        } catch let PlacesError.malformedResponse(m) {
            XCTAssertFalse(m.contains(rxKey))
        } catch { XCTFail("\(error)") }
    }

    func test空の2xx本文はmalformed() async {
        do {
            _ = try await client(RXTransport(status: 200, body: "")).searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500)
            XCTFail()
        } catch let e as PlacesError {
            guard case .malformedResponse = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
    }

    func test空白だけのキーは問い合わせない() async {
        for key in ["", "   ", "\n\t "] {
            let t = RXTransport(body: "{}")
            let c = PlacesClient(apiKey: key, transport: t)
            do { _ = try await c.openingHours(placeID: "X"); XCTFail() } catch { XCTAssertEqual(error as? PlacesError, .missingAPIKey) }
            do { _ = try await c.searchBranches(chainName: "ダイソー", near: rxCenter, radiusMeters: 500); XCTFail() } catch { XCTAssertEqual(error as? PlacesError, .missingAPIKey) }
            XCTAssertTrue(t.requests.isEmpty)
        }
    }

    // MARK: openingHours: request

    func test場所IDの記号と日本語はすべてエンコードされる() async throws {
        let t = RXTransport(body: "{}")
        _ = try await client(t).openingHours(placeID: "a/b?c#d e%f日本ＡＢ")
        let url = try XCTUnwrap(t.requests.first?.url)
        XCTAssertEqual(url, "https://places.googleapis.com/v1/places/a%2Fb%3Fc%23d%20e%25f%E6%97%A5%E6%9C%AC%EF%BC%A1%EF%BC%A2?languageCode=ja&regionCode=JP")
    }

    func test言語コードに記号があってもクエリを壊さない() async throws {
        let t = RXTransport(body: "{}")
        _ = try await PlacesClient(apiKey: rxKey, transport: t, languageCode: "ja&x=1", regionCode: "J P").openingHours(placeID: "X")
        XCTAssertEqual(t.requests.first?.url, "https://places.googleapis.com/v1/places/X?languageCode=ja%26x%3D1&regionCode=J%20P")
    }

    // MARK: openingHours: weekly 境界

    func test時刻の境界_0時と23時59分は通り_24時と60分は捨てる() async throws {
        let periods = [
            rxPeriod(rxPoint(1, 0, 0), rxPoint(1, 23, 59)),     // 有効
            rxPeriod(rxPoint(2, 10, 0), rxPoint(2, 24, 0)),     // 24 時は不正
            rxPeriod(rxPoint(3, 10, 60), rxPoint(3, 21, 0)),    // 60 分は不正
            rxPeriod(rxPoint(4, -1, 0), rxPoint(4, 21, 0)),     // 負
            rxPeriod(rxPoint(-1, 10, 0), rxPoint(0, 2, 0)),     // 曜日 -1
            rxPeriod(rxPoint(5, 10, 0), rxPoint(8, 2, 0)),      // 閉店曜日 8
        ]
        let h = try await hours(rxHours(regular: periods))
        XCTAssertEqual(h?.weekly, [WeeklyPeriod(openDay: 1, openMinute: 0, closeDay: 1, closeMinute: 1439)])
    }

    func test土曜から日曜へまたぐ枠と日曜から月曜へまたぐ枠() async throws {
        let periods = [
            rxPeriod(rxPoint(6, 22, 0), rxPoint(0, 2, 0)),
            rxPeriod(rxPoint(0, 22, 0), rxPoint(1, 2, 0)),
        ]
        let h = try await hours(rxHours(regular: periods))
        XCTAssertEqual(h?.weekly, [
            WeeklyPeriod(openDay: 0, openMinute: 1320, closeDay: 1, closeMinute: 120),
            WeeklyPeriod(openDay: 6, openMinute: 1320, closeDay: 0, closeMinute: 120),
        ])
    }

    func test0を省いた日曜0時開店_月曜0時閉店は24時間営業ではなく通常の枠() async throws {
        // 日曜 0:00-24:00: day/hour/minute が全部省かれた open と、day=1 の close。
        let json = #"{"regularOpeningHours":{"periods":[{"open":{},"close":{"day":1}}]}}"#
        let h = try await hours(json)
        XCTAssertEqual(h?.isAlwaysOpen, false)
        XCTAssertEqual(h?.weekly, [WeeklyPeriod(openDay: 0, openMinute: 0, closeDay: 1, closeMinute: 0)])
    }

    func test24時間営業でも特別日の休みは残る() async throws {
        let json = rxHours(regular: [rxPeriod(rxPoint(0, 0, 0), nil)],
                           current: [rxPeriod(rxPoint(1, 0, 0, date: "2026-12-28"), nil)],
                           special: ["2027-01-01"])
        let h = try await hours(json)
        XCTAssertEqual(h?.isAlwaysOpen, true)
        XCTAssertEqual(h?.weekly, [])
        XCTAssertEqual(h?.specialDays, [SpecialDay(date: CalendarDay(year: 2027, month: 1, day: 1), periods: [])])
    }

    func test24時間営業の判定は枠がちょうど1つのときだけ() async throws {
        // 日曜 0:00 close なしが他の枠と並んでも always-open にはしない。
        let periods = [rxPeriod(rxPoint(0, 0, 0), nil), rxPeriod(rxPoint(1, 10, 0), rxPoint(1, 21, 0))]
        let h = try await hours(rxHours(regular: periods))
        XCTAssertEqual(h?.isAlwaysOpen, false)
        XCTAssertEqual(h?.weekly, [WeeklyPeriod(openDay: 1, openMinute: 600, closeDay: 1, closeMinute: 1260)])
    }

    func test空のオブジェクトだけの応答はnil() async throws {
        let a = try await hours(#"{"regularOpeningHours":{}}"#)
        let b = try await hours(#"{"regularOpeningHours":{"periods":[{}]}}"#)
        let c = try await hours(#"{"currentOpeningHours":{"specialDays":[]}}"#)
        XCTAssertNil(a); XCTAssertNil(b); XCTAssertNil(c)
    }

    // MARK: openingHours: 特別日の日付計算

    func test特別日の翌日閉店は月またぎ_年またぎ_うるう日でも日数差が正しい() async throws {
        // 12/31 18:00 → 1/1 02:00（年またぎ）
        let y = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(4, 18, 0, date: "2026-12-31"), rxPoint(5, 2, 0, date: "2027-01-01"))], special: ["2026-12-31"]))
        XCTAssertEqual(y, [DayPeriod(openMinute: 1080, closeMinute: 1560)])
        // 2/28 → 3/1: 2028 年（うるう）は 2 日差、2027 年は 1 日差。
        let leap = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(1, 20, 0, date: "2028-02-28"), rxPoint(3, 0, 0, date: "2028-03-01"))], special: ["2028-02-28"]))
        XCTAssertEqual(leap, [DayPeriod(openMinute: 1200, closeMinute: 2880)])
        let common = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(0, 20, 0, date: "2027-02-28"), rxPoint(1, 0, 0, date: "2027-03-01"))], special: ["2027-02-28"]))
        XCTAssertEqual(common, [DayPeriod(openMinute: 1200, closeMinute: 1440)])
    }

    func test特別日の閉店が2日後の0時ちょうどは通り_それ以上は捨てる() async throws {
        let ok = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(1, 20, 0, date: "2026-12-14"), rxPoint(3, 0, 0, date: "2026-12-16"))], special: ["2026-12-14"]))
        XCTAssertEqual(ok, [DayPeriod(openMinute: 1200, closeMinute: 2880)])
        let over = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(1, 20, 0, date: "2026-12-14"), rxPoint(3, 0, 1, date: "2026-12-16"))], special: ["2026-12-14"]))
        XCTAssertEqual(over, [])
    }

    func test特別日の枠で閉店日が開店日より前なら捨てる() async throws {
        let p = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(4, 18, 0, date: "2026-12-31"), rxPoint(3, 21, 0, date: "2026-12-30"))], special: ["2026-12-31"]))
        XCTAssertEqual(p, [])
    }

    func test特別日で曜日差だけから閉店を求める_土曜深夜から日曜() async throws {
        let open = #"{"day": 6, "hour": 22, "minute": 0, "date": {"year": 2026, "month": 12, "day": 26}}"#
        let p = try await sdPeriods(rxHours(regular: rxDaily(), current: [rxPeriod(open, rxPoint(0, 2, 0))], special: ["2026-12-26"]))
        XCTAssertEqual(p, [DayPeriod(openMinute: 1320, closeMinute: 1560)])
    }

    func test特別日のcloseなしはその日の終わりまで() async throws {
        let p = try await sdPeriods(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(4, 10, 0, date: "2026-12-31"), nil)], special: ["2026-12-31"]))
        XCTAssertEqual(p, [DayPeriod(openMinute: 600, closeMinute: 1440)])
    }

    func test特別日の日付が欠けた項目は捨てる() async throws {
        let json = #"{"regularOpeningHours":{"periods":[{"open":{"day":1,"hour":10},"close":{"day":1,"hour":21}}]},"currentOpeningHours":{"periods":[{"open":{"day":1,"hour":10,"date":{"year":2026,"month":12,"day":28}},"close":{"day":1,"hour":21,"date":{"year":2026,"month":12,"day":28}}}],"specialDays":[{},{"date":{"year":2027,"month":1}},{"date":{"year":2027,"month":13,"day":1}},{"date":{"year":10000,"month":1,"day":1}},{"date":{"year":2027,"month":1,"day":1}}]}}"#
        let h = try await hours(json)
        XCTAssertEqual(h?.specialDays.map(\.date), [CalendarDay(year: 2027, month: 1, day: 1)])
    }

    // MARK: 評価に渡す前提

    func test返った営業時間はCodableで往復できる() async throws {
        let h = try await hours(rxHours(regular: rxDaily(),
            current: [rxPeriod(rxPoint(4, 18, 0, date: "2026-12-31"), rxPoint(5, 2, 0, date: "2027-01-01"))], special: ["2026-12-31", "2027-01-01"]))
        let data = try JSONEncoder().encode(try XCTUnwrap(h))
        XCTAssertEqual(try JSONDecoder().decode(OpeningHours.self, from: data), h)
    }
}
