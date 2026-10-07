import XCTest
@testable import EkiCore

// 結合テスト（phase 3）。AppEnvironment が組むのと同じ配線を、実物の部品だけで組んで通す:
//   偽の HTTPTransport（実際の Places (New) の JSON）→ PlacesClient → ChainRegistrar → LedgerRepository(InMemory)
//   → TaskImporter / importItems → StationEntryHandler（偽の NotificationPosting）→ MonitoringPlanner
// 各テスト名は利用者から見えるルール。時刻はすべて固定（Asia/Tokyo）。2026-10-05 は月曜。

// MARK: - 固定データ

private enum E2E {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let apiKey = "TEST-KEY-not-a-real-key"

    /// JST の暦から作る（2026 年固定）。
    static func jst(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// 月曜 18:42（仕様の例の時刻）。
    static let monday1842 = jst(10, 5, 18, 42)
    /// 店登録をした日時（日曜の昼）。
    static let registeredAt = jst(10, 4, 12)

    static let fujisawa = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!,
        name: "藤沢駅", coordinate: Coordinate(latitude: 35.3388, longitude: 139.4900)
    )
    static let tsujido = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!,
        name: "辻堂駅", coordinate: Coordinate(latitude: 35.3376, longitude: 139.4486)
    )
    /// 藤沢駅の真北 780 m。ダイソー 藤沢店（藤沢駅の真北 319.9 m）はこの 2 駅の間にあり、
    /// 藤沢駅から 319.9 m・この駅から 460.1 m（徒歩 4 分と 6 分）。
    static let hommachi = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000E003")!,
        name: "藤沢本町駅", coordinate: fujisawa.coordinate.moved(northMeters: 780)
    )

    static func fix(_ at: Coordinate, accuracy: Double = 35, time: Date) -> LocationFix {
        LocationFix(coordinate: at, horizontalAccuracy: accuracy, timestamp: time)
    }
}

private extension Coordinate {
    /// 小さな距離用の平面近似（ここでの誤差は 1 cm 未満）。fixture の位置決めにだけ使い、判定側は haversine。
    func moved(northMeters: Double = 0, eastMeters: Double = 0) -> Coordinate {
        let metersPerDegreeLat = 6_371_008.8 * .pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(latitude * .pi / 180)
        return Coordinate(
            latitude: latitude + northMeters / metersPerDegreeLat,
            longitude: longitude + eastMeters / metersPerDegreeLon
        )
    }
}

// MARK: - Places (New) の JSON

/// 実際の応答と同じく、0 や空の項目は省く（proto3 JSON。日曜 = day 0・0 分は載らない）。
private enum PlacesJSON {
    private static func point(day: Int, hour: Int, minute: Int, date: (Int, Int, Int)? = nil) -> String {
        var parts: [String] = []
        if day != 0 { parts.append("\"day\": \(day)") }
        if hour != 0 { parts.append("\"hour\": \(hour)") }
        if minute != 0 { parts.append("\"minute\": \(minute)") }
        if let d = date { parts.append("\"date\": {\"year\": \(d.0), \"month\": \(d.1), \"day\": \(d.2)}") }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    static func period(openDay: Int, open: (Int, Int), closeDay: Int, close: (Int, Int),
                       openDate: (Int, Int, Int)? = nil, closeDate: (Int, Int, Int)? = nil) -> String {
        "{\"open\": \(point(day: openDay, hour: open.0, minute: open.1, date: openDate)), "
            + "\"close\": \(point(day: closeDay, hour: close.0, minute: close.1, date: closeDate))}"
    }

    /// 毎日 open〜close。close が open 以前なら翌日の閉店（深夜営業）。
    static func dailyPeriods(open: (Int, Int), close: (Int, Int)) -> [String] {
        let overnight = (close.0, close.1) <= (open.0, open.1)
        return (0...6).map { d in
            period(openDay: d, open: open, closeDay: overnight ? (d + 1) % 7 : d, close: close)
        }
    }

    /// regularOpeningHours だけ（特別日なし）。
    static func hours(_ periods: [String], timeZone: String? = "Asia/Tokyo") -> String {
        let tz = timeZone.map { ", \"timeZone\": {\"id\": \"\($0)\"}" } ?? ""
        return "{\"regularOpeningHours\": {\"periods\": [\(periods.joined(separator: ", "))]}, "
            + "\"currentOpeningHours\": {\"periods\": [\(periods.joined(separator: ", "))]}\(tz)}"
    }

    /// 毎日 open〜close の店で、10 月の特別日だけ休み（`closed`）または別の時間（`shortened`）。
    /// currentOpeningHours は本物と同じく「10/5（月）から向こう 7 日の実際の枠（date 付き）」: 休みの日の枠は無く、
    /// 特別日は specialDays に日付だけが載る。
    static func hoursWithSpecialDays(
        open: (Int, Int) = (10, 0), close: (Int, Int) = (21, 0),
        closed: Set<Int> = [], shortened: [Int: ((Int, Int), (Int, Int))] = [:]
    ) -> String {
        let regular = dailyPeriods(open: open, close: close)
        let windowStartDay = 5, windowStartWeekday = 1   // 2026-10-05 は月曜
        var current: [String] = []
        for offset in 0..<7 {
            let d = windowStartDay + offset
            if closed.contains(d) { continue }
            let weekday = (windowStartWeekday + offset) % 7
            let (o, c) = shortened[d] ?? (open, close)
            let overnight = (c.0, c.1) <= (o.0, o.1)
            current.append(period(
                openDay: weekday, open: o, closeDay: overnight ? (weekday + 1) % 7 : weekday, close: c,
                openDate: (2026, 10, d), closeDate: (2026, 10, overnight ? d + 1 : d)
            ))
        }
        let special = (Array(closed) + Array(shortened.keys)).sorted()
            .map { "{\"date\": {\"year\": 2026, \"month\": 10, \"day\": \($0)}}" }
        return "{\"regularOpeningHours\": {\"periods\": [\(regular.joined(separator: ", "))]}, "
            + "\"currentOpeningHours\": {\"periods\": [\(current.joined(separator: ", "))], "
            + "\"specialDays\": [\(special.joined(separator: ", "))]}, "
            + "\"timeZone\": {\"id\": \"Asia/Tokyo\"}}"
    }

    static func error(code: Int, status: String, message: String) -> String {
        "{\"error\": {\"code\": \(code), \"message\": \"\(message)\", \"status\": \"\(status)\"}}"
    }
}

/// 偽の Places サーバが持つ場所。
private struct FakePlace {
    var id: String
    var name: String
    var coordinate: Coordinate
    /// places/{id} の応答。nil なら 404。
    var hoursJSON: String?
}

private enum Catalog {
    static let daisoFujisawaID = "ChIJd8BlQ2BZwokRAFUEcm_daisoF1"
    static let daisoTsujidoID = "ChIJN1t_tDeuEmsRUsoyG83_daisoT2"
    static let daisoSouthID = "ChIJrTLr-GyuEmsRBfy61i5_daisoS3"
    static let mujiFujisawaID = "ChIJ0T2NLikpdTERKxE8d61_mujiF4"
    static let seriaFujisawaID = "ChIJ3S-JXmauEmsRUcIaWtf_seriaF5"

    static let h10to21 = PlacesJSON.hours(PlacesJSON.dailyPeriods(open: (10, 0), close: (21, 0)))
    /// 毎日 10:00 開店・翌 1:00 閉店（深夜営業）。
    static let h10to25 = PlacesJSON.hours(PlacesJSON.dailyPeriods(open: (10, 0), close: (1, 0)))
    /// 10/5（月）だけ臨時休業の無印良品。窓は 10/5（月=1）から 7 日。
    static let hMujiMondayOff = PlacesJSON.hoursWithSpecialDays(closed: [5])

    /// ダイソー 藤沢店は藤沢駅の真北 319.9 m（≒320 m → 徒歩 4 分）。
    static let daisoFujisawaAt = E2E.fujisawa.coordinate.moved(northMeters: 319.9)

    static func standard(daisoName: String = "ダイソー 藤沢店") -> [FakePlace] {
        [
            FakePlace(id: daisoFujisawaID, name: daisoName, coordinate: daisoFujisawaAt, hoursJSON: h10to21),
            // 辻堂駅の真東 200 m（徒歩 3 分）。深夜営業。
            FakePlace(id: daisoTsujidoID, name: "ダイソー 辻堂店",
                      coordinate: E2E.tsujido.coordinate.moved(eastMeters: 200), hoursJSON: h10to25),
            // 藤沢駅の真南 800 m: 検索半径 500 m の外（API は返すが、こちらで落とす: D12）。
            FakePlace(id: daisoSouthID, name: "ダイソー 藤沢南口店",
                      coordinate: E2E.fujisawa.coordinate.moved(northMeters: -800), hoursJSON: h10to21),
            // 藤沢駅の真北 190 m（徒歩 3 分）。10/5 は臨時休業。
            FakePlace(id: mujiFujisawaID, name: "無印良品 ミナパーク藤沢",
                      coordinate: E2E.fujisawa.coordinate.moved(northMeters: 190), hoursJSON: hMujiMondayOff),
        ]
    }

    /// どの検索にも混ざってくる、別チェーンの近所の店（名前の突き合わせで落とす: D12）。
    static let noise = FakePlace(
        id: seriaFujisawaID, name: "セリア 藤沢店",
        coordinate: E2E.fujisawa.coordinate.moved(eastMeters: 100), hoursJSON: h10to21
    )
}

// MARK: - 偽のトランスポート

/// Places (New) の 2 つのエンドポイントだけを話す偽のサーバ。リクエストはすべて記録する。
private final class FakePlacesServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let catalog: [FakePlace]
    private var _requests: [HTTPRequest] = []
    private var _failAllStatus: Int?
    private var _failHoursStatus: Int?
    private var _hoursOverrides: [String: String] = [:]

    init(catalog: [FakePlace]) { self.catalog = catalog }

    var requests: [HTTPRequest] { lock.withLock { _requests } }
    /// 全リクエストをこのステータスで失敗させる（キーの制限ミスなど）。nil で復旧。
    var failAllStatus: Int? {
        get { lock.withLock { _failAllStatus } }
        set { lock.withLock { _failAllStatus = newValue } }
    }
    /// 営業時間の取得だけ失敗させる。
    var failHoursStatus: Int? {
        get { lock.withLock { _failHoursStatus } }
        set { lock.withLock { _failHoursStatus = newValue } }
    }

    /// 店が営業時間を変えた、をつくる（週 1 更新のテスト用）。
    func setHours(placeID: String, json: String) { lock.withLock { _hoursOverrides[placeID] = json } }

    var searches: [HTTPRequest] { requests.filter { $0.method == "POST" } }
    var hoursCalls: [HTTPRequest] { requests.filter { $0.method == "GET" } }
    /// 検索に使われた textQuery（順番どおり）。
    var searchedQueries: [String] { searches.compactMap { Self.json($0.body)?["textQuery"] as? String } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await Task.yield()   // 本物の通信と同じく中断点を作る
        lock.withLock { _requests.append(request) }
        // 本物のサーバと同じく、キーが無ければ 403。
        guard request.headers["X-Goog-Api-Key"] == E2E.apiKey else {
            return Self.errorResponse(403, "PERMISSION_DENIED", "API key not valid.")
        }
        if let status = failAllStatus { return Self.failure(status) }
        if request.method == "POST" { return search(request) }
        if let status = failHoursStatus { return Self.failure(status) }
        return hours(request)
    }

    private static func failure(_ status: Int) -> HTTPResponse {
        errorResponse(status, status == 403 ? "PERMISSION_DENIED" : "UNKNOWN",
                      "Requests from this iOS client application <empty> are blocked.")
    }

    private static func errorResponse(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(PlacesJSON.error(code: status, status: code, message: message).utf8))
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// textQuery を名前に含む場所を、バイアス中心から 3 km 以内で返す（本物の検索は曖昧に広めに返す）。
    /// 一致する場所が無ければ `{}`（places キーごと無い）。別チェーンのノイズ 1 件は必ず混ぜる。
    private func search(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = Self.json(request.body),
              let query = body["textQuery"] as? String,
              let bias = (body["locationBias"] as? [String: Any])?["circle"] as? [String: Any],
              let center = bias["center"] as? [String: Any],
              let lat = center["latitude"] as? Double, let lon = center["longitude"] as? Double else {
            return Self.errorResponse(400, "INVALID_ARGUMENT", "bad request")
        }
        let origin = Coordinate(latitude: lat, longitude: lon)
        let queryKey = ChainName.key(query)
        var hits = catalog.filter {
            ChainName.key($0.name).contains(queryKey) && origin.distance(to: $0.coordinate) <= 3000
        }
        if !hits.isEmpty { hits.append(Catalog.noise) }
        guard !hits.isEmpty else { return HTTPResponse(status: 200, body: Data("{}".utf8)) }
        let places = hits.map { p in
            "{\"id\": \"\(p.id)\", \"displayName\": {\"text\": \"\(p.name)\", \"languageCode\": \"ja\"}, "
                + "\"location\": {\"latitude\": \(p.coordinate.latitude), \"longitude\": \(p.coordinate.longitude)}}"
        }
        return HTTPResponse(status: 200, body: Data("{\"places\": [\(places.joined(separator: ", "))]}".utf8))
    }

    private func hours(_ request: HTTPRequest) -> HTTPResponse {
        guard let url = URL(string: request.url) else { return Self.errorResponse(400, "INVALID_ARGUMENT", "bad url") }
        let id = url.lastPathComponent   // URL が percent-decode した最後のパス要素
        let override = lock.withLock { _hoursOverrides[id] }
        guard let place = (catalog + [Catalog.noise]).first(where: { $0.id == id }), let body = override ?? place.hoursJSON else {
            return Self.errorResponse(404, "NOT_FOUND", "Place not found")
        }
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

private final class RecordingPoster: NotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [NotificationContent] = []
    var posted: [NotificationContent] { lock.withLock { _posted } }

    func post(_ content: NotificationContent) async throws {
        await Task.yield()
        lock.withLock { _posted.append(content) }
    }
}

// MARK: - 配線（AppEnvironment と同じ組み方）

private struct World {
    let server: FakePlacesServer
    let places: PlacesClient
    let store: InMemoryLedgerStore
    let repo: LedgerRepository
    let registrar: ChainRegistrar
    let poster: RecordingPoster
    let handler: StationEntryHandler

    init(
        stations: [Station] = [E2E.fujisawa, E2E.tsujido],
        catalog: [FakePlace] = Catalog.standard(),
        settings: Settings = Settings(),
        deviceTimeZone: TimeZone = E2E.tokyo
    ) async throws {
        server = FakePlacesServer(catalog: catalog)
        places = PlacesClient(apiKey: E2E.apiKey, transport: server)
        store = InMemoryLedgerStore(Ledger(stations: stations, settings: settings))
        repo = try await LedgerRepository.open(store: store)
        registrar = ChainRegistrar(repository: repo, search: places, hours: places, now: { E2E.registeredAt })
        poster = RecordingPoster()
        handler = StationEntryHandler(repository: repo, poster: poster, timeZone: { deviceTimeZone })
    }

    var ledger: Ledger { get async { await repo.snapshot() } }

    /// AppModel.addTask と同じ: 台帳に足し、未登録のチェーンだけ店登録を走らせる（D11）。
    @discardableResult
    func addTask(_ store: String, _ item: String, at now: Date = E2E.registeredAt) async throws -> [RegistrationReport] {
        _ = try await repo.addTask(store: store, item: item, now: now)
        return await registrar.ensureRegistered(chains: [store])
    }

    /// 入域。位置はその駅の中心から 40 m の点。
    @discardableResult
    func enter(_ station: Station, at date: Date) async throws -> JudgeOutcome? {
        let fix = E2E.fix(station.coordinate.moved(northMeters: 40), time: date)
        return try await handler.handle(TriggerEvent(stationID: station.id, firedAt: date, location: fix))
    }

    func plan(at now: Date = E2E.monday1842) async -> MonitoringPlan {
        MonitoringPlanner.plan(ledger: await repo.snapshot(), now: now, deviceLocation: nil)
    }
}


// XCTest の XCTAssert は async の autoclosure を受けないので、台帳（actor）を読む比較用の薄い版。
private func eq<T: Equatable>(
    _ actual: @autoclosure () async throws -> T, _ expected: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let a = try await actual()
    let e = try await expected()
    XCTAssertEqual(a, e, message(), file: file, line: line)
}

private func yes(
    _ condition: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async rethrows {
    let value = try await condition()
    XCTAssertTrue(value, message(), file: file, line: line)
}

private func unwrap<T>(
    _ value: @autoclosure () async throws -> T?,
    file: StaticString = #filePath, line: UInt = #line
) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v, file: file, line: line)
}

// MARK: - シナリオ

final class EndToEndTests: XCTestCase {

    // (1) 仕様の例を端末の台帳まで通す
    func test_01_仕様の例_藤沢駅でダイソーのフィルムと電池が1通にまとまる() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let reports = try await w.addTask("ダイソー", "電池")
        XCTAssertTrue(reports.isEmpty, "2 つ目のタスクでは登録済みのチェーンを再検索しない")

        let ledger = await w.ledger
        XCTAssertEqual(ledger.registeredChains, ["ダイソー"])
        // 検索は有効な 2 駅ぶんの 2 回。営業時間は新しい支店 2 件ぶんの 2 回（500 m 外とノイズは取らない）。
        XCTAssertEqual(w.server.searchedQueries, ["ダイソー", "ダイソー"])
        XCTAssertEqual(w.server.hoursCalls.count, 2)
        XCTAssertEqual(Set(ledger.branches.map(\.id)), [Catalog.daisoFujisawaID, Catalog.daisoTsujidoID])

        let branch = try XCTUnwrap(ledger.branches.first { $0.id == Catalog.daisoFujisawaID })
        let meters = try XCTUnwrap(branch.distance(to: E2E.fujisawa.id))
        XCTAssertEqual(meters, 320, accuracy: 0.5)
        XCTAssertLessThanOrEqual(meters, 320, "ちょうど 320 m を超えると徒歩 5 分になる")
        XCTAssertNil(branch.distance(to: E2E.tsujido.id))
        XCTAssertEqual(branch.hoursFetchedAt, E2E.registeredAt)
        XCTAssertEqual(branch.hours?.timeZoneID, "Asia/Tokyo")

        let outcome = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(result.record.result, .notified)
        XCTAssertEqual(w.poster.posted.count, 1)
        let note = try XCTUnwrap(w.poster.posted.first)
        XCTAssertEqual(note.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池")
        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.stationID, E2E.fujisawa.id)
        XCTAssertEqual(Set(note.taskIDs), Set(ledger.tasks.map(\.id)))

        // 履歴が台帳に残り、発火の位置と時刻が入っている（M1 の完了条件）。
        let history = await w.ledger.history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].stationName, "藤沢駅")
        XCTAssertEqual(history[0].branchIDs, [Catalog.daisoFujisawaID])
        XCTAssertEqual(history[0].firedAt, E2E.monday1842)
        XCTAssertEqual(history[0].location?.horizontalAccuracy, 35)
        XCTAssertEqual(w.store.stored.history, history, "保存された台帳にも同じ履歴がある")

        // 鍵はヘッダだけ。URL・本文のどこにも無い。
        for r in w.server.requests {
            XCTAssertEqual(r.headers["X-Goog-Api-Key"], E2E.apiKey)
            XCTAssertFalse(r.url.contains(E2E.apiKey))
            XCTAssertFalse(String(decoding: r.body ?? Data(), as: UTF8.self).contains(E2E.apiKey))
        }
        XCTAssertTrue(w.server.requests.allSatisfy { $0.url.hasPrefix("https://places.googleapis.com/v1/") })
    }

    // (2) 閉店 30 分前を過ぎたら出さない。しかも「今日」を消費しない
    func test_02_20時30分を過ぎると営業時間外で抑制し_今日は消費せず_翌日18時に通知する() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        try await w.addTask("ダイソー", "電池")

        let late = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 20, 45))
        XCTAssertEqual(late?.record.result, .suppressedClosed)
        XCTAssertNil(late?.notification)
        XCTAssertEqual(late?.record.detail, "ダイソー 藤沢店は閉店まで15分")
        let afterClose = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 22, 10))
        XCTAssertEqual(afterClose?.record.result, .suppressedClosed)
        XCTAssertEqual(afterClose?.record.detail, "ダイソー 藤沢店は営業時間外")
        let early = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 9, 30))
        XCTAssertEqual(early?.record.result, .suppressedClosed, "開店前も営業時間外")
        XCTAssertTrue(w.poster.posted.isEmpty)

        // 抑制は何度出ても「今日通知済」にならない: 同じ日の営業中に入れば通知される。
        let next = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 18, 0))
        XCTAssertEqual(next?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池"])

        let results = await w.ledger.history.map(\.result)
        XCTAssertEqual(results, [.suppressedClosed, .suppressedClosed, .suppressedClosed, .notified])
    }

    func test_02b_閉店30分前ちょうどは通知し_1秒過ぎると抑制する() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let late = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 20, 30, 1))
        XCTAssertEqual(late?.record.result, .suppressedClosed)
        XCTAssertEqual(late?.record.detail, "ダイソー 藤沢店は閉店まで29分")
        let exact = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 20, 30, 0))
        XCTAssertEqual(exact?.record.result, .notified, "ちょうど 30 分残りは足りる（>=）")
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム"])
    }

    // (3) 駅ごとに 1 日 1 回
    func test_03_同じ日の2回目の入域は今日通知済で抑制し_別の駅なら通知する() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        try await w.addTask("ダイソー", "電池")

        let first = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(first?.record.result, .notified)
        let second = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 19, 30))
        XCTAssertEqual(second?.record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertNil(second?.notification)
        XCTAssertEqual(second?.record.detail, "今日 18:42 に通知済")
        XCTAssertEqual(second?.record.taskIDs.count, 2, "抑制でも、通知したはずだったタスクが履歴に残る")

        let other = try await w.enter(E2E.tsujido, at: E2E.jst(10, 5, 19, 50))
        XCTAssertEqual(other?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.map(\.body), [
            "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池",
            "辻堂駅｜ダイソー 辻堂店（徒歩3分・翌1時まで）：フィルム、電池",
        ])
    }

    func test_03b_設定を全駅で1日1回にすると別の駅も抑制され_入域のたびにすると毎回通知する() async throws {
        let once = try await World(settings: Settings(frequency: .oncePerDay))
        try await once.addTask("ダイソー", "フィルム")
        _ = try await once.enter(E2E.fujisawa, at: E2E.monday1842)
        let other = try await once.enter(E2E.tsujido, at: E2E.jst(10, 5, 19, 50))
        XCTAssertEqual(other?.record.result, .suppressedAlreadyNotifiedToday)
        XCTAssertEqual(other?.record.detail, "今日 18:42 に通知済（藤沢駅）")

        let every = try await World(settings: Settings(frequency: .everyEntry))
        try await every.addTask("ダイソー", "フィルム")
        _ = try await every.enter(E2E.fujisawa, at: E2E.monday1842)
        _ = try await every.enter(E2E.fujisawa, at: E2E.jst(10, 5, 19, 0))
        XCTAssertEqual(every.poster.posted.count, 2)
    }

    // (4) 開いている店だけを載せ、落とした店は履歴に書く
    func test_04_開いているチェーンだけを1通に載せ_臨時休業のチェーンは履歴の詳細に名前を残す() async throws {
        let w = try await World(stations: [E2E.fujisawa])
        try await w.addTask("ダイソー", "フィルム")
        let reports = try await w.addTask("無印良品", "ファイルボックス")
        XCTAssertEqual(reports.first?.branchesKept, 1)

        // 無印良品は 10/5（月）が特別日（終日休み）。ダイソーは営業中。
        let muji = try await unwrap(await w.ledger.branches.first { $0.id == Catalog.mujiFujisawaID })
        XCTAssertEqual(muji.hours?.specialDays.map(\.date), [CalendarDay(year: 2026, month: 10, day: 5)])
        XCTAssertEqual(muji.hours?.specialDays.first?.periods, [])

        let outcome = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(result.record.result, .notified)
        XCTAssertEqual(w.poster.posted.count, 1)
        XCTAssertEqual(w.poster.posted[0].body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
        XCTAssertFalse(w.poster.posted[0].body.contains("無印"))
        XCTAssertEqual(result.record.detail, "除外: 無印良品（営業時間外）")
        XCTAssertEqual(result.record.branchIDs, [Catalog.daisoFujisawaID])
        let ledger = await w.ledger
        let shown = Set(result.record.taskIDs)
        XCTAssertEqual(ledger.tasks.filter { shown.contains($0.id) }.map(\.store), ["ダイソー"])
        XCTAssertEqual(ledger.tasks.filter { $0.store == "無印良品" }.first?.status, .pending, "落としたタスクは未完了のまま")

        // 翌日（火）は無印も営業。近い順（190 m が先）の 2 行になる。
        let next = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 18, 0))
        XCTAssertEqual(next?.record.result, .notified)
        XCTAssertEqual(w.poster.posted[1].body, """
            藤沢駅｜無印良品 ミナパーク藤沢（徒歩3分・21時まで）：ファイルボックス
            ダイソー 藤沢店（徒歩4分・21時まで）：フィルム
            """)
    }

    func test_04b_すべてのチェーンが閉まっていれば営業時間外で1行にまとめて抑制する() async throws {
        let w = try await World(stations: [E2E.fujisawa])
        try await w.addTask("ダイソー", "フィルム")
        try await w.addTask("無印良品", "ファイルボックス")
        let outcome = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 22, 0))
        XCTAssertEqual(outcome?.record.result, .suppressedClosed)
        XCTAssertEqual(outcome?.record.detail, "ダイソー 藤沢店は営業時間外、無印良品 ミナパーク藤沢は営業時間外")
        XCTAssertEqual(outcome?.record.taskIDs.count, 2)
        XCTAssertTrue(w.poster.posted.isEmpty)
    }

    // (5) 同じ支店を 2 駅から見る
    func test_05_同じ支店が2駅から見えたら最寄り駅を2つ持ち_徒歩分数は入った駅からの距離で出す() async throws {
        let w = try await World(stations: [E2E.fujisawa, E2E.hommachi])
        try await w.addTask("ダイソー", "フィルム")

        let ledger = await w.ledger
        XCTAssertEqual(ledger.branches.count, 1, "2 駅から見えても 1 件")
        let branch = try XCTUnwrap(ledger.branches.first)
        XCTAssertEqual(branch.id, Catalog.daisoFujisawaID)
        XCTAssertEqual(branch.nearestStations.count, 2)
        XCTAssertEqual(try XCTUnwrap(branch.distance(to: E2E.fujisawa.id)), 319.9, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(branch.distance(to: E2E.hommachi.id)), 460.1, accuracy: 0.5)
        XCTAssertEqual(w.server.hoursCalls.count, 1, "営業時間は支店ごとに 1 回だけ取る")

        _ = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        _ = try await w.enter(E2E.hommachi, at: E2E.jst(10, 5, 18, 55))
        XCTAssertEqual(w.poster.posted.map(\.body), [
            "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム",
            "藤沢本町駅｜ダイソー 藤沢店（徒歩6分・21時まで）：フィルム",
        ])
    }

    // (6) JSON 取込 → 店登録 → 通知
    func test_06_JSON取込は重複と不正行を除いて入り_未登録のチェーンだけ店登録して通知まで届く() async throws {
        let json = """
        {"version": 1, "items": [
          {"store": "ダイソー", "item": "フィルム", "source": "LINE:友人", "date": "2026-09-14"},
          {"store": "ダイソー", "item": "電池", "source": "LINE:友人", "date": "2026-09-20"},
          {"store": "ダイソー", "item": "フィルム", "source": "Notion:HQ"},
          {"store": "無印良品", "source": "Notion:HQ"},
          {"store": "セリア", "item": "付箋", "date": "2026/09/21"}
        ]}
        """
        let parsed = try TaskImporter.parse(Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8))
        XCTAssertEqual(parsed.items.count, 3)
        XCTAssertEqual(parsed.rejected.map(\.index), [3, 4], "品目なし・日付形式違いの 2 行だけが落ちる")

        let w = try await World()
        let summary = try await w.repo.importItems(parsed.items, now: E2E.registeredAt)
        XCTAssertEqual(summary.added.map(\.item), ["フィルム", "電池"])
        XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(summary.chainsNeedingRegistration, ["ダイソー"])
        XCTAssertEqual(summary.added.first?.source, "LINE:友人")
        XCTAssertEqual(summary.added.first?.sourceDate, CalendarDay(year: 2026, month: 9, day: 14))

        let reports = await w.registrar.ensureRegistered(chains: summary.chainsNeedingRegistration)
        XCTAssertEqual(reports.map(\.chainName), ["ダイソー"])
        XCTAssertEqual(reports.first?.branchesKept, 2)
        // 落とした行の無印良品・セリアは台帳にも検索にも現れない。
        await eq(await w.ledger.registeredChains, ["ダイソー"])
        XCTAssertEqual(Set(w.server.searchedQueries), ["ダイソー"])

        _ = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池"])

        // 同じファイルをもう一度入れても何も増えない（完了していない同じ店＋品目は入らない）。
        let again = try await w.repo.importItems(parsed.items, now: E2E.jst(10, 5, 20))
        XCTAssertEqual(again.added.count, 0)
        XCTAssertEqual(again.duplicates, 3)
        await eq(await w.registrar.ensureRegistered(chains: again.chainsNeedingRegistration).count, 0)
    }

    // (7) 完了を押したら、次の入域は未完了なしで、監視も止まる
    func test_07_通知の完了ボタンで全タスクが完了し_再入域は未完了なしで抑制され_監視は止まる() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        try await w.addTask("ダイソー", "電池")
        let before = await w.plan()
        XCTAssertEqual(before.stations.map(\.name), ["藤沢駅", "辻堂駅"])
        XCTAssertFalse(before.tracksSignificantLocationChanges)

        let first = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        let listed = try XCTUnwrap(first?.notification).taskIDs
        XCTAssertEqual(listed.count, 2)

        try await w.repo.complete(taskIDs: listed, at: E2E.jst(10, 5, 18, 44))
        let tasks = await w.ledger.tasks
        XCTAssertTrue(tasks.allSatisfy { $0.status == .done && $0.completedAt == E2E.jst(10, 5, 18, 44) })

        // 同じ日・別の駅でも、未完了なしが先に効く（今日通知済ではない）。
        let again = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 19, 10))
        XCTAssertEqual(again?.record.result, .suppressedNoPendingTasks)
        XCTAssertNil(again?.notification)
        let tsujido = try await w.enter(E2E.tsujido, at: E2E.jst(10, 5, 19, 40))
        XCTAssertEqual(tsujido?.record.result, .suppressedNoPendingTasks)
        XCTAssertEqual(w.poster.posted.count, 1)

        let after = await w.plan()
        XCTAssertEqual(after, .stopped)
        XCTAssertFalse(after.isMonitoring)

        // 台帳の「戻す」で再開する。
        try await w.repo.reopen(taskIDs: [listed[0]])
        await yes(await w.plan().isMonitoring)
    }

    // (8) 今日は無視
    func test_08_今日は無視は当日だけ通知を止め_監視は続き_翌日の0時から通知に戻る() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let first = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        let listed = try XCTUnwrap(first?.notification).taskIDs

        try await w.repo.ignore(taskIDs: listed, untilTomorrow: true, now: E2E.jst(10, 5, 18, 43), timeZone: E2E.tokyo)
        let task = try await unwrap(await w.ledger.tasks.first)
        XCTAssertEqual(task.status, .ignored)
        XCTAssertEqual(task.ignoredUntil, E2E.jst(10, 6, 0, 0))

        let again = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 19, 10))
        XCTAssertEqual(again?.record.result, .suppressedNoPendingTasks)
        XCTAssertEqual(w.poster.posted.count, 1)

        // D13: 最後のタスクを「今日は無視」しても、明日戻るので監視は止めない。
        let plan = await w.plan(at: E2E.jst(10, 5, 19, 10))
        XCTAssertTrue(plan.isMonitoring)
        XCTAssertEqual(plan.stations.map(\.name), ["藤沢駅", "辻堂駅"])

        // 日付の境目: 23:59:59 はまだ無視、翌 0:00:00 から未完了。
        await yes(await w.ledger.pendingTasks(at: E2E.jst(10, 5, 23, 59, 59)).isEmpty)
        await eq(await w.ledger.pendingTasks(at: E2E.jst(10, 6, 0, 0, 0)).count, 1)

        let nextDay = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 18, 0))
        XCTAssertEqual(nextDay?.record.result, .notified, "前日の通知は今日通知済に数えない")
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
    }

    func test_08b_台帳の無視は戻すまで無期限で_監視も止まる() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let id = try await unwrap(await w.ledger.tasks.first).id
        try await w.repo.ignore(taskIDs: [id], untilTomorrow: false, now: E2E.monday1842, timeZone: E2E.tokyo)
        let outcome = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 9, 18, 0))
        XCTAssertEqual(outcome?.record.result, .suppressedNoPendingTasks)
        await eq(await w.plan(), .stopped)
    }

    // (9) 実測モード
    func test_09_実測モードはタスクが0件でも毎回駅名だけ通知し_監視も続ける() async throws {
        let w = try await World(settings: Settings(diagnosticMode: true))
        await yes(await w.ledger.tasks.isEmpty)
        let plan = await w.plan()
        XCTAssertEqual(plan.stations.map(\.name), ["藤沢駅", "辻堂駅"])

        let a = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        let b = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 18, 50))
        XCTAssertEqual(a?.record.result, .diagnosticNotified)
        XCTAssertEqual(b?.record.result, .diagnosticNotified)
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅に入った", "藤沢駅に入った"])
        XCTAssertTrue(w.poster.posted.allSatisfy { $0.taskIDs.isEmpty })
        XCTAssertNotNil(a?.record.location, "発火位置が履歴に残る")

        // 実測通知は今日通知済に数えない: 実測モードを切ると、同じ日にちゃんと通知できる。
        try await w.repo.updateSettings { $0.diagnosticMode = false }
        await eq(await w.plan(), .stopped, "タスクが無ければ止まる")
        try await w.addTask("ダイソー", "フィルム")
        let real = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 19, 5))
        XCTAssertEqual(real?.record.result, .notified)
    }

    // (10) Places が 403 のとき
    func test_10_登録中のPlaces403はレポートに載り_チェーンは登録済みのまま_入域は支店なしで読める履歴を残す() async throws {
        let w = try await World()
        w.server.failAllStatus = 403
        let reports = try await w.addTask("ダイソー", "フィルム")

        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.stationsSearched, 2)
        XCTAssertEqual(Set(report.stationFailures.keys), ["藤沢駅", "辻堂駅"])
        let message = try XCTUnwrap(report.stationFailures["藤沢駅"])
        XCTAssertTrue(message.contains("許可されていません"), message)
        XCTAssertTrue(message.contains("blocked"), "Google のメッセージが読める: \(message)")
        XCTAssertFalse(message.contains(E2E.apiKey))
        XCTAssertEqual(report.branchesKept, 0)
        XCTAssertNil(report.ledgerError)
        await eq(await w.ledger.registeredChains, ["ダイソー"], "失敗してもチェーンの名前は使える（D11）")
        await yes(await w.ledger.branches.isEmpty)

        let outcome = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(outcome?.record.result, .suppressedNoBranch)
        XCTAssertEqual(outcome?.record.detail, "この駅に支店がありません: ダイソー")
        XCTAssertEqual(outcome?.record.taskIDs.count, 1)
        XCTAssertTrue(w.poster.posted.isEmpty)
        await yes(await w.plan().isMonitoring, "監視は未完了がある限り続く")

        // 復旧後に店画面の「再取得」（register）をやれば、同じ台帳で通知に戻る。
        w.server.failAllStatus = nil
        let retry = await w.registrar.register(chainName: "ダイソー")
        XCTAssertTrue(retry.stationFailures.isEmpty)
        XCTAssertEqual(retry.branchesKept, 2)
        let later = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 19, 0))
        XCTAssertEqual(later?.record.result, .notified)
    }

    func test_10b_営業時間だけ取れなかった支店は営業中扱いで営業時間不明と書き_取得日時は空のまま残る() async throws {
        let w = try await World()
        w.server.failHoursStatus = 403
        let reports = try await w.addTask("ダイソー", "フィルム")
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.stationFailures.isEmpty)
        XCTAssertEqual(Set(report.hoursFailures), ["ダイソー 藤沢店", "ダイソー 辻堂店"])
        XCTAssertEqual(report.branchesKept, 2)
        let branches = await w.ledger.branches
        XCTAssertTrue(branches.allSatisfy { $0.hours == nil && $0.hoursFetchedAt == nil }, "次の週 1 更新で真っ先に再取得される")

        // D4: 営業時間不明 = 営業中。深夜 23 時でも通知し、「営業時間不明」と書く。
        let outcome = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 23, 0))
        XCTAssertEqual(outcome?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜ダイソー 藤沢店（徒歩4分・営業時間不明）：フィルム"])
    }

    // (11) 表記ゆれ
    func test_11_チェーン名の全角半角と大文字小文字が違っても登録済みの支店に一致する() async throws {
        let w = try await World(catalog: Catalog.standard(daisoName: "DAISO 藤沢店"))
        let first = try await w.addTask("daiso", "フィルム")
        XCTAssertEqual(first.first?.chainName, "daiso")
        XCTAssertEqual(w.server.searchedQueries, ["daiso", "daiso"])
        await eq(Set(await w.ledger.branches.map(\.id)), [Catalog.daisoFujisawaID], "名前に daiso を含む支店だけ（ダイソー 辻堂店は別表記）")

        // 全角・大文字で書いても同じチェーン: 再検索しない、登録名は最初の表記のまま。
        let second = try await w.addTask("ＤＡＩＳＯ", "電池")
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(w.server.searchedQueries.count, 2)
        await eq(await w.ledger.registeredChains, ["daiso"])
        // 半角カナ・全角の品目の表記違いは重複。
        let dup = try await w.repo.addTask(store: "Ｄａｉｓｏ ", item: "ﾌｨﾙﾑ", now: E2E.registeredAt)
        guard case .duplicate = dup else { return XCTFail("表記違いの同じ店＋品目は重複のはず: \(dup)") }

        let outcome = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(outcome?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜DAISO 藤沢店（徒歩4分・21時まで）：フィルム、電池"])
    }

    // (12) 駅の削除
    func test_12_駅を消すとその駅だけの支店も消え_その駅の入域は何も記録せずnilを返す() async throws {
        let w = try await World(stations: [E2E.fujisawa, E2E.tsujido, E2E.hommachi])
        try await w.addTask("ダイソー", "フィルム")
        await eq(Set(await w.ledger.branches.map(\.id)), [Catalog.daisoFujisawaID, Catalog.daisoTsujidoID])
        _ = try await w.enter(E2E.tsujido, at: E2E.monday1842)
        let historyBefore = await w.ledger.history.count

        // 辻堂駅だけの支店は、辻堂駅と一緒に消える。履歴は残り、駅名で読める。
        try await w.repo.removeStation(id: E2E.tsujido.id)
        await eq(await w.ledger.branches.map(\.id), [Catalog.daisoFujisawaID])
        let gone = try await w.enter(E2E.tsujido, at: E2E.jst(10, 6, 18, 0))
        XCTAssertNil(gone)
        XCTAssertEqual(w.poster.posted.count, 1)
        await eq(await w.ledger.history.count, historyBefore, "古いイベントは何も記録しない")
        await eq(await w.ledger.history.first?.stationName, "辻堂駅")
        await eq(await w.plan().stations.map(\.name), ["藤沢駅", "藤沢本町駅"])

        // 2 駅から見える支店は、片方の駅を消しても残り、もう片方の距離を持ち続ける。
        try await w.repo.removeStation(id: E2E.fujisawa.id)
        let remaining = try await unwrap(await w.ledger.branches.first)
        XCTAssertEqual(remaining.nearestStations.map(\.stationID), [E2E.hommachi.id])
        // 最後の駅を消したら支店も無くなる。
        try await w.repo.removeStation(id: E2E.hommachi.id)
        await yes(await w.ledger.branches.isEmpty)
        await eq(await w.plan(), .stopped, "駅が無ければ監視する対象が無い")
        await eq(await w.ledger.registeredChains, ["ダイソー"], "チェーンの登録は残る")
    }

    func test_12b_駅を足すとその駅ぶんだけ登録済みのチェーンを再検索して支店が入る() async throws {
        let w = try await World(stations: [E2E.fujisawa])
        try await w.addTask("ダイソー", "フィルム")
        await eq(await w.ledger.branches.map(\.id), [Catalog.daisoFujisawaID])
        let searchesBefore = w.server.searches.count

        try await w.repo.upsertStation(E2E.tsujido)
        let reports = await w.registrar.registerStation(id: E2E.tsujido.id)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(w.server.searches.count, searchesBefore + 1, "追加した駅の 1 回だけ")
        await eq(Set(await w.ledger.branches.map(\.id)), [Catalog.daisoFujisawaID, Catalog.daisoTsujidoID])
        let outcome = try await w.enter(E2E.tsujido, at: E2E.monday1842)
        XCTAssertEqual(outcome?.record.result, .notified)
    }

    // 追加: 深夜営業の店と日付の境目
    func test_13_深夜営業の店は翌1時までと書き_日付をまたぐと駅ごと1日1回がリセットされる() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")

        let evening = try await w.enter(E2E.tsujido, at: E2E.monday1842)
        XCTAssertEqual(evening?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "辻堂駅｜ダイソー 辻堂店（徒歩3分・翌1時まで）：フィルム")

        // 23:55 は同じ日: 今日通知済。
        let sameDay = try await w.enter(E2E.tsujido, at: E2E.jst(10, 5, 23, 55))
        XCTAssertEqual(sameDay?.record.result, .suppressedAlreadyNotifiedToday)

        // 0:20（火）: 月曜 10:00 に開いた枠の続きで営業中・閉店まで 40 分・暦日は火曜 → 通知。「1時まで」は同じ日付。
        let afterMidnight = try await w.enter(E2E.tsujido, at: E2E.jst(10, 6, 0, 20))
        XCTAssertEqual(afterMidnight?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "辻堂駅｜ダイソー 辻堂店（徒歩3分・1時まで）：フィルム")
    }

    func test_13b_深夜営業の閉店間際と閉店ちょうどは抑制する() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let soon = try await w.enter(E2E.tsujido, at: E2E.jst(10, 6, 0, 40))
        XCTAssertEqual(soon?.record.result, .suppressedClosed)
        XCTAssertEqual(soon?.record.detail, "ダイソー 辻堂店は閉店まで20分")
        let closed = try await w.enter(E2E.tsujido, at: E2E.jst(10, 6, 1, 0))
        XCTAssertEqual(closed?.record.result, .suppressedClosed, "閉店時刻ちょうどは営業時間外（終端は含まない）")
        XCTAssertEqual(closed?.record.detail, "ダイソー 辻堂店は営業時間外")
        XCTAssertTrue(w.poster.posted.isEmpty)
    }

    // 台帳が JSON ファイルを経由しても、同じ判定になる（保存→再読込）
    func test_14_保存した台帳を開き直しても同じ入域の結果になる() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        try await w.addTask("ダイソー", "電池")
        _ = try await w.enter(E2E.fujisawa, at: E2E.monday1842)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eki-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = JSONFileLedgerStore(url: dir.appendingPathComponent("ledger.json"))
        try file.save(await w.ledger)
        let reopened = try await LedgerRepository.open(store: file)
        await eq(await reopened.snapshot(), await w.ledger)

        let poster = RecordingPoster()
        let handler = StationEntryHandler(repository: reopened, poster: poster, timeZone: { E2E.tokyo })
        let again = try await handler.handle(TriggerEvent(stationID: E2E.fujisawa.id, firedAt: E2E.jst(10, 5, 19, 0)))
        XCTAssertEqual(again?.record.result, .suppressedAlreadyNotifiedToday)
        let tsujido = try await handler.handle(TriggerEvent(stationID: E2E.tsujido.id, firedAt: E2E.jst(10, 5, 19, 5)))
        XCTAssertEqual(tsujido?.record.result, .notified)
        XCTAssertEqual(poster.posted.map(\.body), ["辻堂駅｜ダイソー 辻堂店（徒歩3分・翌1時まで）：フィルム、電池"])
    }

    // MARK: - 営業時間の読み取りが入域の判定まで正しく届く（Places の表現 → 評価器 → 本文）

    private func oneDaiso(_ hoursJSON: String, name: String = "ダイソー 藤沢店") -> [FakePlace] {
        [FakePlace(id: Catalog.daisoFujisawaID, name: name, coordinate: Catalog.daisoFujisawaAt, hoursJSON: hoursJSON)]
    }

    func test_15_日曜だけ閉店が早い店は日曜の判定に日曜の時間を使う() async throws {
        // 月〜土 10:00–21:00、日曜 10:00–20:00。Places は日曜を day 0（JSON では省略）で返す。
        var periods = (1...6).map { PlacesJSON.period(openDay: $0, open: (10, 0), closeDay: $0, close: (21, 0)) }
        periods.append(PlacesJSON.period(openDay: 0, open: (10, 0), closeDay: 0, close: (20, 0)))
        let w = try await World(stations: [E2E.fujisawa], catalog: oneDaiso(PlacesJSON.hours(periods)))
        try await w.addTask("ダイソー", "フィルム")

        let sunday = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 11, 19, 45))   // 2026-10-11 は日曜
        XCTAssertEqual(sunday?.record.result, .suppressedClosed)
        XCTAssertEqual(sunday?.record.detail, "ダイソー 藤沢店は閉店まで15分")
        let sundayNoon = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 11, 12, 0))
        XCTAssertEqual(sundayNoon?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・20時まで）：フィルム")
        // 月曜（翌日）の同じ時刻は営業中。
        let monday = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 12, 19, 45))
        XCTAssertEqual(monday?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
    }

    func test_16_定休日の曜日は営業時間外で_次の日に通知する() async throws {
        // 日曜定休: Places は日曜の枠を返さない。
        let periods = (1...6).map { PlacesJSON.period(openDay: $0, open: (10, 0), closeDay: $0, close: (21, 0)) }
        let w = try await World(stations: [E2E.fujisawa], catalog: oneDaiso(PlacesJSON.hours(periods)))
        try await w.addTask("ダイソー", "フィルム")
        let sunday = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 11, 14, 0))
        XCTAssertEqual(sunday?.record.result, .suppressedClosed)
        XCTAssertEqual(sunday?.record.detail, "ダイソー 藤沢店は営業時間外")
        let monday = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 12, 14, 0))
        XCTAssertEqual(monday?.record.result, .notified)
    }

    func test_17_24時閉店は24時までと書き_閉店の30分前を過ぎると抑制する() async throws {
        let h = PlacesJSON.hours(PlacesJSON.dailyPeriods(open: (10, 0), close: (0, 0)))
        let w = try await World(stations: [E2E.fujisawa], catalog: oneDaiso(h))
        try await w.addTask("ダイソー", "フィルム")
        let late = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 23, 45))
        XCTAssertEqual(late?.record.result, .suppressedClosed)
        XCTAssertEqual(late?.record.detail, "ダイソー 藤沢店は閉店まで15分")
        let evening = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 23, 20))
        XCTAssertEqual(evening?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・24時まで）：フィルム")
        let afterMidnight = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 0, 5))
        XCTAssertEqual(afterMidnight?.record.detail, "ダイソー 藤沢店は営業時間外", "24:00 閉店のあと 10:00 の開店までは時間外")
    }

    func test_18_24時間営業はどちらの表現でも24時間営業と書いて常に通知する() async throws {
        let alwaysOpenFlag = "{\"regularOpeningHours\": {\"periods\": [{\"open\": {\"day\": 0, \"hour\": 0, \"minute\": 0}}]}, \"timeZone\": {\"id\": \"Asia/Tokyo\"}}"
        let contiguous = PlacesJSON.hours(PlacesJSON.dailyPeriods(open: (0, 0), close: (0, 0)))   // 毎日 0:00→翌 0:00
        for (label, json) in [("always-open フラグ", alwaysOpenFlag), ("隙間なしの 7 枠", contiguous)] {
            let w = try await World(stations: [E2E.fujisawa], catalog: oneDaiso(json))
            try await w.addTask("ダイソー", "フィルム")
            let outcome = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 3, 30))
            XCTAssertEqual(outcome?.record.result, .notified, label)
            XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・24時間営業）：フィルム", label)
        }
    }

    func test_19_特別日で短縮営業の日はその日の時間で判定し_ほかの日は通常の時間に戻る() async throws {
        // 10/5（月）だけ 10:00–17:00。
        let h = PlacesJSON.hoursWithSpecialDays(shortened: [5: ((10, 0), (17, 0))])
        let w = try await World(stations: [E2E.fujisawa], catalog: oneDaiso(h))
        try await w.addTask("ダイソー", "フィルム")
        let evening = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(evening?.record.result, .suppressedClosed, "通常なら 21 時まで営業だが、この日は 17 時で終わり")
        let nearClose = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 16, 45))
        XCTAssertEqual(nearClose?.record.detail, "ダイソー 藤沢店は閉店まで15分")
        let afternoon = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 5, 15, 0))
        XCTAssertEqual(afternoon?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・17時まで）：フィルム")
        let tuesday = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 18, 42))
        XCTAssertEqual(tuesday?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム")
    }

    func test_20_特別日が休みでも_前日から続く深夜営業は閉まらない() async throws {
        // 毎日 10:00–翌 1:00。10/6（火）は臨時休業 = 火曜 10:00 には開かないが、月曜 10:00 に開いた枠は火曜 1:00 まで続く。
        let h = PlacesJSON.hoursWithSpecialDays(open: (10, 0), close: (1, 0), closed: [6])
        let w = try await World(stations: [E2E.tsujido], catalog: [
            FakePlace(id: Catalog.daisoTsujidoID, name: "ダイソー 辻堂店", coordinate: E2E.tsujido.coordinate.moved(eastMeters: 200), hoursJSON: h),
        ])
        try await w.addTask("ダイソー", "フィルム")
        let spill = try await w.enter(E2E.tsujido, at: E2E.jst(10, 6, 0, 20))
        XCTAssertEqual(spill?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "辻堂駅｜ダイソー 辻堂店（徒歩3分・1時まで）：フィルム")
        let tuesdayNoon = try await w.enter(E2E.tsujido, at: E2E.jst(10, 6, 12, 0))
        XCTAssertEqual(tuesdayNoon?.record.detail, "ダイソー 辻堂店は営業時間外", "休みの日の昼は閉まっている")
    }

    // MARK: - 支店の選び方・時間帯のずれ・更新

    func test_21_最寄りの支店が閉まっていれば_次に近い開いている支店を載せる() async throws {
        let northID = "ChIJ-daiso-fujisawa-kitaguchi-6"
        let w = try await World(stations: [E2E.fujisawa], catalog: [
            FakePlace(id: Catalog.daisoFujisawaID, name: "ダイソー 藤沢店", coordinate: Catalog.daisoFujisawaAt,
                      hoursJSON: PlacesJSON.hoursWithSpecialDays(closed: [5])),
            FakePlace(id: northID, name: "ダイソー 藤沢北口店", coordinate: E2E.fujisawa.coordinate.moved(eastMeters: 450),
                      hoursJSON: Catalog.h10to21),
        ])
        try await w.addTask("ダイソー", "フィルム")
        let branchCount = await w.ledger.branches.count
        XCTAssertEqual(branchCount, 2)
        let outcome = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(outcome?.record.result, .notified)
        XCTAssertEqual(outcome?.record.branchIDs, [northID])
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜ダイソー 藤沢北口店（徒歩6分・21時まで）：フィルム"])
        // 翌日は最寄りの店が開くので、そちらに戻る。
        let next = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 18, 42))
        XCTAssertEqual(next?.record.branchIDs, [Catalog.daisoFujisawaID])
    }

    func test_22_端末が日本以外のタイムゾーンでも_閉店は店の現地時刻で書き_今日通知済は端末の暦日で数える() async throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let w = try await World(stations: [E2E.fujisawa], deviceTimeZone: la)
        try await w.addTask("ダイソー", "フィルム")
        // 月曜 18:42 JST = 月曜 02:42 PDT。
        let first = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(first?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.last?.body, "藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム", "店の現地時刻で 21 時まで")
        // 火曜 10:00 JST = 月曜 18:00 PDT: 端末の暦日では同じ月曜 → 今日通知済。
        let sameDeviceDay = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 10, 0))
        XCTAssertEqual(sameDeviceDay?.record.result, .suppressedAlreadyNotifiedToday)
        // 火曜 17:00 JST = 火曜 01:00 PDT: 端末の暦日が変わった。
        let nextDeviceDay = try await w.enter(E2E.fujisawa, at: E2E.jst(10, 6, 17, 0))
        XCTAssertEqual(nextDeviceDay?.record.result, .notified)
        // 「今日は無視」の翌日 0 時も端末の暦。
        let listed = try XCTUnwrap(w.poster.posted.last).taskIDs
        try await w.repo.ignore(taskIDs: listed, untilTomorrow: true, now: E2E.jst(10, 6, 17, 1), timeZone: la)
        let tasks = await w.ledger.tasks
        let until = try XCTUnwrap(tasks.first?.ignoredUntil)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        XCTAssertEqual(cal.dateComponents([.year, .month, .day, .hour, .minute], from: until),
                       DateComponents(year: 2026, month: 10, day: 7, hour: 0, minute: 0))
    }

    func test_23_週1更新で営業時間が変わった店は新しい時間で判定される() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let refresher = HoursRefresher(repository: w.repo, hours: w.places, now: { E2E.jst(10, 12, 12) })
        let dueBefore = await refresher.isDue()
        XCTAssertTrue(dueBefore, "登録から 8 日: 7 日を超えたので更新対象")

        // 辻堂店は 20 時閉店に短縮された。
        w.server.setHours(placeID: Catalog.daisoTsujidoID, json: PlacesJSON.hours(PlacesJSON.dailyPeriods(open: (10, 0), close: (20, 0))))
        let report = await refresher.refreshStale()
        XCTAssertEqual(report.refreshed, 2)
        XCTAssertTrue(report.failed.isEmpty)
        let dueAfter = await refresher.isDue()
        XCTAssertFalse(dueAfter)
        let branches = await w.ledger.branches
        let tsujidoBranch = try XCTUnwrap(branches.first { $0.id == Catalog.daisoTsujidoID })
        XCTAssertEqual(tsujidoBranch.hoursFetchedAt, E2E.jst(10, 12, 12))

        let outcome = try await w.enter(E2E.tsujido, at: E2E.jst(10, 13, 19, 45))
        XCTAssertEqual(outcome?.record.result, .suppressedClosed)
        XCTAssertEqual(outcome?.record.detail, "ダイソー 辻堂店は閉店まで15分")
        // 完了したチェーンは更新しない（使っていない店は更新しない）。
        let ids = await w.ledger.tasks.map(\.id)
        try await w.repo.complete(taskIDs: ids, at: E2E.jst(10, 13, 20))
        let later = HoursRefresher(repository: w.repo, hours: w.places, now: { E2E.jst(10, 30, 12) })
        let dueAfterDone = await later.isDue()
        XCTAssertFalse(dueAfterDone)
    }

    // MARK: - 同時に起きても壊れない（順序は仮定しない）

    func test_24_同じ駅への入域が同時に何度来ても通知は1通だけ() async throws {
        let w = try await World()
        try await w.addTask("ダイソー", "フィルム")
        let station = E2E.fujisawa
        var results: [NotificationResult] = []
        try await withThrowingTaskGroup(of: NotificationResult?.self) { group in
            for i in 0..<8 {
                group.addTask { try await w.enter(station, at: E2E.jst(10, 5, 18, 42, i))?.record.result }
            }
            for try await r in group { if let r { results.append(r) } }
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(results.filter { $0 == .notified }.count, 1)
        XCTAssertEqual(results.filter { $0 == .suppressedAlreadyNotifiedToday }.count, 7)
        XCTAssertEqual(w.poster.posted.count, 1)
        let history = await w.ledger.history
        XCTAssertEqual(history.count, 8)
        XCTAssertEqual(history.filter { $0.result == .notified }.count, 1)
    }

    func test_25_同じチェーンの店登録が同時に走っても支店が二重にならない() async throws {
        let w = try await World()
        _ = try await w.repo.addTask(store: "ダイソー", item: "フィルム", now: E2E.registeredAt)
        let registrar = w.registrar
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = await registrar.ensureRegistered(chains: ["ダイソー"]) } }
            group.addTask { _ = await registrar.ensureRegistered(chains: ["ダイソー　"]) }   // 全角空白つきの別表記でも同じ登録
        }
        let ledger = await w.ledger
        XCTAssertEqual(ledger.branches.map(\.id).sorted(), [Catalog.daisoFujisawaID, Catalog.daisoTsujidoID].sorted())
        for b in ledger.branches {
            XCTAssertEqual(Set(b.nearestStations.map(\.stationID)).count, b.nearestStations.count, "同じ駅の距離が 2 つ入らない")
            XCTAssertEqual(b.nearestStations.count, 1)
        }
        XCTAssertEqual(ledger.registeredChains.count, 1)
        // 結果は 1 回登録した場合と同じに通知できる。
        let outcome = try await w.enter(E2E.fujisawa, at: E2E.monday1842)
        XCTAssertEqual(outcome?.record.result, .notified)
        XCTAssertEqual(w.poster.posted.map(\.body), ["藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム"])
    }
}
