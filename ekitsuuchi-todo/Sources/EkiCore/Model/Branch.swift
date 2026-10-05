import Foundation

/// 支店から最寄り駅までの距離。店登録時に計算する（同じ支店が 2 駅から見えたら 1 件に両駅を持たせる）。
public struct StationDistance: Codable, Equatable, Sendable {
    public var stationID: UUID
    public var meters: Double

    public init(stationID: UUID, meters: Double) {
        self.stationID = stationID
        self.meters = meters
    }
}

/// 支店（アプリが書く。Google Places のキャッシュ）。
public struct Branch: Codable, Equatable, Identifiable, Sendable {
    /// Google の Place ID.
    public var id: String
    public var chainName: String
    /// 支店名。通知本文に出る。例 "ダイソー 藤沢店"
    public var name: String
    public var coordinate: Coordinate
    /// nil = Places に営業時間が無い／まだ取れていない。判定では「営業中とみなし、営業時間不明と書く」。
    public var hours: OpeningHours?
    /// 最終取得。7 日超で再取得対象。
    public var hoursFetchedAt: Date?
    public var nearestStations: [StationDistance]
    /// 自由キー値。v0 は手動（規模=大型 など）。将来は在庫調査が書く。
    public var attributes: [String: String]

    public init(
        id: String,
        chainName: String,
        name: String,
        coordinate: Coordinate,
        hours: OpeningHours? = nil,
        hoursFetchedAt: Date? = nil,
        nearestStations: [StationDistance] = [],
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.chainName = chainName
        self.name = name
        self.coordinate = coordinate
        self.hours = hours
        self.hoursFetchedAt = hoursFetchedAt
        self.nearestStations = nearestStations
        self.attributes = attributes
    }

    public func distance(to stationID: UUID) -> Double? {
        nearestStations.first { $0.stationID == stationID }?.meters
    }
}
