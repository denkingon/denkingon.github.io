import XCTest
import EkiCore

// Places API (New) の呼び出しと応答の解釈（§4 店登録時・週1更新）。
// 通信は記録するだけの偽 HTTPTransport で、応答は実際の形に似せた JSON 文字列で与える。

// MARK: - 偽 HTTPTransport

private struct StubFailure: Error, Equatable { var tag: String }

/// 受けたリクエストを全部記録し、用意した応答を順に返す。
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {   // NSLock で守る
    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, Error>]
    private var recorded: [HTTPRequest] = []

    init(_ responses: [Result<HTTPResponse, Error>]) { queue = responses }

    convenience init(status: Int = 200, json: String) {
        self.init([.success(HTTPResponse(status: status, body: Data(json.utf8)))])
    }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try next(for: request).get()
    }

    private func next(for request: HTTPRequest) -> Result<HTTPResponse, Error> {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        if queue.isEmpty { return .failure(StubFailure(tag: "no response queued")) }
        return queue.removeFirst()
    }
}

// MARK: - fixtures

private let testKey = "AIzaSyTEST_KEY_do_not_use_123"
private let fujisawa = Coordinate(latitude: 35.3388, longitude: 139.4900)

/// 搜索応答: 距離・名前・重複の入った 1 本（駅から 500 m で検索する想定）。
private let searchFixture = """
{
  "places": [
    {
      "id": "ChIJ_daiso_near",
      "displayName": { "text": "ダイソー 藤沢店", "languageCode": "ja" },
      "location": { "latitude": 35.3417, "longitude": 139.4900 }
    },
    {
      "id": "ChIJ_daiso_far",
      "displayName": { "text": "ダイソー 辻堂店", "languageCode": "ja" },
      "location": { "latitude": 35.3388, "longitude": 139.4400 }
    },
    {
      "id": "ChIJ_seria",
      "displayName": { "text": "セリア 藤沢店", "languageCode": "ja" },
      "location": { "latitude": 35.3390, "longitude": 139.4905 }
    },
    {
      "id": "ChIJ_daiso_station",
      "displayName": { "text": "ダイソー 藤沢駅前店", "languageCode": "ja" },
      "location": { "latitude": 35.3392, "longitude": 139.4902 }
    },
    {
      "id": "ChIJ_daiso_near",
      "displayName": { "text": "ダイソー 藤沢店", "languageCode": "ja" },
      "location": { "latitude": 35.3417, "longitude": 139.4900 }
    },
    {
      "id": "ChIJ_no_location",
      "displayName": { "text": "ダイソー 場所なし店", "languageCode": "ja" }
    }
  ]
}
"""

private func point(_ day: Int, _ hour: Int, _ minute: Int, date: String? = nil) -> String {
    var s = "{\"day\": \(day), \"hour\": \(hour), \"minute\": \(minute)"
    if let date {
        let p = date.split(separator: "-").map { Int($0) ?? 0 }
        s += ", \"date\": {\"year\": \(p[0]), \"month\": \(p[1]), \"day\": \(p[2])}"
    }
    return s + "}"
}

/// {open, close} 1 枠。
private func period(open: String, close: String?) -> String {
    close.map { "{\"open\": \(open), \"close\": \($0)}" } ?? "{\"open\": \(open)}"
}

/// 毎日同じ時間帯の 7 枠（日曜から）。
private func dailyPeriods(openHour: Int, closeHour: Int) -> [String] {
    (0...6).map { period(open: point($0, openHour, 0), close: point($0, closeHour, 0)) }
}

private func hoursJSON(regular: [String]?, current: [String]? = nil, specialDates: [String] = [], timeZone: String? = "Asia/Tokyo") -> String {
    var parts: [String] = []
    if let regular {
        parts.append("\"regularOpeningHours\": {\"openNow\": true, \"periods\": [\(regular.joined(separator: ","))]}")
    }
    if current != nil || !specialDates.isEmpty {
        var inner = "\"openNow\": true, \"periods\": [\((current ?? []).joined(separator: ","))]"
        if !specialDates.isEmpty {
            let days = specialDates.map { d -> String in
                let p = d.split(separator: "-").map { Int($0) ?? 0 }
                return "{\"date\": {\"year\": \(p[0]), \"month\": \(p[1]), \"day\": \(p[2])}}"
            }
            inner += ", \"specialDays\": [\(days.joined(separator: ","))]"
        }
        parts.append("\"currentOpeningHours\": {\(inner)}")
    }
    if let timeZone { parts.append("\"timeZone\": {\"id\": \"\(timeZone)\"}") }
    return "{" + parts.joined(separator: ",") + "}"
}

private func weekly(_ openDay: Int, _ open: Int, _ closeDay: Int, _ close: Int) -> WeeklyPeriod {
    WeeklyPeriod(openDay: openDay, openMinute: open, closeDay: closeDay, closeMinute: close)
}

private let ordinaryWeekly = (0...6).map { weekly($0, 10 * 60, $0, 21 * 60) }

// MARK: - tests

final class PlacesTests: XCTestCase {
    private func client(_ transport: RecordingTransport, key: String = testKey) -> PlacesClient {
        PlacesClient(apiKey: key, transport: transport)
    }

    private func expectError<T>(_ expected: PlacesError, file: StaticString = #filePath, line: UInt = #line,
                                _ block: () async throws -> T) async {
        do {
            _ = try await block()
            XCTFail("expected \(expected) but nothing was thrown", file: file, line: line)
        } catch let e as PlacesError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected) but got \(error)", file: file, line: line)
        }
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let d = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    // MARK: searchBranches: request

    func test検索リクエストは_URL_メソッド_ヘッダ_ボディが仕様どおり() async throws {
        let transport = RecordingTransport(json: "{}")
        _ = try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url, "https://places.googleapis.com/v1/places:searchText")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers, [
            "Content-Type": "application/json",
            "X-Goog-Api-Key": testKey,
            "X-Goog-FieldMask": "places.id,places.displayName,places.location",
        ])

        let body = try jsonObject(request.body)
        XCTAssertEqual(Set(body.keys), ["textQuery", "languageCode", "regionCode", "pageSize", "locationBias"])
        XCTAssertEqual(body["textQuery"] as? String, "ダイソー")
        XCTAssertEqual(body["languageCode"] as? String, "ja")
        XCTAssertEqual(body["regionCode"] as? String, "JP")
        XCTAssertEqual(body["pageSize"] as? Int, 20)
        let circle = try XCTUnwrap((body["locationBias"] as? [String: Any])?["circle"] as? [String: Any])
        let center = try XCTUnwrap(circle["center"] as? [String: Any])
        XCTAssertEqual(center["latitude"] as? Double, 35.3388)
        XCTAssertEqual(center["longitude"] as? Double, 139.4900)
        XCTAssertEqual(circle["radius"] as? Double, 500)
    }

    func testAPIキーはヘッダにだけ載り_URLにもボディにも出ない() async throws {
        let search = RecordingTransport(json: "{}")
        _ = try await client(search).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
        let hours = RecordingTransport(json: "{}")
        _ = try await client(hours).openingHours(placeID: "ChIJ_daiso_near")

        for request in search.requests + hours.requests {
            XCTAssertFalse(request.url.contains(testKey), "key in URL")
            XCTAssertFalse(request.url.lowercased().contains("key="), "key= query parameter")
            if let body = request.body { XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(testKey), "key in body") }
            for (name, value) in request.headers where name != "X-Goog-Api-Key" {
                XCTAssertFalse(value.contains(testKey), "key in header \(name)")
            }
            XCTAssertEqual(request.headers["X-Goog-Api-Key"], testKey)
        }
    }

    func test言語と地域コードは初期化引数が使われる() async throws {
        let transport = RecordingTransport(json: "{}")
        let c = PlacesClient(apiKey: testKey, transport: transport, languageCode: "en", regionCode: "US")
        _ = try await c.searchBranches(chainName: "Daiso", near: fujisawa, radiusMeters: 500)
        let body = try jsonObject(transport.requests.first?.body)
        XCTAssertEqual(body["languageCode"] as? String, "en")
        XCTAssertEqual(body["regionCode"] as? String, "US")
    }

    func testキーの前後の空白と改行は落としてヘッダに載せる() async throws {
        let transport = RecordingTransport(json: "{}")
        _ = try await client(transport, key: "  \(testKey)\n").searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
        XCTAssertEqual(transport.requests.first?.headers["X-Goog-Api-Key"], testKey)
    }

    func testクライアントを表示してもキーは出ない() {
        let c = client(RecordingTransport([]))
        XCTAssertFalse("\(c)".contains(testKey))
        XCTAssertFalse(String(reflecting: c).contains(testKey))
        var dumped = ""
        dump(c, to: &dumped)
        XCTAssertFalse(dumped.contains(testKey))
    }

    // MARK: searchBranches: result

    func test半径外と店名不一致と重複と位置なしを除き_近い順に返す() async throws {
        let transport = RecordingTransport(json: searchFixture)
        let result = try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)

        // 辻堂店は約 4.5 km（半径外）、セリアは名前不一致、重複 id は 1 件、位置なしは捨てる。
        XCTAssertEqual(result.map(\.placeID), ["ChIJ_daiso_station", "ChIJ_daiso_near"])
        XCTAssertEqual(result.map(\.name), ["ダイソー 藤沢駅前店", "ダイソー 藤沢店"])
        XCTAssertEqual(result[1].coordinate, Coordinate(latitude: 35.3417, longitude: 139.4900))
    }

    func test全角半角と大文字小文字が違う店名でもチェーン名に一致する() async throws {
        let json = """
        {"places": [
          {"id": "A", "displayName": {"text": "ＤＡＩＳＯ 藤沢店"}, "location": {"latitude": 35.3395, "longitude": 139.4905}},
          {"id": "B", "displayName": {"text": "Daiso Fujisawa"}, "location": {"latitude": 35.3400, "longitude": 139.4910}},
          {"id": "C", "displayName": {"text": "ﾀﾞｲｿｰ 辻堂店"}, "location": {"latitude": 35.3410, "longitude": 139.4900}}
        ]}
        """
        let latin = try await client(RecordingTransport(json: json)).searchBranches(chainName: "daiso", near: fujisawa, radiusMeters: 500)
        XCTAssertEqual(latin.map(\.placeID), ["A", "B"])

        // 半角カナの店名は NFKC でカタカナに揃い、全角のチェーン名に一致する。
        let kana = try await client(RecordingTransport(json: json)).searchBranches(chainName: " ダイソー ", near: fujisawa, radiusMeters: 500)
        XCTAssertEqual(kana.map(\.placeID), ["C"])
    }

    func test半径ちょうどは含み_わずかに超えると除く() async throws {
        let place = Coordinate(latitude: 35.3417, longitude: 139.4900)
        let json = """
        {"places": [{"id": "X", "displayName": {"text": "ダイソー 藤沢店"}, "location": {"latitude": 35.3417, "longitude": 139.4900}}]}
        """
        let exact = fujisawa.distance(to: place)
        let included = try await client(RecordingTransport(json: json)).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: exact)
        XCTAssertEqual(included.map(\.placeID), ["X"])
        let excluded = try await client(RecordingTransport(json: json)).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: exact - 0.001)
        XCTAssertTrue(excluded.isEmpty)
    }

    func test該当なしの応答は空配列() async throws {
        let result = try await client(RecordingTransport(json: "{}")).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
        XCTAssertEqual(result, [])
    }

    func testチェーン名が空なら問い合わせず空を返す() async throws {
        let transport = RecordingTransport([])
        let result = try await client(transport).searchBranches(chainName: "  　", near: fujisawa, radiusMeters: 500)
        XCTAssertEqual(result, [])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func test半径が0以下なら問い合わせず空を返す() async throws {
        let transport = RecordingTransport([])
        let c = client(transport)
        let zero = try await c.searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 0)
        let negative = try await c.searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: -5)
        XCTAssertEqual(zero, [])
        XCTAssertEqual(negative, [])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testバイアス半径はAPI上限の50kmで頭打ちにする() async throws {
        let transport = RecordingTransport(json: "{}")
        _ = try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 80_000)
        let body = try jsonObject(transport.requests.first?.body)
        let circle = try XCTUnwrap((body["locationBias"] as? [String: Any])?["circle"] as? [String: Any])
        XCTAssertEqual(circle["radius"] as? Double, 50_000)
    }

    // MARK: errors

    func testステータスごとのエラー分類_検索() async {
        let cases: [(Int, String, PlacesError)] = [
            (400, #"{"error":{"code":400,"message":"Invalid textQuery.","status":"INVALID_ARGUMENT"}}"#, .badRequest("Invalid textQuery.")),
            (401, #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#,
             .permissionDenied("Request had invalid authentication credentials.")),
            (403, #"{"error":{"code":403,"message":"API key not valid. Please pass a valid API key.","status":"PERMISSION_DENIED"}}"#,
             .permissionDenied("API key not valid. Please pass a valid API key.")),
            (404, #"{"error":{"code":404,"message":"Place not found.","status":"NOT_FOUND"}}"#, .notFound("Place not found.")),
            (429, #"{"error":{"code":429,"message":"Quota exceeded.","status":"RESOURCE_EXHAUSTED"}}"#, .rateLimited),
            (500, #"{"error":{"code":500,"message":"Internal error.","status":"INTERNAL"}}"#, .server(500)),
            (503, #"{"error":{"code":503,"message":"Unavailable.","status":"UNAVAILABLE"}}"#, .server(503)),
            (418, #"{"error":{"code":418,"message":"teapot","status":"X"}}"#, .badRequest("teapot")),
            (302, "", .badRequest("HTTP 302")),
        ]
        for (status, body, expected) in cases {
            let transport = RecordingTransport(status: status, json: body)
            await expectError(expected) {
                try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
            }
        }
    }

    func testステータスごとのエラー分類_営業時間() async {
        let cases: [(Int, PlacesError)] = [
            (400, .badRequest("HTTP 400")), (401, .permissionDenied("HTTP 401")), (403, .permissionDenied("HTTP 403")),
            (404, .notFound("HTTP 404")), (429, .rateLimited), (500, .server(500)), (502, .server(502)),
        ]
        for (status, expected) in cases {
            // 本文が JSON でなくても分類できる（メッセージは HTTP ステータスにフォールバック）。
            let transport = RecordingTransport(status: status, json: "<html>nope</html>")
            await expectError(expected) { try await client(transport).openingHours(placeID: "ChIJ_x") }
        }
    }

    func testエラー本文にmessageが無ければstatusを使う() async {
        let transport = RecordingTransport(status: 403, json: #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#)
        await expectError(.permissionDenied("PERMISSION_DENIED")) {
            try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
        }
    }

    func testエラーメッセージにキーが混ざっていたら伏せる() async {
        let transport = RecordingTransport(status: 403, json: #"{"error":{"message":"The key \#(testKey) is restricted."}}"#)
        await expectError(.permissionDenied("The key *** is restricted.")) {
            try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
        }
    }

    func test読めない2xx応答はmalformedResponse() async {
        for body in ["", "not json", "[1,2]", #"{"places": "oops"}"#] {
            let transport = RecordingTransport(json: body)
            do {
                _ = try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
                XCTFail("expected malformedResponse for \(body)")
            } catch let PlacesError.malformedResponse(message) {
                XCTAssertFalse(message.isEmpty)
            } catch {
                XCTFail("wrong error \(error) for \(body)")
            }
        }
        let hours = RecordingTransport(json: "garbage")
        do {
            _ = try await client(hours).openingHours(placeID: "ChIJ_x")
            XCTFail("expected malformedResponse")
        } catch PlacesError.malformedResponse {
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func test通信そのものの失敗はそのまま伝わる() async {
        let transport = RecordingTransport([.failure(StubFailure(tag: "offline"))])
        do {
            _ = try await client(transport).searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500)
            XCTFail("expected a throw")
        } catch let e as StubFailure {
            XCTAssertEqual(e, StubFailure(tag: "offline"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testキーが空なら_リクエストを出さずにmissingAPIKey() async {
        for key in ["", "   ", "\n"] {
            let transport = RecordingTransport([])
            let c = client(transport, key: key)
            await expectError(.missingAPIKey) { try await c.searchBranches(chainName: "ダイソー", near: fujisawa, radiusMeters: 500) }
            await expectError(.missingAPIKey) { try await c.openingHours(placeID: "ChIJ_x") }
            XCTAssertTrue(transport.requests.isEmpty, "no request may be sent without a key")
        }
    }

    func testPlacesErrorは日本語の説明を持つ() {
        let all: [PlacesError] = [.missingAPIKey, .badRequest("a"), .permissionDenied("b"), .notFound("c"), .rateLimited, .server(500), .malformedResponse("d")]
        for e in all { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
        XCTAssertTrue(PlacesError.server(503).errorDescription?.contains("503") == true)
    }

    // MARK: openingHours: request

    func test営業時間リクエストは_URL_メソッド_ヘッダが仕様どおり() async throws {
        let transport = RecordingTransport(json: "{}")
        _ = try await client(transport).openingHours(placeID: "ChIJ_daiso-near~1")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, "https://places.googleapis.com/v1/places/ChIJ_daiso-near~1?languageCode=ja&regionCode=JP")
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.headers, [
            "X-Goog-Api-Key": testKey,
            "X-Goog-FieldMask": "regularOpeningHours,currentOpeningHours,timeZone",
        ])
    }

    func test場所IDはパーセントエンコードされ_resource名の接頭辞は外される() async throws {
        let transport = RecordingTransport([
            .success(HTTPResponse(status: 200, body: Data("{}".utf8))),
            .success(HTTPResponse(status: 200, body: Data("{}".utf8))),
        ])
        let c = client(transport)
        _ = try await c.openingHours(placeID: "a/b?c d#é")
        _ = try await c.openingHours(placeID: "places/ChIJ_abc")

        XCTAssertEqual(transport.requests[0].url,
                       "https://places.googleapis.com/v1/places/a%2Fb%3Fc%20d%23%C3%A9?languageCode=ja&regionCode=JP")
        XCTAssertEqual(transport.requests[1].url,
                       "https://places.googleapis.com/v1/places/ChIJ_abc?languageCode=ja&regionCode=JP")
    }

    func test場所IDが空ならbadRequestでリクエストしない() async {
        let transport = RecordingTransport([])
        await expectError(.badRequest("placeID が空です")) { try await client(transport).openingHours(placeID: " ") }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: openingHours: mapping

    private func hours(_ json: String) async throws -> OpeningHours? {
        try await client(RecordingTransport(json: json)).openingHours(placeID: "ChIJ_x")
    }

    func test毎日10時から21時() async throws {
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21))
        let h = try await hours(json)
        XCTAssertEqual(h, OpeningHours(timeZoneID: "Asia/Tokyo", isAlwaysOpen: false, weekly: ordinaryWeekly, specialDays: []))
    }

    func test日曜だけ営業時間が違う() async throws {
        var periods = dailyPeriods(openHour: 10, closeHour: 21)
        periods[0] = period(open: point(0, 11, 30), close: point(0, 20, 0))
        let h = try await hours(hoursJSON(regular: periods))
        XCTAssertEqual(h?.weekly.first, weekly(0, 11 * 60 + 30, 0, 20 * 60))
        XCTAssertEqual(h?.weekly.dropFirst().map { $0 }, Array(ordinaryWeekly.dropFirst()))
    }

    func test24時間営業は_isAlwaysOpen() async throws {
        let json = #"{"regularOpeningHours":{"openNow":true,"periods":[{"open":{"day":0,"hour":0,"minute":0}}]},"timeZone":{"id":"Asia/Tokyo"}}"#
        let h = try await hours(json)
        XCTAssertEqual(h, OpeningHours(timeZoneID: "Asia/Tokyo", isAlwaysOpen: true, weekly: [], specialDays: []))
    }

    func test0を省いた24時間営業の表現も読める() async throws {
        // proto3 の JSON は 0 を省く: day も hour も minute も無い。
        let json = #"{"regularOpeningHours":{"periods":[{"open":{}}]}}"#
        let h = try await hours(json)
        XCTAssertEqual(h?.isAlwaysOpen, true)
    }

    func test閉店のない枠が日曜0時以外なら24時間営業とは読まない() async throws {
        let json = hoursJSON(regular: [period(open: point(2, 9, 0), close: nil)])
        let h = try await hours(json)
        XCTAssertNil(h, "an open-ended period that is not the 24/7 marker is unusable")
    }

    func test金曜18時から土曜2時は日をまたぐ枠になる() async throws {
        var periods = dailyPeriods(openHour: 10, closeHour: 21)
        periods[5] = period(open: point(5, 18, 0), close: point(6, 2, 0))
        let h = try await hours(hoursJSON(regular: periods))
        XCTAssertEqual(h?.weekly.first { $0.openDay == 5 }, weekly(5, 18 * 60, 6, 2 * 60))
        XCTAssertEqual(h?.weekly.count, 7)
    }

    func test順不同の枠は曜日と開店時刻の順に並べ直す() async throws {
        let periods = [
            period(open: point(3, 15, 0), close: point(3, 21, 0)),
            period(open: point(3, 9, 0), close: point(3, 12, 0)),
            period(open: point(1, 10, 0), close: point(1, 21, 0)),
        ]
        let h = try await hours(hoursJSON(regular: periods))
        XCTAssertEqual(h?.weekly, [weekly(1, 600, 1, 1260), weekly(3, 540, 3, 720), weekly(3, 900, 3, 1260)])
    }

    func test不正な枠は捨てて_残りは使う() async throws {
        let periods = [
            period(open: point(1, 10, 0), close: point(1, 21, 0)),
            period(open: point(2, 25, 0), close: point(2, 21, 0)),    // 25 時
            period(open: point(7, 10, 0), close: point(7, 21, 0)),    // 曜日 7
            period(open: point(3, 10, 0), close: point(3, 10, 0)),    // 開店 == 閉店（同日）
            period(open: point(4, 10, 0), close: point(4, 9, 0)),     // 同日で閉店が先
            period(open: point(5, 10, 0), close: nil),                // close なし
        ]
        let h = try await hours(hoursJSON(regular: periods))
        XCTAssertEqual(h?.weekly, [weekly(1, 600, 1, 1260)])
    }

    func test閉店が翌日0時の枠は24時閉店として保たれる() async throws {
        let periods = [period(open: point(6, 10, 0), close: point(0, 0, 0))]
        let h = try await hours(hoursJSON(regular: periods))
        XCTAssertEqual(h?.weekly, [weekly(6, 600, 0, 0)])
    }

    func test年始の休みは_枠のない特別日になる() async throws {
        // 2026-12-30(水) から 7 日分。1/1(金) は枠が無い = 終日休み。
        let current = [
            period(open: point(3, 10, 0, date: "2026-12-30"), close: point(3, 21, 0, date: "2026-12-30")),
            period(open: point(4, 10, 0, date: "2026-12-31"), close: point(4, 21, 0, date: "2026-12-31")),
            period(open: point(6, 10, 0, date: "2027-01-02"), close: point(6, 21, 0, date: "2027-01-02")),
            period(open: point(0, 10, 0, date: "2027-01-03"), close: point(0, 21, 0, date: "2027-01-03")),
        ]
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: current, specialDates: ["2027-01-01"])
        let h = try await hours(json)
        XCTAssertEqual(h?.weekly, ordinaryWeekly)
        XCTAssertEqual(h?.specialDays, [SpecialDay(date: CalendarDay(year: 2027, month: 1, day: 1), periods: [])])
    }

    func test短縮営業の特別日は_その日の枠だけを持つ() async throws {
        let current = [
            period(open: point(3, 10, 0, date: "2026-12-30"), close: point(3, 21, 0, date: "2026-12-30")),
            period(open: point(4, 10, 0, date: "2026-12-31"), close: point(4, 18, 0, date: "2026-12-31")),
        ]
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: current, specialDates: ["2026-12-31"])
        let h = try await hours(json)
        XCTAssertEqual(h?.specialDays, [SpecialDay(date: CalendarDay(year: 2026, month: 12, day: 31), periods: [DayPeriod(openMinute: 600, closeMinute: 1080)])])
    }

    func test特別日に複数の枠があれば開店順に並ぶ() async throws {
        let current = [
            period(open: point(4, 17, 0, date: "2026-12-31"), close: point(4, 21, 0, date: "2026-12-31")),
            period(open: point(4, 10, 0, date: "2026-12-31"), close: point(4, 14, 0, date: "2026-12-31")),
        ]
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: current, specialDates: ["2026-12-31"])
        let h = try await hours(json)
        XCTAssertEqual(h?.specialDays.first?.periods, [DayPeriod(openMinute: 600, closeMinute: 840), DayPeriod(openMinute: 1020, closeMinute: 1260)])
    }

    func test特別日の閉店が翌日なら1440を足す() async throws {
        // close.date が翌日（年越しの深夜営業）。
        let withDate = [period(open: point(4, 18, 0, date: "2026-12-31"), close: point(5, 2, 0, date: "2027-01-01"))]
        let h1 = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: withDate, specialDates: ["2026-12-31"]))
        XCTAssertEqual(h1?.specialDays.first?.periods, [DayPeriod(openMinute: 1080, closeMinute: 1440 + 120)])

        // close に date が無いときは曜日の差（木 → 金 = 1 日）。
        let openDate = #"{"day": 4, "hour": 18, "minute": 0, "date": {"year": 2026, "month": 12, "day": 31}}"#
        let noCloseDate = [period(open: openDate, close: point(5, 2, 0))]
        let h2 = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: noCloseDate, specialDates: ["2026-12-31"]))
        XCTAssertEqual(h2?.specialDays.first?.periods, [DayPeriod(openMinute: 1080, closeMinute: 1440 + 120)])

        // 24:00 閉店（翌日 0 時）は 1440。
        let midnight = [period(open: point(4, 10, 0, date: "2026-12-31"), close: point(5, 0, 0, date: "2027-01-01"))]
        let h3 = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: midnight, specialDates: ["2026-12-31"]))
        XCTAssertEqual(h3?.specialDays.first?.periods, [DayPeriod(openMinute: 600, closeMinute: 1440)])
    }

    func test特別日でない日の枠は特別日に入れない() async throws {
        // 12/30 の枠は特別日 12/31 のものではない。前日に開いて翌日に閉まる枠も、開く日のものとして扱う。
        let current = [
            period(open: point(3, 18, 0, date: "2026-12-30"), close: point(4, 2, 0, date: "2026-12-31")),
            period(open: point(4, 10, 0, date: "2026-12-31"), close: point(4, 18, 0, date: "2026-12-31")),
        ]
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: current, specialDates: ["2026-12-31"])
        let h = try await hours(json)
        XCTAssertEqual(h?.specialDays.first?.periods, [DayPeriod(openMinute: 600, closeMinute: 1080)])
    }

    func test同じ特別日が重複していても1件にまとめ_日付順に並べる() async throws {
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21),
                             current: [period(open: point(3, 10, 0, date: "2026-12-30"), close: point(3, 21, 0, date: "2026-12-30"))],
                             specialDates: ["2027-01-02", "2027-01-01", "2027-01-02"])
        let h = try await hours(json)
        XCTAssertEqual(h?.specialDays.map(\.date), [CalendarDay(year: 2027, month: 1, day: 1), CalendarDay(year: 2027, month: 1, day: 2)])
    }

    func test存在しない日付の特別日は捨てる() async throws {
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21),
                             current: [period(open: point(3, 10, 0, date: "2026-12-30"), close: point(3, 21, 0, date: "2026-12-30"))],
                             specialDates: ["2027-02-30"])
        let h = try await hours(json)
        XCTAssertEqual(h?.specialDays, [])
    }

    func test枠に日付が1つも付いていなければ_特別日は読めないので捨てる() async throws {
        // 日付無しの枠から「その日は枠なし = 休み」と読むと誤って休みにしてしまう。
        let undated = dailyPeriods(openHour: 10, closeHour: 21)
        let json = hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), current: undated, specialDates: ["2027-01-01"])
        let h = try await hours(json)
        XCTAssertEqual(h?.weekly, ordinaryWeekly)
        XCTAssertEqual(h?.specialDays, [])
    }

    func test営業時間が無い場所はnil() async throws {
        let none1 = try await hours("{}")
        XCTAssertNil(none1)
        let none2 = try await hours(#"{"timeZone":{"id":"Asia/Tokyo"}}"#)
        XCTAssertNil(none2)
        let none3 = try await hours(#"{"regularOpeningHours":{"periods":[]},"currentOpeningHours":{"periods":[]}}"#)
        XCTAssertNil(none3)
        // 現在の営業時間だけがあっても、通常営業時間も特別日も無ければ「営業時間なし」。
        let none4 = try await hours(hoursJSON(regular: nil, current: dailyPeriods(openHour: 10, closeHour: 21)))
        XCTAssertNil(none4)
    }

    func test通常の営業時間が無く特別日だけある場所はnil() async throws {
        // 特別日だけ持たせると、評価器は「特別日以外は終日休み」と読んで通知を止めてしまう。
        // 営業時間不明（nil）なら D4 で営業中扱いになるので、そちらに倒す。
        let json = hoursJSON(regular: nil, current: [], specialDates: ["2027-01-01"])
        let h = try await hours(json)
        XCTAssertNil(h)
    }

    func testタイムゾーンが無ければAsiaTokyo() async throws {
        let h = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), timeZone: nil))
        XCTAssertEqual(h?.timeZoneID, "Asia/Tokyo")
    }

    func testタイムゾーンはあればそのまま使い_不明なidはAsiaTokyoにする() async throws {
        let osaka = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), timeZone: "Asia/Seoul"))
        XCTAssertEqual(osaka?.timeZoneID, "Asia/Seoul")
        let bogus = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), timeZone: "Mars/Olympus"))
        XCTAssertEqual(bogus?.timeZoneID, "Asia/Tokyo")
        let blank = try await hours(hoursJSON(regular: dailyPeriods(openHour: 10, closeHour: 21), timeZone: " "))
        XCTAssertEqual(blank?.timeZoneID, "Asia/Tokyo")
    }

    func test営業時間の本物に近い応答を丸ごと読める() async throws {
        // 余計な項目（weekdayDescriptions, openNow, nextCloseTime …）があっても読める。
        let json = """
        {
          "regularOpeningHours": {
            "openNow": true,
            "periods": [
              {"open": {"day": 0, "hour": 10, "minute": 0}, "close": {"day": 0, "hour": 21, "minute": 0}},
              {"open": {"day": 1, "hour": 10, "minute": 0}, "close": {"day": 1, "hour": 21, "minute": 0}}
            ],
            "weekdayDescriptions": ["月曜日: 10時00分～21時00分", "日曜日: 10時00分～21時00分"],
            "nextCloseTime": "2026-10-05T12:00:00Z"
          },
          "currentOpeningHours": {
            "openNow": true,
            "periods": [
              {"open": {"day": 1, "hour": 10, "minute": 0, "date": {"year": 2026, "month": 10, "day": 5}},
               "close": {"day": 1, "hour": 21, "minute": 0, "date": {"year": 2026, "month": 10, "day": 5}}}
            ],
            "weekdayDescriptions": ["月曜日: 10時00分～21時00分"],
            "secondaryHoursType": "DELIVERY"
          },
          "timeZone": {"id": "Asia/Tokyo", "version": "2025b"}
        }
        """
        let h = try await hours(json)
        XCTAssertEqual(h, OpeningHours(timeZoneID: "Asia/Tokyo", isAlwaysOpen: false,
                                       weekly: [weekly(0, 600, 0, 1260), weekly(1, 600, 1, 1260)], specialDays: []))
    }
}
