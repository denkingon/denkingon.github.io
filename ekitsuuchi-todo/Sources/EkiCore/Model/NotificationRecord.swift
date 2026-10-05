import Foundation

/// 発火・抑制の結果（コンテンツ設計書 §2 通知履歴）。どの門で止まっても 1 行残る。
public enum NotificationResult: String, Codable, Sendable, CaseIterable {
    case notified                       // 通知した
    case diagnosticNotified             // 実測モード：駅名だけ通知した（M1）
    case suppressedClosed               // 抑制:営業時間外
    case suppressedAlreadyNotifiedToday // 抑制:今日通知済
    case suppressedNoPendingTasks       // 抑制:未完了なし
    case suppressedNoBranch             // 抑制:支店なし
    case failedToPost                   // 通知を出せなかった（通知の許可なし等）。detail に理由。「今日通知済」には数えない

    public var label: String {
        switch self {
        case .notified: return "通知した"
        case .diagnosticNotified: return "通知した（実測）"
        case .suppressedClosed: return "抑制:営業時間外"
        case .suppressedAlreadyNotifiedToday: return "抑制:今日通知済"
        case .suppressedNoPendingTasks: return "抑制:未完了なし"
        case .suppressedNoBranch: return "抑制:支店なし"
        case .failedToPost: return "通知に失敗"
        }
    }

    public var isSuppression: Bool {
        switch self {
        case .notified, .diagnosticNotified: return false
        default: return true
        }
    }
}

public struct NotificationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var stationID: UUID
    /// 駅を後で消しても履歴が読めるように名前も残す。
    public var stationName: String
    /// 通知に載った（または抑制された）支店・タスク。抑制で該当なしなら空。
    public var branchIDs: [String]
    public var taskIDs: [UUID]
    public var firedAt: Date
    public var result: NotificationResult
    /// 発火時の端末の位置。M1 の完了条件「発火位置と時刻がログに残る」のための追加欄。
    public var location: LocationFix?
    /// 1 行で読める補足。例 "閉店まで20分（ダイソー 藤沢店）"
    public var detail: String?

    public init(
        id: UUID = UUID(),
        stationID: UUID,
        stationName: String,
        branchIDs: [String] = [],
        taskIDs: [UUID] = [],
        firedAt: Date,
        result: NotificationResult,
        location: LocationFix? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.stationID = stationID
        self.stationName = stationName
        self.branchIDs = branchIDs
        self.taskIDs = taskIDs
        self.firedAt = firedAt
        self.result = result
        self.location = location
        self.detail = detail
    }
}
