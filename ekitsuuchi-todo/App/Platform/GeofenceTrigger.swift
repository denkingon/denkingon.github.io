import CoreLocation
import EkiCore
import Foundation
import os

/// 引き金の v0 実装: 駅のジオフェンス入域（CLLocationManager の領域監視、§5 引き金）。
///
/// 重要: このオブジェクトは `application(_:didFinishLaunchingWithOptions:)` の中で作り、
/// そこで `onTrigger` まで設定すること。領域イベントでアプリがバックグラウンド起動されたとき、
/// delegate を持つ CLLocationManager が起動中に存在していれば、保留されていた `didEnterRegion` がそこへ届く。
/// 遅れて作ると、そのイベントは取りこぼす。
///
/// スレッド: CLLocationManager はメインスレッドで作り、メインから操作する（delegate もメインの run loop に届く）。
/// どのスレッドから `apply` / `requestAuthorization` を呼んでも、中でメインへ寄せる。
/// 入域の保留リスト（`pending`）と 6 秒のタイマーもメインだけで触る（ロック不要）。
///
/// 寿命: `CLLocationManager.delegate` は weak。このオブジェクト（= delegate）をアプリ側が強参照で持ち続けること
/// （AppDelegate / アプリ全体のモデルのプロパティなど）。手放すと領域イベントが二度と届かない。
final class GeofenceTrigger: NSObject, TriggerSource, CLLocationManagerDelegate, @unchecked Sendable {
    // 可変状態はまとめて Locked に入れる（設定はどのスレッドからでも、読むのは主に delegate = メイン）。
    private struct State {
        var onTrigger: (@Sendable (TriggerEvent) -> Void)?
        var onSignificantMove: (@Sendable (Coordinate) -> Void)?
        var onAuthorizationChange: (@Sendable (LocationAuthorization) -> Void)?
        var onStatusChange: (@Sendable () -> Void)?
        var authorization: LocationAuthorization
        /// 「正確な位置情報」がオフ（iOS 14+ の accuracyAuthorization）。領域の入域判定が粗くなる。
        var reducedAccuracy: Bool
        /// 登録に失敗した領域の ID。登録に成功する（didStartMonitoringFor）か、計画から外れると消える。
        var failedRegionIDs = Set<String>()
        /// 初回に「使用中のみ」を通った直後、続けて「常に」を求めるための印。
        var wantsAlways = false

        /// 駅画面に出す一言。許可が無い問題は別の導線（権限の表示）があるので、ここでは扱わない。
        var problem: String? {
            if !failedRegionIDs.isEmpty {
                return "駅の監視を登録できません（件数の上限か位置情報の許可）"
            }
            if reducedAccuracy, authorization == .whenInUse || authorization == .always {
                return "「正確な位置情報」がオフです。駅に入ったことの検知が遅れたり外れたりします（設定 > 位置情報）"
            }
            return nil
        }
    }

    /// 入域を受けてから、新しい位置が届く（またはあきらめる）まで保留している 1 件。
    private struct PendingEntry {
        let token: UUID
        let stationID: UUID
        /// 判定器に渡す時刻は入域を受け取った時刻のまま。位置待ちの間に進めない。
        let firedAt: Date
        /// 入域を受けた時点で manager が持っていた位置（nil や数分前のことがある）。新しい位置が間に合わなかったときの代用。
        let cachedFix: LocationFix?
    }

    /// 新しい位置を待つ上限。入域を受けた瞬間から `BackgroundHold` でバックグラウンド時間を借りるので、
    /// この待ちが起動直後の約 10 秒を食い潰すことはない（借りた時間は配達の少しあとまで持つ）。
    /// 切れたら古い位置（無ければ nil）で必ず配達する。入域を落とすのが最悪の失敗。
    private static let freshFixTimeout: TimeInterval = 6

    /// 配達してから借り時間を返すまでの間。直後に AppEnvironment.handleTrigger が自分の分を借りるまでの隙間を作らない。
    private static let holdReleaseDelay: TimeInterval = 4

    // @unchecked Sendable の根拠: manager はメインでのみ操作する。他スレッドからは `location` の読み取りだけ。
    private let manager: CLLocationManager
    private let state: Locked<State>
    // メインだけで触る（delegate・タイマー・apply はすべてメイン）。ロックに入れないのはそのため。
    private var pending: [PendingEntry] = []
    private var tracksSignificantChanges = false

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.state = Locked(State(
            authorization: LocationAuthorization(manager.authorizationStatus),
            reducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy
        ))
        super.init()
        // 領域監視には要らないが、入域直後の位置（requestLocation）は粗い位置だと M1 の実測にならない。
        // 大きな位置変化の購読（significant-change）はこの設定に影響されないので電池への影響は小さい。
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // 起動直後に delegate を付ける（上のクラスコメント参照）。
        manager.delegate = self
    }

    // MARK: TriggerSource / 公開口

    var onTrigger: (@Sendable (TriggerEvent) -> Void)? {
        get { state.withValue { $0.onTrigger } }
        set { state.withValue { $0.onTrigger = newValue } }
    }

    /// 大きな位置変化（有効な駅が上限を超えるときの入れ替え用）。
    var onSignificantMove: (@Sendable (Coordinate) -> Void)? {
        get { state.withValue { $0.onSignificantMove } }
        set { state.withValue { $0.onSignificantMove = newValue } }
    }

    var onAuthorizationChange: (@Sendable (LocationAuthorization) -> Void)? {
        get { state.withValue { $0.onAuthorizationChange } }
        set { state.withValue { $0.onAuthorizationChange = newValue } }
    }

    /// 位置情報の購読の状態が変わったとき（`monitoringProblem` か許可）。呼ばれるスレッドは不定。
    var onStatusChange: (@Sendable () -> Void)? {
        get { state.withValue { $0.onStatusChange } }
        set { state.withValue { $0.onStatusChange = newValue } }
    }

    var authorization: LocationAuthorization {
        state.withValue { $0.authorization }
    }

    /// 駅画面に出す「監視がうまくいっていない理由」。問題が無ければ nil。
    /// 「正確な位置情報」オフ、または領域の登録失敗。後者は次に登録が成功するか計画から外れると消える。
    var monitoringProblem: String? {
        state.withValue { $0.problem }
    }

    var currentCoordinate: Coordinate? {
        manager.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    /// 計画どおりに領域を登録し直す。何度呼んでも安全（差分だけ反映）。空の計画は全部止める。
    func apply(_ plan: MonitoringPlan) {
        onMain { [self] in
            applyOnMain(plan)
        }
    }

    /// 初回: 「使用中のみ」→ 続けて「常に」。「使用中のみ」の人には「常に」だけ。それ以外は設定アプリへ（画面側の導線）。
    func requestAuthorization() {
        onMain { [self] in
            switch LocationAuthorization(manager.authorizationStatus) {
            case .notDetermined:
                // iOS は「常に」をいきなり求められない。先に使用中を求め、結果が来たら続けて求める。
                state.withValue { $0.wantsAlways = true }
                manager.requestWhenInUseAuthorization()
            case .whenInUse:
                manager.requestAlwaysAuthorization()
            case .always, .denied, .restricted:
                break
            }
        }
    }

    // MARK: 領域の登録

    private func applyOnMain(_ plan: MonitoringPlan) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            AppLog.location.error("領域監視が使えない端末")
            return
        }

        // 許可が出る前（未設定・拒否・制限）は領域を登録しない。許可前に登録した領域が有効になる保証が無いので、
        // 許可が変わったときの再反映（AppEnvironment の onAuthorizationChange → replan）で登録する。
        // 外す側（下の stopMonitoring）は許可に関係なく進める。
        let status = LocationAuthorization(manager.authorizationStatus)
        let canStart = (status == .whenInUse || status == .always)

        // 同じ ID が二重に入っていても最後のものを採る（Dictionary(uniqueKeysWithValues:) は重複で落ちる）。
        var wanted: [String: Station] = [:]
        for station in plan.stations {
            wanted[station.id.uuidString] = station
        }

        // 計画から外れた駅の失敗は忘れる（残る駅は登録し直した結果で、成功すれば didStartMonitoringFor、失敗すればまた記録される）。
        mutateStatus { $0.failedRegionIDs.formIntersection(wanted.keys) }

        // iOS が覚えている領域（前回起動分を含む）と突き合わせる。
        var alreadyCorrect = Set<String>()
        for region in manager.monitoredRegions {
            guard let circular = region as? CLCircularRegion,
                  let station = wanted[circular.identifier],
                  matches(circular, station: station) else {
                manager.stopMonitoring(for: region)
                continue
            }
            alreadyCorrect.insert(circular.identifier)
        }

        // 注意: すでに半径の中にいる状態で登録した領域は、いったん出て入り直すまで入域イベントが来ない（iOS の仕様）。
        for (identifier, station) in wanted where !alreadyCorrect.contains(identifier) {
            guard canStart else { continue }
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude),
                radius: effectiveRadius(for: station),
                identifier: identifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }

        tracksSignificantChanges = plan.tracksSignificantLocationChanges
        if plan.tracksSignificantLocationChanges {
            if canStart, CLLocationManager.significantLocationChangeMonitoringAvailable() {
                manager.startMonitoringSignificantLocationChanges()
            }
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }

        AppLog.location.info("監視計画を反映: 駅 \(wanted.count) 件、位置変化の購読 \(plan.tracksSignificantLocationChanges ? "あり" : "なし", privacy: .public)")
    }

    /// 端末の上限を超える半径は指定できない。負値（取得失敗）のときは上限を使わない。
    private func effectiveRadius(for station: Station) -> CLLocationDistance {
        let limit = manager.maximumRegionMonitoringDistance
        let radius = limit > 0 ? min(station.radiusMeters, limit) : station.radiusMeters
        return max(1, radius)
    }

    private func matches(_ region: CLCircularRegion, station: Station) -> Bool {
        abs(region.center.latitude - station.coordinate.latitude) < 1e-9
            && abs(region.center.longitude - station.coordinate.longitude) < 1e-9
            && abs(region.radius - effectiveRadius(for: station)) < 0.5
            && region.notifyOnEntry
            && !region.notifyOnExit
    }

    /// 常にメインのキューへ積む（メインから呼ばれても同期実行しない）。
    /// 同期実行を混ぜると、別スレッドから積んだ古い計画が、メインで直に反映した新しい計画を後から上書きしうる。
    /// 全部 FIFO のキューに通せば、呼んだ順に反映される。
    private func onMain(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    /// 状態を変え、`monitoringProblem` の文言が変わったときだけ `onStatusChange` を呼ぶ（コールバックはロックの外）。
    private func mutateStatus(_ change: (inout State) -> Void) {
        let (callback, changed) = state.withValue { current -> ((@Sendable () -> Void)?, Bool) in
            let before = current.problem
            change(&current)
            return (current.onStatusChange, before != current.problem)
        }
        if changed { callback?() }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion,
              let stationID = UUID(uuidString: circular.identifier) else {
            AppLog.location.debug("対象外の領域に入った: \(region.identifier, privacy: .public)")
            return
        }

        // 入域の通知は位置のキャッシュ（nil や数分前のことがある）しか持たない。M1 は「発火位置」で半径を決めるので、
        // 新しい位置を 1 回取りに行き、届いた（または 6 秒たった）ところで配達する。
        let entry = PendingEntry(
            token: UUID(),
            stationID: stationID,
            firedAt: Date(),
            cachedFix: manager.location.map(Self.fix(from:))
        )
        AppLog.location.info("入域: \(stationID.uuidString, privacy: .public)")
        // 位置を待つ間も、判定・通知の配達まで一時停止されないようにする（delegate はメインで呼ばれる）。
        MainActor.assumeIsolated { BackgroundHold.shared.begin("region-entry") }
        let isFirstPending = pending.isEmpty
        pending.append(entry)

        // 位置が来なくても、失敗しても、このタイマーが必ず 1 回だけ配達する。配達済みなら何もしない。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freshFixTimeout) { [weak self] in
            self?.deliver(token: entry.token, fresh: nil)
        }

        // 同時に何件入っても位置の要求は 1 回。届いた位置は保留中の全件が共有する。
        guard isFirstPending else { return }
        let status = LocationAuthorization(manager.authorizationStatus)
        if status == .whenInUse || status == .always {
            manager.requestLocation()
        } else {
            // 許可が無いと requestLocation は失敗する。待たずに今ある情報で配達する。
            deliverAllPending(fresh: nil)
        }
    }

    private static func fix(from location: CLLocation) -> LocationFix {
        LocationFix(
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }

    /// 保留から外してから配達する。外れていれば配達済みなので何もしない（同じ入域を二度送らない）。
    private func deliver(token: UUID, fresh: LocationFix?) {
        guard let index = pending.firstIndex(where: { $0.token == token }) else { return }
        let entry = pending.remove(at: index)
        emit(entry, fresh: fresh, reason: "タイムアウト")
        releaseBackgroundTimeSoon()
    }

    private func deliverAllPending(fresh: LocationFix?) {
        let entries = pending
        pending.removeAll()
        for entry in entries {
            emit(entry, fresh: fresh, reason: fresh == nil ? "位置を取れず" : "新しい位置")
        }
        releaseBackgroundTimeSoon()
    }

    /// 保留が空のままなら、少し待ってから借り時間を返す。その間に次の入域が来ていれば返さない（その配達がまた予約する）。
    private func releaseBackgroundTimeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdReleaseDelay) { [weak self] in
            guard let self, self.pending.isEmpty else { return }
            MainActor.assumeIsolated { BackgroundHold.shared.end() }
        }
    }

    private func emit(_ entry: PendingEntry, fresh: LocationFix?, reason: String) {
        let fix = fresh ?? entry.cachedFix
        let event = TriggerEvent(stationID: entry.stationID, firedAt: entry.firedAt, location: fix)
        let source = fresh != nil ? "新しい位置" : (entry.cachedFix != nil ? "古い位置で代用" : "位置なし")
        AppLog.location.info("入域を配達: \(entry.stationID.uuidString, privacy: .public)（\(source, privacy: .public)・\(reason, privacy: .public)）")
        let callback = state.withValue { $0.onTrigger }
        guard let callback else {
            // 受け側の設定が間に合っていない。入域は履歴にも残らないので、ログだけは確実に残す。
            AppLog.location.error("入域を受けたが onTrigger が未設定: \(entry.stationID.uuidString, privacy: .public)")
            return
        }
        callback(event)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        AppLog.location.error("領域監視の失敗 \(region?.identifier ?? "-", privacy: .public): \(error.localizedDescription, privacy: .public)")
        // region が nil のときも「失敗あり」は残したいので空の ID で覚える（次の apply で消える）。
        mutateStatus { _ = $0.failedRegionIDs.insert(region?.identifier ?? "") }
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        mutateStatus { _ = $0.failedRegionIDs.remove(region.identifier) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = LocationAuthorization(manager.authorizationStatus)
        // ロックの中ではコールバックを呼ばない。必要な情報だけ取り出して外で使う。
        let (callback, statusCallback, shouldAskAlways) = state.withValue { current -> ((@Sendable (LocationAuthorization) -> Void)?, (@Sendable () -> Void)?, Bool) in
            current.authorization = status
            // 「正確な位置情報」の切り替えでもこの delegate が呼ばれる。
            current.reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            var ask = false
            if current.wantsAlways {
                switch status {
                case .whenInUse:
                    current.wantsAlways = false
                    ask = true
                case .notDetermined:
                    break // まだ答えが出ていない（delegate 設定直後の初回呼び出しなど）
                case .always, .denied, .restricted:
                    current.wantsAlways = false
                }
            }
            return (current.onAuthorizationChange, current.onStatusChange, ask)
        }
        AppLog.location.info("位置情報の許可: \(status.label, privacy: .public)")
        if shouldAskAlways {
            manager.requestAlwaysAuthorization()
        }
        callback?(status)
        statusCallback?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        // 入域の保留があるときに届いた位置は、直前の requestLocation の結果として使う。保留が無いときは位置変化の購読。
        let hadPending = !pending.isEmpty
        if hadPending {
            // 精度が負の位置は無効（CoreLocation の約束）。使わず、キャッシュの位置に任せる。
            deliverAllPending(fresh: last.horizontalAccuracy >= 0 ? Self.fix(from: last) : nil)
        }
        // 保留中に届いた位置変化の購読を取りこぼさないよう、購読中ならこちらも通す（再計画は同じ計画なら何もしない）。
        guard !hadPending || tracksSignificantChanges else { return }
        let coordinate = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        let callback = state.withValue { $0.onSignificantMove }
        callback?(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLog.location.error("位置情報のエラー: \(error.localizedDescription, privacy: .public)")
        // requestLocation の失敗でも入域は落とさない。キャッシュの位置（無ければ nil）で配達する。
        deliverAllPending(fresh: nil)
    }
}
