import Foundation

public struct RefreshReport: Equatable, Sendable {
    /// 営業時間を取り直せた支店の数（Google が「営業時間なし」と答えた場合も、聞き直せたので含む）。
    public var refreshed: Int
    /// 支店 id → 失敗の理由。古いデータ・古い取得日時のまま（次回また対象になる）。
    public var failed: [String: String]
    /// 更新しなかった支店の数: 期限内、使っていないチェーン、途中で台帳から消えた、キャンセルで未着手。
    public var skipped: Int

    public init(refreshed: Int = 0, failed: [String: String] = [:], skipped: Int = 0) {
        self.refreshed = refreshed
        self.failed = failed
        self.skipped = skipped
    }
}

/// 週 1 更新（§4）: 未完了タスクに出てくるチェーンの支店のうち、最終取得から 7 日超のものだけ営業時間を取り直す。
public struct HoursRefresher: Sendable {
    private let repository: LedgerRepository
    private let hours: BusinessHoursProviding
    private let now: @Sendable () -> Date

    public init(
        repository: LedgerRepository,
        hours: BusinessHoursProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.hours = hours
        self.now = now
    }

    /// 期限切れの支店が 1 つでもあるか。BGTask を走らせるか・前面復帰で追いかけるかの判断に使う（通信しない）。
    public func isDue() async -> Bool {
        let ledger = await repository.snapshot()
        return !Self.dueBranchIDs(in: ledger, now: now()).isEmpty
    }

    public func refreshStale() async -> RefreshReport {
        let snapshot = await repository.snapshot()
        let due = Self.dueBranchIDs(in: snapshot, now: now())
        var report = RefreshReport()
        var results: [(id: String, hours: OpeningHours?)] = []

        // 通信は台帳の変更の外で、順番に。
        for id in due {
            if Task.isCancelled { break }
            do {
                results.append((id: id, hours: try await hours.openingHours(placeID: id)))
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                // 古いデータと古い取得日時を残す = 次回また対象になる。
                report.failed[id] = Self.message(error)
            }
        }

        // 取れた分は途中でキャンセルされても反映する（支店ごとに独立で、無駄にしない）。
        let fetchedAt = now()
        do {
            let applied: Int = try await repository.mutate { ledger in
                var count = 0
                for (id, answer) in results {
                    guard let i = ledger.branches.firstIndex(where: { $0.id == id }) else { continue }   // 通信中に消えた
                    // nil（Google に営業時間が無い）は古い営業時間を残すが、取得日時は進める: 毎回は聞き直さない。
                    if let answer { ledger.branches[i].hours = answer }
                    ledger.branches[i].hoursFetchedAt = fetchedAt
                    count += 1
                }
                return count
            }
            report.refreshed = applied
        } catch {
            for r in results { report.failed[r.id] = "保存に失敗しました: \(Self.message(error))" }
        }
        report.skipped = snapshot.branches.count - report.refreshed - report.failed.count
        return report
    }

    // MARK: - 対象の選び方

    /// 対象 = 完了していないタスク（未完了・無視）が使っているチェーンの支店で、期限切れのもの。
    static func dueBranchIDs(in ledger: Ledger, now: Date) -> [String] {
        let usedKeys = Set(ledger.tasks.filter { $0.status != .done }.map { ChainName.key($0.store) })
        return ledger.branches
            .filter { usedKeys.contains(ChainName.key($0.chainName)) && isStale($0, now: now) }
            .map(\.id)
    }

    /// 7 日ちょうどは期限内（「7 日超」= 厳密に超えたら）。未取得（nil）は常に期限切れ。
    static func isStale(_ branch: Branch, now: Date) -> Bool {
        guard let fetched = branch.hoursFetchedAt else { return true }
        return now.timeIntervalSince(fetched) > Double(Tuning.hoursRefreshAfterDays) * 86_400
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
