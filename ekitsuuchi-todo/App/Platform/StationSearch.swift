import CoreLocation
import EkiCore
import Foundation
import MapKit

/// 駅の検索結果 1 件（駅名 → 座標）。駅の登録画面が選ばせる。
struct StationCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let coordinate: Coordinate
    let subtitle: String?
}

/// 駅名 → 座標。MapKit の検索（キー不要・端末内の API）を使う。Places は店の検索専用に取っておく。
struct StationSearch {
    private static let maxResults = 10

    init() {}

    func search(_ text: String) async throws -> [StationCandidate] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        // 「藤沢」だけでも駅が出るように、駅で終わっていなければ付ける。
        request.naturalLanguageQuery = trimmed.hasSuffix("駅") ? trimmed : trimmed + "駅"
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
        // 全国から探す（端末の現在地に引きずられない）。
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.2),
            span: MKCoordinateSpan(latitudeDelta: 24, longitudeDelta: 28)
        )

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            // 該当なしはエラーで返ることがある。画面には「見つからない」と同じ空配列で渡す。
            return []
        }

        var seen = Set<String>()
        var candidates: [StationCandidate] = []
        for item in response.mapItems {
            guard let name = item.name, !name.isEmpty else { continue }
            let coordinate = Coordinate(
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude
            )
            // 同名・同位置（小数 4 桁 ≒ 11 m）は 1 件にまとめる。
            let key = Self.key(name: name, coordinate: coordinate)
            guard seen.insert(key).inserted else { continue }

            let subtitle = [item.placemark.locality, item.placemark.administrativeArea]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            candidates.append(StationCandidate(
                id: key,
                name: name,
                coordinate: coordinate,
                subtitle: subtitle.isEmpty ? nil : subtitle
            ))
        }

        // 名前に「駅」を含むものを先に（バス停・空港などを後ろへ）。それぞれ元の順序は保つ。
        let stations = candidates.filter { $0.name.contains("駅") }
        let others = candidates.filter { !$0.name.contains("駅") }
        return Array((stations + others).prefix(Self.maxResults))
    }

    private static func key(name: String, coordinate: Coordinate) -> String {
        let lat = Int((coordinate.latitude * 10_000).rounded())
        let lon = Int((coordinate.longitude * 10_000).rounded())
        return "\(name)@\(lat),\(lon)"
    }
}
