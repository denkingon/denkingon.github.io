import Foundation

/// 緯度経度。CoreLocation に依存しないので Linux でもテストできる。
public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres (haversine, mean Earth radius).
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_008.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// 位置の実測値。M1（1週間の実測）で「どこで発火したか」を履歴に残すために使う。
public struct LocationFix: Codable, Equatable, Sendable {
    public var coordinate: Coordinate
    /// metres. Negative means CoreLocation considered the fix invalid.
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(coordinate: Coordinate, horizontalAccuracy: Double, timestamp: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}
