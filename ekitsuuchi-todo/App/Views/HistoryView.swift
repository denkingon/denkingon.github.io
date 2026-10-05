import EkiCore
import SwiftUI

// MARK: - 履歴 画面（コンテンツ設計書 §3）
//
// 発火・抑制の記録。新しい順。「なぜ鳴った／鳴らなかった」が 1 行で読めること、
// そして M1（1 週間の実測）で駅の半径を決めるための道具であることが役目。
// 読むだけの画面で、台帳への書き込みは無い。配色は無彩色のみ。
// 発火と抑制の差は色ではなく濃淡（太字／灰色）と、失敗の「!」で示す。

// MARK: 絞り込み

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case notified
    case suppressed
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "すべて"
        case .notified: return "通知"
        case .suppressed: return "抑制"
        case .failed: return "失敗"
        }
    }

    func includes(_ result: NotificationResult) -> Bool {
        switch self {
        case .all: return true
        case .notified: return HistoryKind(result) == .notified
        case .suppressed: return HistoryKind(result) == .suppressed
        case .failed: return HistoryKind(result) == .failed
        }
    }
}

/// 結果を 3 つの見た目に分ける。`NotificationResult.isSuppression` は failedToPost も true にするので、ここで分け直す。
private enum HistoryKind {
    case notified
    case suppressed
    case failed

    init(_ result: NotificationResult) {
        switch result {
        case .notified, .diagnosticNotified: self = .notified
        case .failedToPost: self = .failed
        case .suppressedClosed, .suppressedAlreadyNotifiedToday, .suppressedNoPendingTasks, .suppressedNoBranch:
            self = .suppressed
        }
    }
}

// MARK: 文言の組み立て（行と書き出しで同じ文を使う）

private enum HistoryFormat {
    // DateFormatter は固定書式。en_US_POSIX で 24 時間表記・半角数字に固定し、時刻帯は端末の現在の地域に追従させる。
    private static func makeFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = pattern
        return formatter
    }

    private static let rowFormatter = makeFormatter("M/d HH:mm")
    /// 書き出しは年も入れる（共有した先で、年をまたいだ記録が読めるように）。
    private static let exportFormatter = makeFormatter("yyyy-MM-dd HH:mm")

    static func rowTime(_ date: Date) -> String { rowFormatter.string(from: date) }
    static func exportTime(_ date: Date) -> String { exportFormatter.string(from: date) }

    /// 距離・精度の m 表示。NaN や巨大値で `Int` への変換が落ちないようにする。
    static func meters(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 1_000_000_000 else { return "—" }
        return String(Int(value.rounded()))
    }

    /// `M/d HH:mm  駅名  結果`。失敗は先頭に「!」（色を使わずに目立たせる）。
    static func headline(for record: NotificationRecord) -> String {
        let base = "\(rowTime(record.firedAt))  \(record.stationName)  \(record.result.label)"
        return HistoryKind(record.result) == .failed ? "! " + base : base
    }

    /// 発火時刻とこの秒数以上ずれた位置は「発火の瞬間の位置」ではない（CoreLocation の古いキャッシュ）。
    static let staleFixSeconds: TimeInterval = 60

    /// その位置が発火の瞬間のものと見なせるか。古い位置は距離の実測に使わない（半径を誤って決めないため）。
    static func isFresh(_ record: NotificationRecord, _ fix: LocationFix) -> Bool {
        let age = abs(record.firedAt.timeIntervalSince(fix.timestamp))
        return age.isFinite && age < staleFixSeconds
    }

    /// 発火位置の行。`駅から 120m・精度 ±15m・半径内`。
    /// 駅が削除済みなら距離と半径内外は出さない。位置が古いときは、そのことも添える（古い位置は距離の測定に使えないため）。
    static func positionLine(for record: NotificationRecord, station: Station?) -> String? {
        guard let fix = record.location else { return nil }
        // 負の精度は CoreLocation が「無効な位置」とした印（Core の LocationFix の注記）。
        guard fix.horizontalAccuracy >= 0 else { return "位置を取得できませんでした（無効な位置）" }

        var parts: [String] = []
        var inside: Bool?
        if let station {
            let distance = station.coordinate.distance(to: fix.coordinate)
            parts.append("駅から \(meters(distance))m")
            if distance.isFinite { inside = distance <= station.radiusMeters }
        }
        parts.append("精度 ±\(meters(fix.horizontalAccuracy))m")
        if let inside { parts.append(inside ? "半径内" : "半径外") }

        let age = abs(record.firedAt.timeIntervalSince(fix.timestamp))
        if age.isFinite, age >= staleFixSeconds {
            parts.append("位置は\(ageText(age))前のもの")
        }
        return parts.joined(separator: "・")
    }

    private static func ageText(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))分" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))時間" }
        return "\(Int(min(seconds, 86_400 * 3650) / 86_400))日"
    }

    /// 書き出しの 1 行（改行を含む補足があっても 1 行に収める）。
    static func exportLine(for record: NotificationRecord, station: Station?) -> String {
        var line = "\(exportTime(record.firedAt))  \(record.stationName)  \(record.result.label)"
        if let detail = oneLine(record.detail) { line += "  \(detail)" }
        if let position = positionLine(for: record, station: station) { line += "  [\(position)]" }
        return line
    }

    static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? nil : flattened
    }
}

// MARK: 実測の集計

/// 駅ごとの発火の実測。半径を決める数字（M1）。
private struct StationStats: Identifiable {
    let id: UUID
    let name: String
    let radius: Double
    /// この駅の記録の数（結果によらず、入域のたびに 1 件残る）。
    let fireCount: Int
    /// そのうち、使える位置が付いていたもの。
    let measuredCount: Int
    let median: Double?
    let maximum: Double?
    /// 位置が半径の外だった発火の数。
    let outsideCount: Int

    static func make(stations: [Station], history: [NotificationRecord]) -> [StationStats] {
        var byStation: [UUID: [NotificationRecord]] = [:]
        for record in history {
            byStation[record.stationID, default: []].append(record)
        }
        return stations.map { station in
            let records = byStation[station.id] ?? []
            var distances: [Double] = []
            for record in records {
                // 無効な位置・古い位置は距離に数えない（行には「位置は〜前のもの」と出るので、集計も同じ扱いにそろえる）。
                guard let fix = record.location, fix.horizontalAccuracy >= 0, HistoryFormat.isFresh(record, fix) else { continue }
                let distance = station.coordinate.distance(to: fix.coordinate)
                if distance.isFinite { distances.append(distance) }
            }
            distances.sort()
            let median: Double?
            if distances.isEmpty {
                median = nil
            } else if distances.count % 2 == 1 {
                median = distances[distances.count / 2]
            } else {
                let upper = distances.count / 2
                median = (distances[upper - 1] + distances[upper]) / 2
            }
            return StationStats(
                id: station.id,
                name: station.name,
                radius: station.radiusMeters,
                fireCount: records.count,
                measuredCount: distances.count,
                median: median,
                maximum: distances.last,
                outsideCount: distances.filter { $0 > station.radiusMeters }.count
            )
        }
    }

    var summaryLine: String {
        if fireCount == 0 { return "まだ発火していません" }
        guard let median, let maximum else { return "使える位置の記録がありません" }
        var text = "中央値 \(HistoryFormat.meters(median))m・最大 \(HistoryFormat.meters(maximum))m"
        if outsideCount > 0 { text += "・半径外 \(outsideCount) 回" }
        if measuredCount < fireCount { text += "（距離は \(measuredCount) 回ぶん）" }
        return text
    }
}

// MARK: - 画面

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    @State private var filter: HistoryFilter = .all
    @State private var showStats = false

    var body: some View {
        let ledger = model.ledger
        // 台帳の history は追記順（古い→新しい）。時刻の新しい順に並べ直す。
        // 同時刻は追記順の新しい方を上にする（並べ替えが安定でなくても行が入れ替わらないように）。
        let all = ledger.history.enumerated()
            .sorted { lhs, rhs in
                lhs.element.firedAt != rhs.element.firedAt
                    ? lhs.element.firedAt > rhs.element.firedAt
                    : lhs.offset > rhs.offset
            }
            .map(\.element)
        let visible = all.filter { filter.includes($0.result) }
        let stationsByID = Dictionary(
            ledger.stations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return NavigationStack {
            VStack(spacing: 0) {
                if all.isEmpty {
                    emptyState
                } else {
                    header(all: all)
                    recordList(ledger: ledger, all: all, visible: visible, stationsByID: stationsByID)
                }
            }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: exportText(visible: visible, stationsByID: stationsByID))
                        .disabled(visible.isEmpty)
                }
            }
        }
    }

    // MARK: 上部

    private var emptyState: some View {
        ContentUnavailableView(
            "履歴はまだありません",
            systemImage: "clock.arrow.circlepath",
            description: Text("駅に入ると、通知した・抑制した・通知に失敗した記録がここに1行ずつ残ります。")
        )
    }

    private func header(all: [NotificationRecord]) -> some View {
        var notified = 0
        var suppressed = 0
        var failed = 0
        for record in all {
            switch HistoryKind(record.result) {
            case .notified: notified += 1
            case .suppressed: suppressed += 1
            case .failed: failed += 1
            }
        }
        return VStack(spacing: 6) {
            Picker("絞り込み", selection: $filter) {
                ForEach(HistoryFilter.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Text("全 \(all.count) 件・通知 \(notified)・抑制 \(suppressed)・失敗 \(failed)")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: 一覧

    private func recordList(
        ledger: Ledger,
        all: [NotificationRecord],
        visible: [NotificationRecord],
        stationsByID: [UUID: Station]
    ) -> some View {
        // 集計は絞り込みに関係なく全履歴から出す（入域は結果によらず発火 1 回）。
        let stats = StationStats.make(stations: ledger.stations, history: all)
        return List {
            Section {
                DisclosureGroup("実測の集計", isExpanded: $showStats) {
                    statsContent(stats)
                }
            }
            Section {
                if visible.isEmpty {
                    Text("「\(filter.label)」に当てはまる記録はありません")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(visible) { record in
                        HistoryRow(record: record, station: stationsByID[record.stationID])
                    }
                }
            } header: {
                Text("\(visible.count) 件")
            }
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: [StationStats]) -> some View {
        if stats.isEmpty {
            Text("登録されている駅がありません")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        } else {
            ForEach(stats) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text("半径 \(HistoryFormat.meters(item.radius))m")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        Spacer(minLength: 0)
                        Text("発火 \(item.fireCount) 回")
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                    }
                    Text(item.summaryLine)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text("距離は駅の座標から発火時の位置までの直線距離です。位置が取れなかった発火と、位置が発火の 1 分以上前のものだった発火は、距離に含めません。")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: 書き出し

    private func exportText(visible: [NotificationRecord], stationsByID: [UUID: Station]) -> String {
        var lines = ["駅通知todo 履歴（\(filter.label)・\(visible.count) 件・新しい順）"]
        for record in visible {
            lines.append(HistoryFormat.exportLine(for: record, station: stationsByID[record.stationID]))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 行

private struct HistoryRow: View {
    let record: NotificationRecord
    let station: Station?

    private var kind: HistoryKind { HistoryKind(record.result) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HistoryFormat.headline(for: record))
                .font(.subheadline.weight(headlineWeight))
                .foregroundStyle(kind == .suppressed ? Color.secondary : Color.primary)
            if let detail = HistoryFormat.oneLine(record.detail) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            if let position = HistoryFormat.positionLine(for: record, station: station) {
                Text(position)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 通知は太字、抑制は細字＋灰色、失敗は中太字＋「!」。
    private var headlineWeight: Font.Weight {
        switch kind {
        case .notified: return .bold
        case .suppressed: return .regular
        case .failed: return .semibold
        }
    }
}
