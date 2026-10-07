import Foundation

/// 端末内の台帳 4 つ（タスク・駅・支店・通知履歴）と、アプリが持つ設定。1 つの JSON ファイルとして保存する。
/// 人が書くのは tasks だけ。stations は初回に一度、branches と history はアプリが書く（コンテンツ設計書 §2）。
public struct Ledger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var tasks: [TodoTask]
    public var stations: [Station]
    public var branches: [Branch]
    /// 新しい順ではなく追記順（古い→新しい）。表示側で並べ替える。
    public var history: [NotificationRecord]
    /// 店登録済みのチェーン名（表記はユーザーが入れた名前）。タスクの「店」に使える名前の一覧。
    public var registeredChains: [String]
    public var settings: Settings

    public init(
        schemaVersion: Int = Ledger.currentSchemaVersion,
        tasks: [TodoTask] = [],
        stations: [Station] = [],
        branches: [Branch] = [],
        history: [NotificationRecord] = [],
        registeredChains: [String] = [],
        settings: Settings = Settings()
    ) {
        self.schemaVersion = schemaVersion
        self.tasks = tasks
        self.stations = stations
        self.branches = branches
        self.history = history
        self.registeredChains = registeredChains
        self.settings = settings
    }

    // 欠けた欄は既定値で読む（将来の欄追加で古いファイルが読めなくならないように）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Ledger.currentSchemaVersion
        tasks = try c.decodeIfPresent([TodoTask].self, forKey: .tasks) ?? []
        stations = try c.decodeIfPresent([Station].self, forKey: .stations) ?? []
        branches = try c.decodeIfPresent([Branch].self, forKey: .branches) ?? []
        history = try c.decodeIfPresent([NotificationRecord].self, forKey: .history) ?? []
        registeredChains = try c.decodeIfPresent([String].self, forKey: .registeredChains) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    }
}

// MARK: - 判定器・登録処理が共通で使う読み取り

public extension Ledger {
    /// 通知の対象になるタスク（未完了、および「今日は無視」の期限が切れたもの）。
    func pendingTasks(at now: Date) -> [TodoTask] {
        tasks.filter { $0.isPending(at: now) }
    }

    func station(id: UUID) -> Station? {
        stations.first { $0.id == id }
    }

    /// その駅の最寄りとして登録されている、このチェーンの支店（駅からの距離の近い順）。
    func branches(ofChain chain: String, nearStation stationID: UUID) -> [(branch: Branch, meters: Double)] {
        branches
            .filter { ChainName.matches($0.chainName, chain) }
            .compactMap { b in b.distance(to: stationID).map { (branch: b, meters: $0) } }
            .sorted { $0.meters < $1.meters }
    }
}
