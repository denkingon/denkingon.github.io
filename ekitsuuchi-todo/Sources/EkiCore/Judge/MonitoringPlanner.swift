import Foundation

/// 領域監視の計画（§4 監視の停止 / §2 制約: 20 個まで）。純粋関数。
public enum MonitoringPlanner {
    public static func plan(ledger: Ledger, now: Date, deviceLocation: Coordinate?) -> MonitoringPlan {
        // `now` は今は使わない: D13 は「ignoredUntil が入っていれば（過ぎていても）続ける」なので時刻に依存しない。
        // 期限が過ぎた無視は次の入域で未完了として拾われ、拾われなければ監視を続けても害はない。
        _ = now
        guard isMonitoringNeeded(ledger) else { return .stopped }

        let enabled = ledger.stations.filter(\.isEnabled)
        let cap = Tuning.regionMonitoringCap
        guard enabled.count > cap else {
            return MonitoringPlan(stations: enabled, tracksSignificantLocationChanges: false)
        }

        // 上限超え: 端末に近い順に cap 個。位置が分からなければ台帳の並びの先頭から。
        guard let device = deviceLocation else {
            return MonitoringPlan(stations: Array(enabled.prefix(cap)), tracksSignificantLocationChanges: true)
        }
        let ranked = enabled.enumerated().map { (offset: $0.offset, distance: distance(device, $0.element.coordinate)) }
            .sorted { a, b in
                // 同じ距離は台帳の並びが先。NaN は最後（distance() が無限大に倒す）。
                a.distance != b.distance ? a.distance < b.distance : a.offset < b.offset
            }
        let keep = Set(ranked.prefix(cap).map(\.offset))
        // 返す並びは台帳順に保つ: 端末が少し動いても同じ集合なら同じ計画になり、再登録が起きない。
        let stations = enabled.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        return MonitoringPlan(stations: stations, tracksSignificantLocationChanges: true)
    }

    /// D13: 実測モード / 未完了がある / 「今日は無視」で明日戻るタスクがある。
    /// 最後のタスクを「今日は無視」しただけでアプリが永久に黙るのを防ぐ。
    static func isMonitoringNeeded(_ ledger: Ledger) -> Bool {
        if ledger.settings.diagnosticMode { return true }
        return ledger.tasks.contains { task in
            switch task.status {
            case .pending: return true
            case .ignored: return task.ignoredUntil != nil
            case .done: return false
            }
        }
    }

    private static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let d = a.distance(to: b)
        return d.isFinite ? d : .infinity
    }
}
