import BackgroundTasks
import EkiCore
import Foundation
import UserNotifications
import os

/// 台帳を開いたあとに使える部品一式（台帳が開けないと作れない）。
struct LedgerServices: Sendable {
    let repository: LedgerRepository
    let registrar: ChainRegistrar
    let refresher: HoursRefresher
    let entryHandler: StationEntryHandler
}

/// 台帳を開いた結果。`services == nil` のときは `error` に理由がある（画面が出す）。
struct LedgerOpenResult: Sendable {
    var services: LedgerServices?
    /// 台帳ファイルが壊れていて脇へ退避し、空の台帳で続けた、という知らせ。
    var warning: String?
    /// 台帳を開けなかった理由（新しい版のファイル・読み取り失敗など）。
    var error: String?
    /// 時間をおけば開けるかもしれない失敗（端末の初回アンロック前でファイルを読めない、など）。
    /// 新しい版のファイルのように、待っても変わらない失敗は false。
    var retryable = false
}

/// AppModel（画面側）が環境の変化を知るための合図。中身は `AppEnvironment` から読み直す。
enum EnvironmentEvent: Sendable {
    case authorizationChanged
    case planChanged
}

/// UI を持たない組み立て役（composition root）。
///
/// 駅入域（ジオフェンス）でアプリがバックグラウンド起動されたときは画面も AppModel も作られない。
/// そのとき通知まで届くのに要るもの（引き金・通知・台帳・判定器・通知ボタンの受け口）は全部ここに置く。
/// 画面側（AppModel）はここを読むだけで、ここは画面側を知らない。
///
/// `shared` の最初の参照は `AppDelegate.application(_:didFinishLaunchingWithOptions:)`（メインスレッド）で行うこと。
/// `GeofenceTrigger` の中の CLLocationManager はメインで作る必要があり、領域イベントの受け側も起動中に揃っている必要がある。
/// （AppModel の init はここに触らない。App 構造体の初期化が AppDelegate より先に走っても順序が崩れないように。）
final class AppEnvironment: @unchecked Sendable {
    // @unchecked Sendable の根拠: 公開しているプロパティは作成後に変わらない let。
    // 可変状態は `state`（Locked）の中だけ。Apple のオブジェクトを持つ部品は各自が自分の理由で Sendable を宣言している。
    static let shared = AppEnvironment()

    let trigger: GeofenceTrigger
    let poster: UserNotificationPoster
    let actionHandler: NotificationActionHandler
    let transport: URLSessionTransport
    let places: PlacesClient
    let stationSearch: StationSearch
    /// Places のキーが入っているか（値は見せない）。
    let placesConfigured: Bool
    let ledgerURL: URL

    static let lastHoursRefreshKey = "lastHoursRefresh"

    private typealias Observer = @Sendable (EnvironmentEvent) -> Void

    private struct State {
        var launched = false
        var openTask: Task<LedgerOpenResult, Never>?
        var planningTask: Task<Void, Never>?
        var latestLedger: Ledger?
        var appliedPlan: MonitoringPlan?
        var observer: Observer?
        var refreshingHours = false
    }

    private struct PlanChange {
        var observer: Observer?
    }

    private let state = Locked(State())

    private init() {
        let transport = URLSessionTransport()
        let apiKey = AppSecrets.placesAPIKey
        self.transport = transport
        self.places = PlacesClient(apiKey: apiKey, transport: transport)
        self.placesConfigured = !apiKey.isEmpty
        self.poster = UserNotificationPoster()
        self.actionHandler = NotificationActionHandler()
        self.stationSearch = StationSearch()
        self.ledgerURL = AppEnvironment.defaultLedgerURL()
        // メインスレッドで作る（クラスコメント参照）。delegate は GeofenceTrigger の init が付ける。
        self.trigger = GeofenceTrigger()
    }

    /// Application Support/EkiTsuuchi/ledger.json。ディレクトリは保存時に `JSONFileLedgerStore` が作る。
    /// ファイル保護は iOS の既定（初回アンロックまで）のまま。ロック中の入域でも読み書きできる必要がある。
    private static func defaultLedgerURL() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("EkiTsuuchi", isDirectory: true)
            .appendingPathComponent("ledger.json", isDirectory: false)
    }

    // MARK: 起動

    /// 何度呼んでも 1 回しか働かない。`application(_:didFinishLaunchingWithOptions:)` の中で、return する前に呼ぶ。
    /// （BGTaskScheduler の登録は return 前が必須。通知の delegate と領域イベントの受け口も、
    ///  バックグラウンド起動で保留イベントが届く前に揃えておく必要がある。）
    func launch() {
        let isFirst = state.withValue { s -> Bool in
            if s.launched { return false }
            s.launched = true
            return true
        }
        guard isFirst else { return }

        // delegate は weak。強参照はこのオブジェクトの `actionHandler` が持つ。
        UNUserNotificationCenter.current().delegate = actionHandler
        UserNotificationPoster.registerCategories()

        actionHandler.onAction = { [weak self] action in
            guard let self else { return }
            await self.perform(action)
        }
        trigger.onTrigger = { [weak self] event in
            guard let self else { return }
            Task { await self.handleTrigger(event) }
        }
        trigger.onSignificantMove = { [weak self] _ in
            guard let self else { return }
            // 位置が大きく動いた。駅が上限を超えているときの「近い 20 駅」を入れ替える。
            self.replan()
        }
        trigger.onAuthorizationChange = { [weak self] _ in
            guard let self else { return }
            // 許可が変わったら、計画が同じでも反映し直す（GeofenceTrigger は許可が出るまで領域の登録を見送っている）。
            self.replan(force: true)
            self.notify(.authorizationChanged)
        }

        BackgroundRefresh.register { [weak self] in
            guard let self else { return false }
            return await self.refreshHoursIfDue()
        }
        // 予約済みならそのまま残す。起動のたびに予約し直すと「24 時間後以降」が毎回先へ延びて、
        // 毎日起動される（入域のバックグラウンド起動を含む）アプリでは更新が一度も走らなくなる。
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            if !requests.contains(where: { $0.identifier == BackgroundRefresh.taskID }) {
                BackgroundRefresh.schedule()
            }
        }

        _ = ensureOpenTask()
        startPlanning()
    }

    // MARK: 台帳

    private func ensureOpenTask() -> Task<LedgerOpenResult, Never> {
        state.withValue { s -> Task<LedgerOpenResult, Never> in
            if let existing = s.openTask { return existing }
            let task = Task { await self.openLedger() }
            s.openTask = task
            return task
        }
    }

    /// 台帳を開く（開けるまで待つ）。開けなかったときは `services == nil`。
    /// 一時的な失敗（`retryable`）は覚えておかない。次に呼ばれたとき開き直す
    /// （端末の初回アンロック前に領域イベントで起動されると、ファイルを読めないことがある）。
    func openResult() async -> LedgerOpenResult {
        let task = ensureOpenTask()
        let result = await task.value
        if result.services == nil && result.retryable {
            state.withValue { (s: inout State) -> Void in
                if s.openTask == task { s.openTask = nil }
            }
        }
        return result
    }

    func services() async -> LedgerServices? {
        await openResult().services
    }

    func repository() async -> LedgerRepository? {
        await services()?.repository
    }

    private func openLedger() async -> LedgerOpenResult {
        let store = JSONFileLedgerStore(url: ledgerURL)
        var warning: String?
        var failure: String?
        var retryable = false
        var opened: LedgerRepository?

        do {
            opened = try await LedgerRepository.open(store: store)
        } catch LedgerStoreError.corrupt(let backupPath) {
            // 壊れたファイルは退避済み。もう一度開けば空の台帳で始まる（人が書いたものは退避先に残っている）。
            AppLog.ledger.error("台帳が壊れていたため退避: \(backupPath, privacy: .public)")
            warning = "台帳ファイルを読めなかったため、別名で退避して空の台帳で始めました（\(backupPath)）。"
            do {
                opened = try await LedgerRepository.open(store: store)
            } catch {
                failure = error.localizedDescription
                retryable = true
            }
        } catch let error as LedgerStoreError {
            // 新しい版のファイルなど。待っても変わらない。
            failure = error.localizedDescription
        } catch {
            failure = error.localizedDescription
            retryable = true
        }

        guard let repository = opened else {
            let message = failure ?? "台帳を開けませんでした。"
            AppLog.ledger.error("台帳を開けない: \(message, privacy: .public)")
            return LedgerOpenResult(services: nil, warning: warning, error: message, retryable: retryable)
        }

        let services = LedgerServices(
            repository: repository,
            registrar: ChainRegistrar(repository: repository, search: places, hours: places),
            refresher: HoursRefresher(repository: repository, hours: places),
            // 端末のタイムゾーンは起動中に変わりうる（旅行）。値の固定を避けて、読むたびに今の設定を見る（D14）。
            entryHandler: StationEntryHandler(repository: repository, poster: poster, timeZone: { TimeZone.autoupdatingCurrent })
        )
        return LedgerOpenResult(services: services, warning: warning, error: nil)
    }

    // MARK: 駅入域

    /// 入域の経路。台帳が開けなければログだけ残して戻る（落とさない）。
    /// バックグラウンド起動中に判定と通知の投稿が終わる前に一時停止されないよう、時間を借りる。
    func handleTrigger(_ event: TriggerEvent) async {
        // 時間の借り入れは台帳を開くのを待つ前から始める。バックグラウンド起動直後は台帳の読み込みも
        // この猶予の中で走るので、開く前に一時停止されないようにする。
        await withBackgroundTime("station-entry") { () async -> Void in
            guard let services = await self.services() else {
                AppLog.location.error("入域を処理できない（台帳が開けない）: \(event.stationID.uuidString, privacy: .public)")
                return
            }
            do {
                // 結果（通知した／抑制した）は台帳の履歴に書かれる。ここでは使わない。
                _ = try await services.entryHandler.handle(event)
            } catch {
                AppLog.notify.error("入域の処理に失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: 通知のボタン

    func perform(_ action: NotificationAction) async {
        if case .open = action { return }
        guard let repository = await self.repository() else {
            AppLog.ledger.error("通知の操作を処理できない（台帳が開けない）")
            return
        }
        do {
            switch action {
            case .complete(let taskIDs):
                try await completeFromNotification(taskIDs, in: repository)
            case .ignoreToday(let taskIDs):
                // D2: 今日だけ止める。端末のタイムゾーンの翌日 0 時に未完了へ戻る。
                try await repository.ignore(taskIDs: taskIDs, untilTomorrow: true, now: Date(), timeZone: TimeZone.autoupdatingCurrent)
            case .open:
                break
            }
        } catch {
            AppLog.ledger.error("通知の操作を台帳に書けなかった: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 「完了」ボタンの扱いはここ 1 か所。
    /// D3 / 計画書 §4 未決「通知から『完了』を押したとき、同じ店の他の品目はどう扱うか」の既定:
    /// 通知に載っていたタスクを全部完了にする（ボタンは「どれか」を聞けない）。
    /// 1 品目ずつ・店ごと一括などに変えるときは、この関数だけを書き換える。台帳画面の「戻す」で取り消せる。
    private func completeFromNotification(_ listedTaskIDs: [UUID], in repository: LedgerRepository) async throws {
        try await repository.complete(taskIDs: listedTaskIDs, at: Date())
    }

    // MARK: 監視の計画

    /// 台帳の変化を購読して、監視計画を作り直し続ける。UI が無くても動く。
    private func startPlanning() {
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let opened = await self.openResult()
                if let repository = opened.services?.repository {
                    let stream = await repository.updates()
                    for await ledger in stream {
                        self.replan(ledger: ledger)
                    }
                    return
                }
                // 台帳を開けない間は、領域監視は前回のまま（iOS が覚えている）。一時的な失敗なら開き直す。
                guard opened.retryable else { return }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        state.withValue { $0.planningTask = task }
    }

    /// `ledger` を渡すとそれを最新として覚える。渡さなければ覚えている最新の台帳で作り直す。
    /// 計画が前回と同じなら何もしない（`force` のときだけ登録し直す）。
    /// 計算から反映までをロックの中で行うのは、別スレッドからの呼び出しが前後して古い計画で上書きするのを防ぐため
    /// （`trigger.apply` はメインのキューへ積むだけで、ここでは待たない）。
    private func replan(ledger newLedger: Ledger? = nil, force: Bool = false) {
        let change = state.withValue { (s: inout State) -> PlanChange? in
            if let newLedger { s.latestLedger = newLedger }
            guard let ledger = s.latestLedger else { return nil }
            let plan = MonitoringPlanner.plan(ledger: ledger, now: Date(), deviceLocation: trigger.currentCoordinate)
            let changed = s.appliedPlan != plan
            guard changed || force else { return nil }
            s.appliedPlan = plan
            trigger.apply(plan)
            return changed ? PlanChange(observer: s.observer) : nil
        }
        change?.observer?(.planChanged)
    }

    /// いま反映している計画（まだ作っていなければ停止）。
    var currentPlan: MonitoringPlan {
        state.withValue { $0.appliedPlan ?? .stopped }
    }

    /// 画面側の購読口（1 つだけ。AppModel が設定する）。呼ばれるスレッドは不定。
    func setObserver(_ observer: (@Sendable (EnvironmentEvent) -> Void)?) {
        state.withValue { $0.observer = observer }
    }

    private func notify(_ event: EnvironmentEvent) {
        let observer = state.withValue { $0.observer }
        observer?(event)
    }

    // MARK: 権限の状態

    var locationAuthorization: LocationAuthorization { trigger.authorization }

    func notificationStatus() async -> UNAuthorizationStatus {
        await poster.authorizationStatus()
    }

    // MARK: 営業時間の週 1 更新

    var lastHoursRefresh: Date? { AppEnvironment.storedLastHoursRefresh() }

    /// インスタンスを作らずに読める（AppModel の初期値用。`shared` に触れずに済ませる）。
    static func storedLastHoursRefresh() -> Date? {
        UserDefaults.standard.object(forKey: lastHoursRefreshKey) as? Date
    }

    func recordHoursRefresh(_ date: Date) {
        UserDefaults.standard.set(date, forKey: AppEnvironment.lastHoursRefreshKey)
    }

    /// 更新が要る支店があるか（通信しない）。キー未設定なら false（取りに行けない）。
    func isHoursRefreshDue() async -> Bool {
        guard placesConfigured, let services = await self.services() else { return false }
        return await services.refresher.isDue()
    }

    /// 週 1 更新（§4）。BGTask とフォアグラウンドの取りこぼし回収の両方が使う。
    /// 成功（または何もすることが無い）なら true。失敗した支店があるときと、時間切れで止められたときは false。
    func refreshHoursIfDue() async -> Bool {
        guard let report = await refreshHoursIfDueReport() else { return !Task.isCancelled }
        return report.failed.isEmpty && !Task.isCancelled
    }

    /// 実行したときだけレポートを返す。nil = キー未設定・台帳なし・更新不要・他で実行中。
    func refreshHoursIfDueReport() async -> RefreshReport? {
        guard placesConfigured, let services = await self.services() else { return nil }
        // BGTask とフォアグラウンドが同時に走っても、Places を二重に叩かない。
        let acquired = state.withValue { s -> Bool in
            if s.refreshingHours { return false }
            s.refreshingHours = true
            return true
        }
        guard acquired else { return nil }
        defer { state.withValue { $0.refreshingHours = false } }

        guard await services.refresher.isDue() else { return nil }
        let report = await services.refresher.refreshStale()
        if report.refreshed > 0 {
            recordHoursRefresh(Date())
        }
        AppLog.refresh.info("営業時間の更新: 更新 \(report.refreshed) 件、失敗 \(report.failed.count) 件、対象外 \(report.skipped) 件")
        return report
    }
}
