import Foundation

/// 権限まわりの文言。計画書 §2: App Store 審査の理由文はアプリ内の文言と一致させる。
enum PermissionCopy {
    /// project.yml の NSLocationAlwaysAndWhenInUseUsageDescription / NSLocationWhenInUseUsageDescription と
    /// 一字一句同じにすること（審査の理由文とアプリ内表示を一致させるため）。変えるときは project.yml も同時に。
    static let locationReason =
        "使う駅に入った瞬間をバックグラウンドでも検知し、その駅の近くで開いている店のタスクをお知らせするために、位置情報を「常に」使います。"

    /// 「常に」でないときの案内（駅画面・設定画面）。
    static let locationAlwaysRequired = "常に許可が必要です"

    /// 通知の許可を求める理由（権限ダイアログ自体の文言は iOS 固定。ここは画面内の説明用）。
    static let notificationReason = "駅に入ったときに、その駅の近くで買うものをお知らせするために通知を使います。"

    static let notificationDenied = "通知が許可されていません（設定 > 通知）"

    static let placesKeyMissing = "Places API キーが未設定です（README）"
}
