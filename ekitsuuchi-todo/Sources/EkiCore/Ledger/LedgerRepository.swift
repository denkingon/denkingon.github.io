import Foundation

public enum LedgerError: Error, Equatable {
    /// 店・品目などの必須欄が空（前後の空白を除いて）。値は欄の名前（"store" / "item" / "chain" / "key"）。
    case emptyField(String)
}

extension LedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyField(let name):
            switch name {
            case "store": return "店が空です。"
            case "item": return "品目が空です。"
            case "chain": return "チェーン名が空です。"
            default: return "\(name) が空です。"
            }
        }
    }
}

public enum AddTaskResult: Equatable, Sendable {
    case added(TodoTask)
    /// 同じ店＋品目が完了していない状態で既にある（D5）。追加はしていない。
    case duplicate(existing: TodoTask)
}

/// 台帳の唯一の書き手。台帳は 1 つのメモリ上の値で、変更はすべて `mutate` を通る。
///
/// 同時実行の肝（actor の再入）: `mutate` は同期で、本体の実行から保存・公開まで一度も中断しない（await が無い）。
/// だから 200 個の `addTask` が同時に来ても、互いの変更を上書きせず直列に積まれる。
/// この関数の中に await を足さないこと。足した瞬間に別の変更が割り込み、読んだ値が古くなる。
///
/// 失敗の扱い: 本体が投げる、または保存に失敗したら、メモリ上の台帳は変わらず、購読者にも流さない
/// （ディスクに無い状態を画面だけが持つ、を作らない）。保存の失敗は呼び出し元へ必ず投げる。
public actor LedgerRepository {
    private let store: LedgerStore
    private var ledger: Ledger
    private var subscribers: [UUID: AsyncStream<Ledger>.Continuation] = [:]

    private init(store: LedgerStore, ledger: Ledger) {
        self.store = store
        self.ledger = ledger
    }

    /// 台帳を読んで開く。`LedgerStoreError.corrupt` / `.newerSchema` はそのまま投げる（空の台帳で続行しない）。
    public static func open(store: LedgerStore) async throws -> LedgerRepository {
        var loaded = try store.load()
        normalise(&loaded)
        return LedgerRepository(store: store, ledger: loaded)
    }

    deinit {
        for c in subscribers.values { c.finish() }
    }

    // MARK: - 読み取り・購読

    public func snapshot() -> Ledger { ledger }

    /// 今の台帳を即座に 1 回流し、以後は変更が保存されるたびに流す。購読者は何人でも。
    /// 遅い購読者には最新の 1 件だけ残す（台帳は丸ごとの写しなので、途中の版は要らない）。
    /// 受け手が終わる・キャンセルされる・ストリームを手放すと購読は自動で外れる。
    public func updates() -> AsyncStream<Ledger> {
        let (stream, continuation) = AsyncStream<Ledger>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(ledger)
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// テスト用。
    var subscriberCount: Int { subscribers.count }

    // MARK: - 変更の唯一の入口

    /// コピーに対して `body` を実行 → 正規化（履歴の上限）→ 保存 → 公開。
    /// 中身が変わらなければ保存も公開もしない。`body` か保存が投げたら何も変わらない。
    @discardableResult
    public func mutate<T>(_ body: (inout Ledger) throws -> T) throws -> T {
        var working = ledger
        let result = try body(&working)
        Self.normalise(&working)
        if working != ledger {
            try store.save(working)
            ledger = working
            for c in subscribers.values { c.yield(working) }
        }
        return result
    }

    private static func normalise(_ ledger: inout Ledger) {
        let cap = Tuning.maxHistoryRecords
        if ledger.history.count > cap {
            // 追記順（古い→新しい）なので先頭から捨てる。
            ledger.history.removeFirst(ledger.history.count - cap)
        }
    }

    // MARK: - タスク

    /// 店・品目の前後の空白を除いて追加する。空なら `LedgerError.emptyField`。
    /// 同じ店＋品目が完了していない状態で既にあれば追加せず `.duplicate`（D5）。
    /// チェーンの店登録（Places）は呼び出し側の仕事: 追加後に `registeredChains` を見て ChainRegistrar を呼ぶ。
    public func addTask(
        store storeName: String,
        item: String,
        source: String = TodoTask.manualSource,
        sourceDate: CalendarDay? = nil,
        now: Date = Date()
    ) throws -> AddTaskResult {
        let storeName = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return try mutate { ledger in
            guard !storeName.isEmpty else { throw LedgerError.emptyField("store") }
            guard !item.isEmpty else { throw LedgerError.emptyField("item") }
            if let existing = TaskDedupe.existing(store: storeName, item: item, in: ledger.tasks) {
                return .duplicate(existing: existing)
            }
            let task = TodoTask(
                store: storeName,
                item: item,
                source: trimmedSource.isEmpty ? TodoTask.manualSource : trimmedSource,
                sourceDate: sourceDate,
                createdAt: now
            )
            ledger.tasks.append(task)
            return .added(task)
        }
    }

    /// 完了にする。完了済みのものは完了日を変えない。
    public func complete(taskIDs: [UUID], at now: Date = Date()) throws {
        let ids = Set(taskIDs)
        try mutate { ledger in
            for i in ledger.tasks.indices where ids.contains(ledger.tasks[i].id) && ledger.tasks[i].status != .done {
                ledger.tasks[i].status = .done
                ledger.tasks[i].completedAt = now
                ledger.tasks[i].ignoredUntil = nil
            }
        }
    }

    /// 無視にする（D2）。
    /// - `untilTomorrow == true`（通知の「今日は無視」）: `ignoredUntil` = 端末のタイムゾーンでの翌日 0 時。
    ///   その時刻を過ぎると `TodoTask.isPending(at:)` が再び真になる。
    /// - `false`（台帳画面の「無視」）: `ignoredUntil = nil`、戻す（reopen）まで無期限。
    /// 完了済みのタスクは無視にしない（完了を巻き戻さない）。
    public func ignore(taskIDs: [UUID], untilTomorrow: Bool, now: Date = Date(), timeZone: TimeZone = .current) throws {
        let ids = Set(taskIDs)
        let until: Date? = untilTomorrow ? Self.nextLocalMidnight(after: now, timeZone: timeZone) : nil
        try mutate { ledger in
            for i in ledger.tasks.indices where ids.contains(ledger.tasks[i].id) && ledger.tasks[i].status != .done {
                ledger.tasks[i].status = .ignored
                ledger.tasks[i].completedAt = nil
                ledger.tasks[i].ignoredUntil = until
            }
        }
    }

    /// `now` を含む暦日の翌日 0 時（`timeZone` の暦）。`now` ちょうどが 0 時でも「次の」0 時を返す。
    static func nextLocalMidnight(after now: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfToday = cal.startOfDay(for: now)
        // 暦の翌日（夏時間のある地域で 86400 秒足さない）。取れなければ 24 時間後で代用。
        return cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
    }

    /// 未完了に戻す。完了日・無視の期限を消す。
    public func reopen(taskIDs: [UUID]) throws {
        let ids = Set(taskIDs)
        try mutate { ledger in
            for i in ledger.tasks.indices where ids.contains(ledger.tasks[i].id) {
                ledger.tasks[i].status = .pending
                ledger.tasks[i].completedAt = nil
                ledger.tasks[i].ignoredUntil = nil
            }
        }
    }

    public func delete(taskIDs: [UUID]) throws {
        let ids = Set(taskIDs)
        try mutate { ledger in
            ledger.tasks.removeAll { ids.contains($0.id) }
        }
    }

    // MARK: - 駅

    /// 同じ id があれば置き換え、無ければ末尾に追加。
    public func upsertStation(_ station: Station) throws {
        try mutate { ledger in
            if let i = ledger.stations.firstIndex(where: { $0.id == station.id }) {
                ledger.stations[i] = station
            } else {
                ledger.stations.append(station)
            }
        }
    }

    /// 駅を消し、その駅を最寄りに持っていた支店から駅を外す。駅が 0 になった支店は消す
    /// （最初から最寄り駅を持たない支店には触らない）。履歴は残す（駅名を持っているので読める）。
    public func removeStation(id: UUID) throws {
        try mutate { ledger in
            ledger.stations.removeAll { $0.id == id }
            var kept: [Branch] = []
            for var branch in ledger.branches {
                let before = branch.nearestStations.count
                branch.nearestStations.removeAll { $0.stationID == id }
                if before > 0 && branch.nearestStations.isEmpty { continue }
                kept.append(branch)
            }
            ledger.branches = kept
        }
    }

    // MARK: - チェーン・支店

    /// 台帳に「店として使える名前」を記録する。`ChainName.key` が同じものが既にあれば何もしない（最初の表記を残す）。
    /// Places の取得は ChainRegistrar の仕事で、ここは名前の記録だけ。
    public func registerChain(_ name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutate { ledger in
            guard !ChainName.key(name).isEmpty else { throw LedgerError.emptyField("chain") }
            if !ledger.registeredChains.contains(where: { ChainName.matches($0, name) }) {
                ledger.registeredChains.append(name)
            }
        }
    }

    /// 登録を外し、そのチェーンの支店も消す。タスクは残す（また登録すれば使える）。
    public func unregisterChain(_ name: String) throws {
        try mutate { ledger in
            ledger.registeredChains.removeAll { ChainName.matches($0, name) }
            ledger.branches.removeAll { ChainName.matches($0.chainName, name) }
        }
    }

    /// 支店の属性（規模=大型 など）。`value == nil` で消す。空白だけの値も消す（画面で空欄にしたとき）。
    /// 知らない支店 id は何もしない。
    public func setBranchAttribute(branchID: String, key: String, value: String?) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutate { ledger in
            guard !key.isEmpty else { throw LedgerError.emptyField("key") }
            guard let i = ledger.branches.firstIndex(where: { $0.id == branchID }) else { return }
            if let value, !value.isEmpty {
                ledger.branches[i].attributes[key] = value
            } else {
                ledger.branches[i].attributes[key] = nil
            }
        }
    }

    // MARK: - 履歴・設定

    /// 追記。上限（`Tuning.maxHistoryRecords`）を超えたら古いものから捨てる。
    public func appendHistory(_ record: NotificationRecord) throws {
        try mutate { ledger in
            ledger.history.append(record)
        }
    }

    public func updateSettings(_ change: (inout Settings) -> Void) throws {
        try mutate { ledger in
            change(&ledger.settings)
        }
    }

    // MARK: - 取込

    /// 取り込み（M4）。重複の規則は `addTask` と同じ（D5）で、同じファイル内の重複も弾く。
    /// 全体で 1 回の保存・1 回の公開。店または品目が空の項目は `invalid` に数えて入れない。
    public func importItems(_ items: [InflowItem], now: Date = Date()) throws -> ImportSummary {
        try mutate { ledger in
            var summary = ImportSummary()
            var needing: [String] = []
            var seenKeys = Set(ledger.registeredChains.map(ChainName.key))
            // 完了していない既存タスクの署名を 1 回だけ作る（件数 × 件数の NFKC を避ける）。
            var liveSignatures = Set(ledger.tasks.lazy.filter { $0.status != .done }
                .compactMap { TaskDedupe.signature(store: $0.store, item: $0.item) })
            for raw in items {
                let storeName = raw.store.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = raw.item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ChainName.key(storeName).isEmpty, !item.isEmpty else {
                    summary.invalid += 1
                    continue
                }
                let key = ChainName.key(storeName)
                if seenKeys.insert(key).inserted { needing.append(storeName) }

                guard let signature = TaskDedupe.signature(store: storeName, item: item),
                      liveSignatures.insert(signature).inserted else {
                    summary.duplicates += 1
                    continue
                }
                let source = raw.source.trimmingCharacters(in: .whitespacesAndNewlines)
                let task = TodoTask(
                    store: storeName,
                    item: item,
                    source: source.isEmpty ? TaskImporter.defaultSource : source,
                    sourceDate: raw.date,
                    createdAt: now
                )
                ledger.tasks.append(task)
                summary.added.append(task)
            }
            summary.chainsNeedingRegistration = needing
            return summary
        }
    }
}
