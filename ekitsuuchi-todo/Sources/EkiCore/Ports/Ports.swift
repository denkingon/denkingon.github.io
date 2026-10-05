import Foundation

// 差し替え口 5 つ（コンテンツ設計書 §5）。外部に依存する部分はここに名前で切っておき、差し替えは口の裏だけを書き換える。
// 台帳と画面は触らない。v0 の実装と将来の差し替え先は各 protocol のコメントに書いてある。

// MARK: 1. 店の検索

public struct BranchCandidate: Equatable, Sendable {
    public var placeID: String
    public var name: String
    public var coordinate: Coordinate

    public init(placeID: String, name: String, coordinate: Coordinate) {
        self.placeID = placeID
        self.name = name
        self.coordinate = coordinate
    }
}

/// チェーン名＋座標＋半径 → 支店の一覧。
/// v0: Google Places（キー埋込）= `PlacesClient`。差し替え先: 中継サーバ経由の Places（配布時）。
public protocol StoreSearching: Sendable {
    func searchBranches(chainName: String, near center: Coordinate, radiusMeters: Double) async throws -> [BranchCandidate]
}

// MARK: 2. 営業時間

/// 支店 → 曜日別＋特別日。nil = Places にその店の営業時間が無い。
/// v0: Google Places = `PlacesClient`。差し替え先: 公式サイトで上書き（臨時休業）。
public protocol BusinessHoursProviding: Sendable {
    func openingHours(placeID: String) async throws -> OpeningHours?
}

// MARK: 3. タスクの流入

/// {店, 品目, 出典, 日付}。入力 JSON v1 の 1 件（M4）。A（LINE・Notion の自動抽出）もこの形で吐けば繋がる。
public struct InflowItem: Equatable, Sendable {
    public var store: String
    public var item: String
    public var source: String
    public var date: CalendarDay?

    public init(store: String, item: String, source: String, date: CalendarDay? = nil) {
        self.store = store
        self.item = item
        self.source = source
        self.date = date
    }
}

/// → タスクの一覧。v0: 手打ち（画面から台帳へ直接）／JSON 1 ファイル。差し替え先: LINE txt 抽出／Notion。
public protocol TaskInflow: Sendable {
    func fetchItems() async throws -> [InflowItem]
}

// MARK: 4. 支店の属性

/// 支店 → キー値。v0: 手動タグ（画面で付ける。この口は使わない）。差し替え先: 週 1 の在庫・規模調査 AI。
public protocol BranchAttributing: Sendable {
    func attributes(for branch: Branch) async throws -> [String: String]
}

// MARK: 5. 引き金

/// 「今、通知を考えるべき」。v0: 駅のジオフェンス入域。差し替え先: カレンダーの余裕検知／ルーティン推定。
public struct TriggerEvent: Equatable, Sendable {
    public var stationID: UUID
    public var firedAt: Date
    /// 発火時点の端末位置（取れたとき）。履歴に残して M1 で半径を決める材料にする。
    public var location: LocationFix?

    public init(stationID: UUID, firedAt: Date, location: LocationFix? = nil) {
        self.stationID = stationID
        self.firedAt = firedAt
        self.location = location
    }
}

/// 領域監視をどうするかの計画（`MonitoringPlanner` が決め、`TriggerSource` が実行する）。
public struct MonitoringPlan: Equatable, Sendable {
    /// 今登録すべき駅。空なら監視を止める。個数は `Tuning.regionMonitoringCap` 以下。
    public var stations: [Station]
    /// 有効な駅が上限を超えているとき true。端末が動いたら近い駅に入れ替える必要があるので、
    /// 大きな位置変化の通知も購読する。
    public var tracksSignificantLocationChanges: Bool

    public init(stations: [Station], tracksSignificantLocationChanges: Bool = false) {
        self.stations = stations
        self.tracksSignificantLocationChanges = tracksSignificantLocationChanges
    }

    public static let stopped = MonitoringPlan(stations: [], tracksSignificantLocationChanges: false)
    public var isMonitoring: Bool { !stations.isEmpty }
}

/// v0 の実装は iOS 側の `GeofenceTrigger`（CLLocationManager の領域監視）。
public protocol TriggerSource: AnyObject {
    /// アプリ起動の早い段階（起動直後）に設定すること。バックグラウンドで起動されたときに保留中の入域イベントが届く。
    var onTrigger: (@Sendable (TriggerEvent) -> Void)? { get set }
    /// 計画どおりに登録し直す。前の計画にあって今回無い駅は外す。
    func apply(_ plan: MonitoringPlan)
}

// MARK: - 通知

public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String
    public var stationID: UUID
    /// 「完了」「今日は無視」ボタンが対象にするタスク。
    public var taskIDs: [UUID]

    public init(title: String = "", body: String, stationID: UUID, taskIDs: [UUID]) {
        self.title = title
        self.body = body
        self.stationID = stationID
        self.taskIDs = taskIDs
    }
}

/// ローカル通知を出す。iOS 側の実装は UNUserNotificationCenter。
public protocol NotificationPosting: Sendable {
    func post(_ content: NotificationContent) async throws
}

// MARK: - HTTP（Places の呼び出しを Linux でテストするための薄い口）

public struct HTTPRequest: Equatable, Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// iOS 側の実装は URLSession。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
