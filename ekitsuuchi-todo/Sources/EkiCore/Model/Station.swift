import Foundation

/// 駅（人が初回に書く）。座標は駅名検索で自動、半径は M1 の実測後に決める。
public struct Station: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var coordinate: Coordinate
    /// metres. 初期値は `Tuning.stationRadiusMeters`.
    public var radiusMeters: Double
    /// 一時的に外す用。
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        coordinate: Coordinate,
        radiusMeters: Double = Tuning.stationRadiusMeters,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.radiusMeters = radiusMeters
        self.isEnabled = isEnabled
    }
}
