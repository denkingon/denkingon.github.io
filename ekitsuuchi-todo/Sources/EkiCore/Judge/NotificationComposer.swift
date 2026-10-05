import Foundation

/// 1 つの支店ぶんの通知の行。`meters` はその駅からの距離（D6 の徒歩分数と並び順に使う）。
public struct BranchLine: Sendable {
    public var branch: Branch
    public var meters: Double
    public var tasks: [TodoTask]

    public init(branch: Branch, meters: Double, tasks: [TodoTask]) {
        self.branch = branch
        self.meters = meters
        self.tasks = tasks
    }
}

/// 通知本文（コンテンツ設計書 §3）:
/// `藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池`
/// 複数の支店は改行で行を分ける。純粋関数（時刻は引数）。
public enum NotificationComposer {
    public static func compose(station: Station, lines: [BranchLine], now: Date, timeZone: TimeZone) -> NotificationContent {
        // `timeZone`（端末側）は閉店表記には使わない: 「21時まで」は店の現地時刻で言うもの（D14）。
        _ = timeZone
        let ordered = orderedLines(lines)
        let text = ordered.map { line -> String in
            let closing = closingText(line.branch.hours, now: now)
            return "\(line.branch.name)（徒歩\(walkingMinutes(meters: line.meters))分・\(closing)）：\(itemsText(line.tasks))"
        }
        let body = text.isEmpty ? station.name : "\(station.name)｜" + text.joined(separator: "\n")
        return NotificationContent(
            title: "",
            body: body,
            stationID: station.id,
            taskIDs: ordered.flatMap { $0.tasks.map(\.id) }
        )
    }

    /// D6: max(1, ceil(m / 80))。距離 0 でも「徒歩0分」とは書かない。非数・負は 1 分に倒す。
    public static func walkingMinutes(meters: Double) -> Int {
        guard meters.isFinite, meters > 0 else { return 1 }
        let minutes = (meters / Tuning.walkingMetersPerMinute).rounded(.up)
        return max(1, Int(min(minutes, 100_000)))
    }

    /// 近い順。同じ距離は渡された順（= チェーンの出現順）を保つ。`sorted` の安定性に頼らず添字で決める。
    static func orderedLines(_ lines: [BranchLine]) -> [BranchLine] {
        lines.enumerated()
            .sorted { a, b in
                if a.element.meters != b.element.meters { return a.element.meters < b.element.meters }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// 品目はタスク順。完全一致の重複は 1 つにする（正規化して同じ品目は D5 で入らないので、残るのは完了済みとの再追加など）。
    private static func itemsText(_ tasks: [TodoTask]) -> String {
        var seen = Set<String>()
        var items: [String] = []
        for t in tasks where seen.insert(t.item).inserted { items.append(t.item) }
        return items.joined(separator: "、")
    }

    // MARK: 閉店の表記

    /// 「21時まで」「21:30まで」「翌1時まで」「24時まで」「24時間営業」「営業時間不明」「営業時間外」。
    /// 日付の比較は店のタイムゾーン（`hours.timeZone`）。
    public static func closingText(_ hours: OpeningHours?, now: Date) -> String {
        guard let hours else { return "営業時間不明" }
        switch hours.status(at: now) {
        case .closed:
            return "営業時間外"   // 営業時間チェックを切っているときだけここに来る
        case .open(let closesAt):
            guard let closesAt, closesAt.timeIntervalSince(now) <= 24 * 60 * 60 else { return "24時間営業" }
            return closingClock(closesAt, now: now, timeZone: hours.timeZone)
        }
    }

    private static func closingClock(_ closesAt: Date, now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let nowDay = cal.startOfDay(for: now)
        let closeDayStart = cal.startOfDay(for: closesAt)
        var dayOffset = cal.dateComponents([.day], from: nowDay, to: closeDayStart).day ?? 0
        let c = cal.dateComponents([.hour, .minute], from: closesAt)
        var hour = c.hour ?? 0
        let minute = c.minute ?? 0
        // ちょうど 0 時の閉店は「その前日の 24 時」と書く（24:00 閉店）。
        if closesAt == closeDayStart {
            dayOffset -= 1
            hour = 24
        }
        let prefix = dayOffset <= 0 ? "" : (dayOffset == 1 ? "翌" : "\(dayOffset)日後")
        let clock = minute == 0 ? "\(hour)時" : "\(hour):" + String(format: "%02d", minute)
        return "\(prefix)\(clock)まで"
    }
}
