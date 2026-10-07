import Foundation

/// 駅入域イベント → 判定 → 履歴 → 通知（§4 駅入域時）。ジオフェンスの発火から呼ばれる。
///
/// 原子性: 判定と履歴の追記は `repository.mutate` の 1 回の中で行う。`mutate` は途中で中断されないので、
/// 同時に来た 2 つの入域が両方「今日未通知」を見て 2 通出す、ということが起きない（後から来た方は先の記録を見て抑制される）。
/// 通知（`poster.post`）は必ずその mutate の後。台帳の書き込みの中で外部 I/O を待たない。
public struct StationEntryHandler: Sendable {
    private let repository: LedgerRepository
    private let poster: NotificationPosting
    private let timeZone: @Sendable () -> TimeZone

    /// `timeZone` は入域のたびに読む（端末のタイムゾーンは旅行で変わる。D14）。
    public init(
        repository: LedgerRepository,
        poster: NotificationPosting,
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.repository = repository
        self.poster = poster
        self.timeZone = timeZone
    }

    /// 駅が台帳に無い・無効（古いイベント）なら何も記録せず nil。
    /// 履歴を保存できなかったら投げる（通知も出さない: 記録できない通知を出すと、次の入域でまた出てしまう）。
    /// 通知の失敗は投げず、履歴を `.failedToPost` に書き換えて返す（D9）。
    public func handle(_ event: TriggerEvent) async throws -> JudgeOutcome? {
        let zone = timeZone()
        let outcome: JudgeOutcome? = try await repository.mutate { ledger in
            guard let station = ledger.station(id: event.stationID), station.isEnabled else { return nil }
            let outcome = NotificationJudge.judge(JudgeContext(
                ledger: ledger,
                station: station,
                now: event.firedAt,
                timeZone: zone,
                location: event.location
            ))
            ledger.history.append(outcome.record)
            return outcome
        }
        guard var outcome else { return nil }
        guard let content = outcome.notification else { return outcome }

        do {
            try await poster.post(content)
        } catch {
            let recordID = outcome.record.id
            let detail = "通知を出せませんでした: \(Self.reason(error))"
            // 失敗は「今日通知済」に数えない（.failedToPost は頻度の門が見ない）ので、次の入域でまた出せる。
            try await repository.mutate { ledger in
                if let i = ledger.history.lastIndex(where: { $0.id == recordID }) {
                    ledger.history[i].result = .failedToPost
                    ledger.history[i].detail = detail
                }
            }
            outcome.record.result = .failedToPost
            outcome.record.detail = detail
            outcome.notification = nil
        }
        return outcome
    }

    private static func reason(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        return String(describing: error)
    }
}
