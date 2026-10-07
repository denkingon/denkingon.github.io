import Foundation

/// 判定の初期値（コンテンツ設計書 §5「判定の初期値」。M1 の実測後に見直す）。
/// 数字はここに集めて、判定器・登録処理は直書きしない。
public enum Tuning {
    /// 駅の半径 m。駅前広場と改札を含み、隣駅と重ならない。
    public static let stationRadiusMeters: Double = 300
    /// 支店の検索半径 m（駅から）。徒歩 6〜7 分。
    public static let branchSearchRadiusMeters: Double = 500
    /// 営業中の判定：閉店まで何分残っていれば「営業中」か。
    public static let closingMarginMinutes: Int = 30
    /// 週 1 更新の閾値：最終取得からこの日数を超えたら再取得。
    public static let hoursRefreshAfterDays: Int = 7
    /// iOS の領域監視は 1 アプリ 20 個まで。
    public static let regionMonitoringCap: Int = 20
    /// 徒歩の分数 = ceil(距離 m / 80)（不動産表示の規約と同じ）。
    public static let walkingMetersPerMinute: Double = 80
    /// 履歴の上限件数。超えたら古いものから捨てる。
    public static let maxHistoryRecords: Int = 2000
}
