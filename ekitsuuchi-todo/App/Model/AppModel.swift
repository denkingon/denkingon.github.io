import EkiCore
import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: - 画面とやりとりする値

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

enum AddTaskFeedback: Equatable {
    case added
    /// 同じ店・品目が未完了で既にある（D5）。追加していない。
    case duplicate
    /// 追加できなかった理由（画面にそのまま出せる日本語）。
    case invalid(String)
}

/// JSON 取込の結果。ファイル全体が読めなかったときは `errorMessage` だけが入る。
struct ImportFeedback: Equatable {
    var added = 0
    var duplicates = 0
    /// 取り込めなかった行（形式の不備）。
    var rejected = 0
    /// 取り込めなかった行の理由（最初の数件。「3 件目: …」の形）。
    var rejectedReasons: [String] = []
    /// ファイル全体が受け付けられなかった理由。
    var errorMessage: String?

    var isFailure: Bool { errorMessage != nil }

    /// 1 行の結果。
    var summaryLine: String {
        if let errorMessage { return "取り込めませんでした: \(errorMessage)" }
        var text = "取り込み: 追加 \(added) 件、重複 \(duplicates) 件"
        if rejected > 0 { text += "、取り込めない行 \(rejected) 件" }
        return text
    }
}

/// `updateSettings` の変換を Sendable な仕事に載せるための箱。
/// 変換は呼び出し側が書いた「Settings を書き換えるだけ」の純粋な関数で、台帳の actor の中で 1 回だけ実行される。
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

// MARK: - AppModel

/// 画面のための台帳の写しと、画面からの操作口。
///
/// 台帳の読み書きは `LedgerRepository` が唯一の入口で、ここは「最新の写しを持つ」「操作を Task で流す」「失敗を alert にする」だけ。
/// 駅入域の判定・通知ボタン・監視計画は `AppEnvironment` が持つ（画面が無くても動かすため）。ここには置かない。
@MainActor
@Observable
final class AppModel {
    // MARK: 状態

    /// 最新の台帳（起動直後は空。`isReady` が true になったら中身が入っている）。
    private(set) var ledger = Ledger()
    /// 台帳を開く試みが終わった（開けた／開けなかった）。開けなかったときは `ledgerError` がある。
    private(set) var isReady = false
    var alert: AppAlert?
    private(set) var locationAuthorization: LocationAuthorization = .notDetermined
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// 最後に営業時間を取り直した時刻。
    private(set) var lastHoursRefresh: Date? = AppEnvironment.storedLastHoursRefresh()
    /// 登録・更新・取込の最中は文言が入る（画面の細いバナー用）。
    private(set) var busyMessage: String?
    /// 直近の登録・更新・取込の結果 1 行。
    private(set) var lastReport: String?
    /// いま監視している駅（`監視中 N / 20` の N）。
    private(set) var monitoringPlan: MonitoringPlan = .stopped
    /// 壊れた台帳ファイルを退避して空で始めた、という知らせ（常設の表示用）。
    private(set) var ledgerWarning: String?
    /// 台帳を開けなかった理由。これが入っているとき、変更操作は何も保存されない。
    private(set) var ledgerError: String?

    /// Places のキーが入っているか。値は見せない。ビルド時に決まるので変わらない。
    var placesConfigured: Bool { !AppSecrets.placesAPIKey.isEmpty }

    /// 台帳 画面の「店」欄の候補: 登録済みのチェーン、続けてタスクで使われている店（`ChainName.key` で重複を除く）。
    var knownStoreNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in ledger.registeredChains + ledger.tasks.map(\.store) {
            let key = ChainName.key(name)
            if !key.isEmpty, seen.insert(key).inserted {
                names.append(name)
            }
        }
        return names
    }

    // MARK: 内部

    private var env: AppEnvironment { AppEnvironment.shared }

    private struct BusyEntry {
        let id: UUID
        let message: String
    }

    @ObservationIgnored private var busyEntries: [BusyEntry] = []
    @ObservationIgnored private var reportedLedgerOpen = false
    @ObservationIgnored private var lastCatchUp: Date?

    /// 同じ名前でこの距離（m）以内の駅は同じ駅とみなして二重登録しない（二重の領域は二重の通知になる）。
    private static let duplicateStationMeters: Double = 300
    /// 取込のレポートに載せる「取り込めない行の理由」の最大件数。
    private static let maxRejectedReasons = 5
    /// 営業時間の取りこぼし回収を試みる最短の間隔。失敗が続いても、前面に戻るたびに通信しない。
    private static let catchUpInterval: TimeInterval = 60 * 60

    /// AppEnvironment には触らない（App 構造体の初期化が AppDelegate より先に走っても、起動の順序を崩さないため）。
    init() {}

    // MARK: ライフサイクル

    /// 画面が出たとき 1 回呼ぶ（`.task`）。台帳の更新を受け取り続けるので、画面が消える（キャンセル）まで戻らない。
    func start() async {
        let env = self.env
        env.launch() // 通常は AppDelegate が済ませている。冪等。
        observeEnvironment()
        monitoringPlan = env.currentPlan
        await refreshPermissionStates()

        let opened = await env.openResult()
        reportLedgerOpen(opened)
        guard let services = opened.services else {
            isReady = true
            return
        }

        let stream = await services.repository.updates()
        Task { await self.catchUpRefresh() }
        for await snapshot in stream {
            ledger = snapshot
            isReady = true
        }
    }

    /// 前面に戻ったとき。設定アプリで変えた許可状態の読み直しと、営業時間の取りこぼし回収。
    func didBecomeActive() async {
        await refreshPermissionStates()
        await catchUpRefresh()
    }

    private func observeEnvironment() {
        env.setObserver { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
    }

    /// 合図の中身は読み直す（合図が前後して届いても、最新の値に揃う）。
    private func handle(_ event: EnvironmentEvent) {
        switch event {
        case .authorizationChanged:
            locationAuthorization = env.locationAuthorization
            Task { await self.refreshNotificationStatus() }
        case .planChanged:
            monitoringPlan = env.currentPlan
        }
    }

    private func reportLedgerOpen(_ result: LedgerOpenResult) {
        ledgerWarning = result.warning
        ledgerError = result.error
        guard !reportedLedgerOpen else { return }
        reportedLedgerOpen = true
        if let error = result.error {
            alert = AppAlert(title: "台帳を開けません", message: error)
        } else if let warning = result.warning {
            alert = AppAlert(title: "台帳を読めませんでした", message: warning)
        }
    }

    /// 起動中に営業時間の更新が要るなら取り直す（BGTask は実行時刻を iOS が決めるので、前面でも拾う）。
    private func catchUpRefresh() async {
        let now = Date()
        if let last = lastCatchUp, now.timeIntervalSince(last) < Self.catchUpInterval { return }
        lastCatchUp = now
        guard await env.isHoursRefreshDue() else { return }
        let report = await withBusy("営業時間を更新しています…") {
            await self.env.refreshHoursIfDueReport()
        }
        lastHoursRefresh = env.lastHoursRefresh
        if let report {
            lastReport = Self.describe(report)
        }
    }

    // MARK: タスク

    /// 店と品目を台帳に足す。未登録のチェーンなら裏で店登録を始める（D11: 人が触るのはこの 1 画面だけ）。
    func addTask(store: String, item: String) async -> AddTaskFeedback {
        guard let repository = await repositoryOrAlert() else {
            return .invalid("台帳を開けないため追加できません")
        }
        do {
            switch try await repository.addTask(store: store, item: item) {
            case .added(let task):
                registerInBackground(chains: [task.store])
                return .added
            case .duplicate:
                return .duplicate
            }
        } catch let error as LedgerError {
            return .invalid(error.localizedDescription)
        } catch {
            return .invalid("保存できませんでした: \(error.localizedDescription)")
        }
    }

    func complete(_ ids: [UUID]) {
        mutateLedger("完了にできませんでした") { repository in
            try await repository.complete(taskIDs: ids, at: Date())
        }
    }

    /// `untilTomorrow == false` が台帳画面の「無視」（戻すまで無期限）、true が「今日だけ」（明日 0 時に未完了へ戻る。D2）。
    func ignore(_ ids: [UUID], untilTomorrow: Bool) {
        mutateLedger("無視にできませんでした") { repository in
            try await repository.ignore(taskIDs: ids, untilTomorrow: untilTomorrow, now: Date(), timeZone: TimeZone.current)
        }
    }

    func reopen(_ ids: [UUID]) {
        mutateLedger("戻せませんでした") { repository in
            try await repository.reopen(taskIDs: ids)
        }
    }

    func delete(_ ids: [UUID]) {
        mutateLedger("削除できませんでした") { repository in
            try await repository.delete(taskIDs: ids)
        }
    }

    // MARK: 駅

    func searchStations(_ text: String) async throws -> [StationCandidate] {
        try await env.stationSearch.search(text)
    }

    /// 駅を足す（半径は `Tuning` の既定）。登録済みの全チェーンについて、その駅ぶんだけ店登録をやり直す（§4 週1更新-3）。
    /// 監視計画の作り直しは、台帳の更新を購読している `AppEnvironment` が自動で行う。
    func addStation(_ candidate: StationCandidate) async {
        guard let services = await repositoryServicesOrAlert() else { return }
        let repository = services.repository

        let existing = await repository.snapshot().stations
        let candidateKey = ChainName.key(candidate.name)
        let alreadyThere = existing.contains { station in
            ChainName.key(station.name) == candidateKey
                && station.coordinate.distance(to: candidate.coordinate) < Self.duplicateStationMeters
        }
        if alreadyThere {
            alert = AppAlert(title: "登録済みの駅です", message: "\(candidate.name) はすでに登録されています。")
            return
        }

        let station = Station(name: candidate.name, coordinate: candidate.coordinate)
        do {
            try await repository.upsertStation(station)
        } catch {
            alert = AppAlert(title: "駅を追加できませんでした", message: error.localizedDescription)
            return
        }

        // 初めての駅で、まだ位置情報の許可を聞いていなければここで聞く（使用中 → 常に の順に iOS が案内する）。
        if env.locationAuthorization == .notDetermined {
            requestLocationAuthorization()
        }

        guard !(await repository.snapshot().registeredChains.isEmpty) else {
            lastReport = "\(station.name) を追加しました。店を登録すると、この駅の近くの支店を探します。"
            return
        }
        await searchBranches(forNewStation: station, services: services)
    }

    func setStationRadius(_ id: UUID, meters: Double) {
        guard meters.isFinite else { return }
        // 画面は 100…1000 m。ここは壊れた値だけを弾く広めの範囲（端末の上限は GeofenceTrigger が丸める）。
        let clamped = min(max(meters, 50), 2000)
        mutateLedger("半径を変えられませんでした") { repository in
            try await repository.mutate { (ledger: inout Ledger) -> Void in
                guard let i = ledger.stations.firstIndex(where: { $0.id == id }) else { return }
                ledger.stations[i].radiusMeters = clamped
            }
        }
    }

    func setStationEnabled(_ id: UUID, _ enabled: Bool) {
        Task {
            guard let services = await self.repositoryServicesOrAlert() else { return }
            let repository = services.repository
            do {
                try await repository.mutate { (ledger: inout Ledger) -> Void in
                    guard let i = ledger.stations.firstIndex(where: { $0.id == id }) else { return }
                    ledger.stations[i].isEnabled = enabled
                }
            } catch {
                self.alert = AppAlert(title: "有効・無効を変えられませんでした", message: error.localizedDescription)
                return
            }
            // 無効の間に足した駅は支店を探していない。有効にしたとき、支店がまだ 1 つも無ければ探す。
            guard enabled else { return }
            let snapshot = await repository.snapshot()
            guard let station = snapshot.station(id: id),
                  !snapshot.registeredChains.isEmpty,
                  !snapshot.branches.contains(where: { $0.distance(to: id) != nil }) else { return }
            await self.searchBranches(forNewStation: station, services: services)
        }
    }

    func removeStation(_ id: UUID) {
        mutateLedger("駅を削除できませんでした") { repository in
            try await repository.removeStation(id: id)
        }
    }

    private func searchBranches(forNewStation station: Station, services: LedgerServices) async {
        let registrar = services.registrar
        let reports = await withBusy("\(station.name) の支店を探しています…") {
            await registrar.registerStation(id: station.id)
        }
        let snapshot = await services.repository.snapshot()
        let nearCount = snapshot.branches.filter { $0.distance(to: station.id) != nil }.count
        var text = "\(station.name) の近くの支店: \(nearCount) 件"
        let failures = reports.filter { !$0.stationFailures.isEmpty }
        if !failures.isEmpty {
            let names = failures.map(\.chainName).joined(separator: "、")
            text += "（検索に失敗した店: \(names)）"
        }
        let hoursFailures = reports.reduce(0) { $0 + $1.hoursFailures.count }
        if hoursFailures > 0 {
            text += "（営業時間を取得できなかった支店 \(hoursFailures) 件）"
        }
        lastReport = text
    }

    // MARK: 店

    /// チェーン名で店を足す（店画面）。駅ごとに近隣の支店と営業時間を取る。
    func addChain(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ChainName.key(trimmed).isEmpty else {
            alert = AppAlert(title: "店を追加できません", message: "チェーン名が空です。")
            return
        }
        await registerChain(trimmed)
    }

    /// 店画面の「再取得」。
    func reregisterChain(_ name: String) async {
        await registerChain(name)
    }

    private func registerChain(_ name: String) async {
        guard let services = await repositoryServicesOrAlert() else { return }
        let registrar = services.registrar
        let report = await withBusy("\(name) の支店を探しています…") {
            await registrar.register(chainName: name)
        }
        lastReport = Self.describe(report)
    }

    /// 登録を外し、そのチェーンの支店も消す。タスクは残る（また店を足せば使える）。
    func removeChain(_ name: String) {
        mutateLedger("店を削除できませんでした") { repository in
            try await repository.unregisterChain(name)
        }
    }

    func setBranchAttribute(branchID: String, key: String, value: String?) {
        mutateLedger("属性を保存できませんでした") { repository in
            try await repository.setBranchAttribute(branchID: branchID, key: key, value: value)
        }
    }

    /// 設定画面の「今すぐ更新」。
    /// 全チェーンの店登録をやり直し（支店の増減・名前の更新）、続けて営業時間を取り直す。
    /// Core の店登録は既存の支店の営業時間に触らないので、先に「最終取得」を消して、7 日以内のものも更新対象にする。
    /// 取得に失敗した支店は古い営業時間のまま残り、次の機会に再試行される（最終取得が空のまま）。
    func refreshAllHours() async {
        guard placesConfigured else {
            lastReport = PermissionCopy.placesKeyMissing
            return
        }
        guard let services = await repositoryServicesOrAlert() else { return }
        let chains = await services.repository.snapshot().registeredChains
        guard !chains.isEmpty else {
            lastReport = "登録済みの店がありません"
            return
        }
        let summary = await withBusy("営業時間を更新しています…") {
            await self.performFullRefresh(chains: chains, services: services)
        }
        lastHoursRefresh = env.lastHoursRefresh
        lastReport = summary
    }

    private func performFullRefresh(chains: [String], services: LedgerServices) async -> String {
        do {
            try await services.repository.mutate { (ledger: inout Ledger) -> Void in
                for i in ledger.branches.indices {
                    ledger.branches[i].hoursFetchedAt = nil
                }
            }
        } catch {
            alert = AppAlert(title: "更新を始められませんでした", message: error.localizedDescription)
            return "営業時間の更新を始められませんでした"
        }

        var stationFailures = 0
        var hoursFailures = 0
        for chain in chains {
            if Task.isCancelled { break }
            let report = await services.registrar.register(chainName: chain)
            stationFailures += report.stationFailures.count
            hoursFailures += report.hoursFailures.count
        }
        let refresh = await services.refresher.refreshStale()
        let branchCount = await services.repository.snapshot().branches.count

        let failureCount = stationFailures + hoursFailures + refresh.failed.count
        if failureCount == 0 && !Task.isCancelled {
            env.recordHoursRefresh(Date())
        }
        var text = "営業時間を更新: 店 \(chains.count) 件、支店 \(branchCount) 件、取り直し \(refresh.refreshed) 件"
        if failureCount > 0 {
            text += "、失敗 \(failureCount) 件（古い営業時間のまま。あとで再試行します）"
        }
        return text
    }

    // MARK: 取込

    /// 入力 JSON v1 を取り込む（M4）。`.fileImporter` が返した URL（セキュリティスコープ付き）をそのまま渡せる。
    /// 未登録のチェーンが出てきたら、結果を返したあと裏で店登録を始める（D11）。
    func importJSON(from url: URL) async -> ImportFeedback {
        guard let repository = await repositoryOrAlert() else {
            return ImportFeedback(errorMessage: "台帳を開けないため取り込めません")
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let data: Data
        do {
            data = try await Task.detached { try FileReader.read(url) }.value
        } catch {
            return finish(ImportFeedback(errorMessage: "ファイルを読めませんでした（\(error.localizedDescription)）"))
        }

        let parsed: ImportParseResult
        do {
            parsed = try TaskImporter.parse(data)
        } catch {
            return finish(ImportFeedback(errorMessage: error.localizedDescription))
        }

        let summary: ImportSummary
        do {
            summary = try await repository.importItems(parsed.items, now: Date())
        } catch {
            return finish(ImportFeedback(errorMessage: "保存できませんでした: \(error.localizedDescription)"))
        }

        let reasons = parsed.rejected.prefix(Self.maxRejectedReasons).map { "\($0.index + 1) 件目: \($0.reason)" }
        registerInBackground(chains: summary.chainsNeedingRegistration)
        return finish(ImportFeedback(
            added: summary.added.count,
            duplicates: summary.duplicates,
            rejected: parsed.rejected.count + summary.invalid,
            rejectedReasons: reasons,
            errorMessage: nil
        ))
    }

    private func finish(_ feedback: ImportFeedback) -> ImportFeedback {
        lastReport = feedback.summaryLine
        return feedback
    }

    // MARK: 設定と権限

    /// 設定を書き換える。`change` は台帳の actor の中で、その時点の設定に対して 1 回だけ実行される。
    func updateSettings(_ change: @escaping (inout Settings) -> Void) {
        let box = UncheckedSendable(value: change)
        mutateLedger("設定を保存できませんでした") { repository in
            try await repository.updateSettings(box.value)
        }
    }

    func requestLocationAuthorization() {
        env.trigger.requestAuthorization()
    }

    /// 通知の許可ダイアログを出す（初回のみ表示される。拒否済みなら設定アプリへ案内する）。
    func requestNotificationAuthorization() async {
        _ = await env.poster.requestAuthorization()
        await refreshPermissionStates()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func refreshPermissionStates() async {
        locationAuthorization = env.locationAuthorization
        await refreshNotificationStatus()
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await env.notificationStatus()
    }

    // MARK: 内部の道具

    /// 台帳を書き換える操作を Task で流す。失敗は alert に出す。
    private func mutateLedger(
        _ failureTitle: String,
        _ work: @escaping @Sendable (LedgerRepository) async throws -> Void
    ) {
        Task {
            guard let repository = await self.repositoryOrAlert() else { return }
            do {
                try await work(repository)
            } catch {
                self.alert = AppAlert(title: failureTitle, message: error.localizedDescription)
            }
        }
    }

    private func repositoryServicesOrAlert() async -> LedgerServices? {
        let opened = await env.openResult()
        if opened.services == nil {
            alert = AppAlert(title: "台帳を開けません", message: opened.error ?? "台帳を開けませんでした。")
        }
        return opened.services
    }

    private func repositoryOrAlert() async -> LedgerRepository? {
        await repositoryServicesOrAlert()?.repository
    }

    /// 未登録のチェーンだけ店登録を始める（登録済みは `ensureRegistered` が飛ばす）。結果は待たない。
    private func registerInBackground(chains: [String]) {
        guard !chains.isEmpty else { return }
        Task {
            guard let services = await self.env.services() else { return }
            let registrar = services.registrar
            let reports = await self.withBusy("店を登録しています…") {
                await registrar.ensureRegistered(chains: chains)
            }
            guard !reports.isEmpty else { return }
            self.lastReport = reports.map { Self.describe($0) }.joined(separator: " ／ ")
        }
    }

    /// 同時に複数の処理が走っても、バナーは最後に始まった処理の文言を出し、全部終わったら消える。
    private func withBusy<T>(_ message: String, _ body: () async -> T) async -> T {
        let entry = BusyEntry(id: UUID(), message: message)
        busyEntries.append(entry)
        busyMessage = message
        let result = await body()
        busyEntries.removeAll { $0.id == entry.id }
        busyMessage = busyEntries.last?.message
        return result
    }

    private static func describe(_ report: RegistrationReport) -> String {
        var text = "\(report.chainName): 支店 \(report.branchesKept) 件"
        if report.stationsSearched == 0 {
            text += "（有効な駅がないため検索していません）"
        } else {
            text += "（駅 \(report.stationsSearched) 件を検索）"
        }
        if !report.stationFailures.isEmpty {
            let names = report.stationFailures.keys.sorted()
            let reason = names.first.flatMap { report.stationFailures[$0] } ?? ""
            text += "／検索に失敗: \(names.joined(separator: "、"))（\(reason)）"
        }
        if !report.hoursFailures.isEmpty {
            text += "／営業時間を取得できなかった支店 \(report.hoursFailures.count) 件"
        }
        return text
    }

    private static func describe(_ report: RefreshReport) -> String {
        var text = "営業時間を更新しました（\(report.refreshed) 件）"
        if !report.failed.isEmpty {
            text += "／失敗 \(report.failed.count) 件（古いまま。あとで再試行します）"
        }
        return text
    }
}

// MARK: - ファイル読み取り

/// 取込ファイルの読み取り（メインを塞がない）。iCloud Drive 上の未ダウンロードのファイルも、
/// NSFileCoordinator 経由なら読む前にダウンロードされる。
private enum FileReader {
    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var outcome: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            outcome = Result { try Data(contentsOf: readableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileReadUnknown) }
        return try outcome.get()
    }
}
