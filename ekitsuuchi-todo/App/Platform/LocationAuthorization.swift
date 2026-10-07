import CoreLocation

/// 位置情報の許可状態。画面に出す文言（`label`）と「常に」判定をここに寄せる。
enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .denied
        }
    }

    var label: String {
        switch self {
        case .notDetermined: return "未設定"
        case .denied: return "拒否"
        case .restricted: return "制限あり"
        case .whenInUse: return "使用中のみ"
        case .always: return "常に"
        }
    }

    /// 領域監視がバックグラウンドで効くのは「常に」だけ。
    var isAlways: Bool { self == .always }
}
