import Foundation

public struct JudgeContext: Sendable {
    public var ledger: Ledger
    public var station: Station
    public var now: Date
    /// 端末のタイムゾーン。「今日通知済」の暦日はこれで切る（D14）。営業時間は店の側のゾーンで見る。
    public var timeZone: TimeZone
    public var location: LocationFix?

    public init(ledger: Ledger, station: Station, now: Date, timeZone: TimeZone, location: LocationFix? = nil) {
        self.ledger = ledger
        self.station = station
        self.now = now
        self.timeZone = timeZone
        self.location = location
    }
}

public struct JudgeOutcome: Equatable, Sendable {
    public var record: NotificationRecord
    /// nil = 通知しない（抑制）。
    public var notification: NotificationContent?

    public init(record: NotificationRecord, notification: NotificationContent? = nil) {
        self.record = record
        self.notification = notification
    }
}

/// 駅入域時の判定（コンテンツ設計書 §4）。通信なし・時刻は引数の純粋関数。
/// 門の順: 未完了 → 支店 → 営業中 → 今日通知済。どこで止まっても履歴の 1 行になる。
/// 鉄則: 抑制は「今日」を消費しない。頻度の門は `.notified` の履歴だけを数えるので、
/// 営業時間外・失敗・実測通知で止まった日も、次の入域でちゃんと判定し直される。
public enum NotificationJudge {
    public static func judge(_ context: JudgeContext, recordID: UUID = UUID()) -> JudgeOutcome {
        let ledger = context.ledger
        let station = context.station
        let settings = ledger.settings
        let now = context.now

        func record(
            _ result: NotificationResult,
            branchIDs: [String] = [],
            taskIDs: [UUID] = [],
            detail: String? = nil
        ) -> NotificationRecord {
            NotificationRecord(
                id: recordID,
                stationID: station.id,
                stationName: station.name,
                branchIDs: branchIDs,
                taskIDs: taskIDs,
                firedAt: now,
                result: result,
                location: context.location,
                detail: detail
            )
        }

        // 0. 実測モード（D8）: 門を通さず駅名だけ。.diagnosticNotified は「今日通知済」に数えない。
        if settings.diagnosticMode {
            let content = NotificationContent(body: "\(station.name)に入った", stationID: station.id, taskIDs: [])
            return JudgeOutcome(record: record(.diagnosticNotified), notification: content)
        }

        // 1. 未完了タスク（「今日は無視」の期限切れを含む）。
        let pending = ledger.pendingTasks(at: now)
        guard !pending.isEmpty else {
            return JudgeOutcome(record: record(.suppressedNoPendingTasks, detail: "未完了のタスクがありません"))
        }

        // チェーンごとに束ねる（ChainName.key で同一視。出現順 = タスク順）。
        var groups: [ChainGroup] = []
        for task in pending {
            let key = ChainName.key(task.store)
            if let i = groups.firstIndex(where: { $0.key == key }) {
                groups[i].tasks.append(task)
            } else {
                groups.append(ChainGroup(key: key, name: task.store, tasks: [task]))
            }
        }

        // 2. この駅に支店があるか。一部のチェーンだけ無い（部分欠落）ときはそのチェーンだけ落とす。
        var dropped: [Int: String] = [:]          // groups の添字 → 除外理由（detail 用）
        var candidates: [(index: Int, branches: [(branch: Branch, meters: Double)])] = []
        for (i, g) in groups.enumerated() {
            // ledger 側の並びは近い順だが、同距離の順序を実装任せにしないよう id で決める。
            let found = ledger.branches(ofChain: g.name, nearStation: station.id)
                .sorted { ($0.meters, $0.branch.id) < ($1.meters, $1.branch.id) }
            if found.isEmpty {
                dropped[i] = noBranchReason
            } else {
                candidates.append((i, found))
            }
        }
        guard !candidates.isEmpty else {
            let names = groups.map(\.name).joined(separator: "、")
            return JudgeOutcome(record: record(.suppressedNoBranch, taskIDs: pending.map(\.id), detail: "この駅に支店がありません: \(names)"))
        }

        // 3. 営業中（閉店まで余裕あり）。チェーンごとに「開いている一番近い支店」を選ぶ（D4: 時間不明は開いている扱い）。
        var chosen: [(index: Int, branch: Branch, meters: Double)] = []
        var closedLines: [(index: Int, text: String, branchID: String)] = []
        for (i, found) in candidates {
            guard settings.checkBusinessHours else {
                chosen.append((i, found[0].branch, found[0].meters))
                continue
            }
            if let open = found.first(where: { isOpenEnough($0.branch, at: now) }) {
                chosen.append((i, open.branch, open.meters))
            } else {
                // 最寄りの支店が止まった理由を 1 行に。
                let nearest = found[0].branch
                let reason = closedReason(nearest, at: now) ?? "営業時間外"
                closedLines.append((i, "\(nearest.name)は\(reason)", nearest.id))
                dropped[i] = reason
            }
        }
        guard !chosen.isEmpty else {
            var detail = closedLines.map(\.text).joined(separator: "、")
            let noBranch = groups.indices.filter { dropped[$0] == noBranchReason }.map { groups[$0].name }
            if !noBranch.isEmpty { detail += "（支店なし: \(noBranch.joined(separator: "、"))）" }
            let reached = closedLines.flatMap { groups[$0.index].tasks.map(\.id) }
            return JudgeOutcome(record: record(.suppressedClosed, branchIDs: closedLines.map(\.branchID), taskIDs: reached, detail: detail))
        }

        // 通知に載る内容。ここから先は通知するかしないかだけで、載る中身は変わらない。
        let lines = chosen.map { BranchLine(branch: $0.branch, meters: $0.meters, tasks: groups[$0.index].tasks) }
        let content = NotificationComposer.compose(station: station, lines: lines, now: now, timeZone: context.timeZone)
        let shownBranchIDs = NotificationComposer.orderedLines(lines).map(\.branch.id)

        // 4. 今日通知済か（`.notified` だけを数える）。
        if let earlier = alreadyNotifiedToday(context) {
            let at = clock(earlier.firedAt, timeZone: context.timeZone)
            let suffix = earlier.stationID == station.id ? "" : "（\(earlier.stationName)）"
            return JudgeOutcome(record: record(
                .suppressedAlreadyNotifiedToday,
                branchIDs: shownBranchIDs,
                taskIDs: content.taskIDs,
                detail: "今日 \(at) に通知済\(suffix)"
            ))
        }

        // 5. 通知する。
        var detail: String?
        if !dropped.isEmpty {
            let parts = dropped.keys.sorted().map { "\(groups[$0].name)（\(dropped[$0] ?? "")）" }
            detail = "除外: " + parts.joined(separator: "、")
        }
        return JudgeOutcome(
            record: record(.notified, branchIDs: shownBranchIDs, taskIDs: content.taskIDs, detail: detail),
            notification: content
        )
    }

    // MARK: - 部品

    private static let noBranchReason = "支店なし"

    private struct ChainGroup {
        var key: String
        var name: String
        var tasks: [TodoTask]
    }

    private static func isOpenEnough(_ branch: Branch, at now: Date) -> Bool {
        guard let hours = branch.hours else { return true }   // D4
        return hours.isOpen(at: now, minimumRemainingMinutes: Tuning.closingMarginMinutes)
    }

    /// 開いていない理由（開いていれば nil）。「営業時間外」「閉店まで20分」。
    private static func closedReason(_ branch: Branch, at now: Date) -> String? {
        guard let hours = branch.hours, !isOpenEnough(branch, at: now) else { return nil }
        switch hours.status(at: now) {
        case .closed:
            return "営業時間外"
        case .open(let closesAt):
            guard let closesAt else { return nil }
            let minutes = Int(max(0, closesAt.timeIntervalSince(now)) / 60)   // 切り捨て: 余裕が足りない側に正直に
            return minutes == 0 ? "閉店まで1分未満" : "閉店まで\(minutes)分"
        }
    }

    /// 頻度の設定に従って、今日すでに通知した記録（あれば最新）。`.notified` だけが「消費」になる。
    private static func alreadyNotifiedToday(_ c: JudgeContext) -> NotificationRecord? {
        let today = CalendarDay(date: c.now, timeZone: c.timeZone)
        let notifiedToday = c.ledger.history.filter {
            $0.result == .notified && CalendarDay(date: $0.firedAt, timeZone: c.timeZone) == today
        }
        switch c.ledger.settings.frequency {
        case .everyEntry:
            return nil
        case .perStationPerDay:
            return notifiedToday.filter { $0.stationID == c.station.id }.max { $0.firedAt < $1.firedAt }
        case .oncePerDay:
            return notifiedToday.max { $0.firedAt < $1.firedAt }
        }
    }

    private static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
