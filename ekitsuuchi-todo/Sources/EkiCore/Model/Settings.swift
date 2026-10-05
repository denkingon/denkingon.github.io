import Foundation

public enum NotifyFrequency: String, Codable, Sendable, CaseIterable {
    /// 駅ごと 1 日 1 回（既定。決定事項）
    case perStationPerDay
    /// 入域のたび
    case everyEntry
    /// 全駅合わせて 1 日 1 回
    case oncePerDay

    public var label: String {
        switch self {
        case .perStationPerDay: return "駅ごとに1日1回"
        case .everyEntry: return "入域のたび"
        case .oncePerDay: return "全駅で1日1回"
        }
    }
}

/// 設定画面の値（コンテンツ設計書 §3: 通知の頻度、営業時間チェックの有無）。
public struct Settings: Codable, Equatable, Sendable {
    public var frequency: NotifyFrequency
    /// false なら判定の「営業中？」の門を通す（営業時間を見ない）。
    public var checkBusinessHours: Bool
    /// M1 の実測用。入域のたびに「藤沢駅に入った」とだけ通知し、位置と時刻を履歴に残す。
    public var diagnosticMode: Bool

    public init(
        frequency: NotifyFrequency = .perStationPerDay,
        checkBusinessHours: Bool = true,
        diagnosticMode: Bool = false
    ) {
        self.frequency = frequency
        self.checkBusinessHours = checkBusinessHours
        self.diagnosticMode = diagnosticMode
    }

    // 将来の欄追加で古い台帳が読めなくならないように、欠けた欄は既定値で読む。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decodeIfPresent(NotifyFrequency.self, forKey: .frequency) ?? .perStationPerDay
        checkBusinessHours = try c.decodeIfPresent(Bool.self, forKey: .checkBusinessHours) ?? true
        diagnosticMode = try c.decodeIfPresent(Bool.self, forKey: .diagnosticMode) ?? false
    }
}
