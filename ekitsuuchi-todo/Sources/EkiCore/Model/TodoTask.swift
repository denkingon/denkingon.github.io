import Foundation

/// 状態。「無視」＝通知だけ止めて残す（コンテンツ設計書 §2）。
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case pending   // 未完了
    case done      // 完了
    case ignored   // 無視

    public var label: String {
        switch self {
        case .pending: return "未完了"
        case .done: return "完了"
        case .ignored: return "無視"
        }
    }
}

/// タスク（人が書く台帳）。`Task` は Swift の並行処理と名前が衝突するので TodoTask。
public struct TodoTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 店（チェーン名）。支店台帳のチェーン名と ChainName.key で一致させる。
    public var store: String
    /// 品目。通知本文に出る。
    public var item: String
    /// 出典。"手打ち" / "LINE:友人" / "Notion:HQ" など。A（自動抽出）のための欄。
    public var source: String
    /// 出典日。期限ではない。言及された日。
    public var sourceDate: CalendarDay?
    public var status: TaskStatus
    public var createdAt: Date
    public var completedAt: Date?
    /// 通知の「今日は無視」を押したとき、翌日のローカル 0 時が入る。status == .ignored で値があれば
    /// その時刻を過ぎると未完了として扱う（`isPending(at:)`）。nil のまま .ignored なら、戻すまで無期限の無視。
    /// （設計書の「状態」は 3 値のまま。「今日は無視」と「無視＝通知だけ止めて残す」を両立させる追加欄。）
    public var ignoredUntil: Date?

    public init(
        id: UUID = UUID(),
        store: String,
        item: String,
        source: String = TodoTask.manualSource,
        sourceDate: CalendarDay? = nil,
        status: TaskStatus = .pending,
        createdAt: Date,
        completedAt: Date? = nil,
        ignoredUntil: Date? = nil
    ) {
        self.id = id
        self.store = store
        self.item = item
        self.source = source
        self.sourceDate = sourceDate
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.ignoredUntil = ignoredUntil
    }

    public static let manualSource = "手打ち"

    /// 通知の対象になる（未完了、または「今日は無視」の期限が切れた無視）か。
    public func isPending(at now: Date) -> Bool {
        switch status {
        case .pending: return true
        case .done: return false
        case .ignored:
            if let until = ignoredUntil { return now >= until }
            return false
        }
    }
}
