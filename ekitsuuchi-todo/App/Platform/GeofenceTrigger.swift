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
///
/// 寿命: `CLLocationManager.delegate` は weak。このオブジェクト（= delegate）をアプリ側が強参照で持ち続けること
/// （AppDelegate / アプリ全体のモデルのプロパティなど）。手放すと領域イベントが二度と届かない。
final class GeofenceTrigger: NSObject, TriggerSource, CLLocationManagerDelegate, @unchecked Sendable {
    // 可変状態はまとめて Locked に入れる（設定はどのスレッドからでも、読むのは主に delegate = メイン）。
    private struct State {
        var onTrigger: (@Sendable (TriggerEvent) -> Void)?
        var onSignificantMove: (@Sendable (Coordinate) -> Void)?
        var onAuthorizationChange: (@Sendable (LocationAuthorization) -> Void)?
        var authorization: LocationAuthorization
        /// 初回に「使用中のみ」を通った直後、続けて「常に」を求めるための印。
        var wantsAlways = false
    }

    // @unchecked Sendable の根拠: manager はメインでのみ操作する。他スレッドからは `location` の読み取りだけ。
    private let manager: CLLocationManager
    private let state: Locked<State>

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.state = Locked(State(authorization: LocationAuthorization(manager.authorizationStatus)))
        super.init()
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

    var authorization: LocationAuthorization {
        state.withValue { $0.authorization }
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

        // 同じ ID が二重に入っていても最後のものを採る（Dictionary(uniqueKeysWithValues:) は重複で落ちる）。
        var wanted: [String: Station] = [:]
        for station in plan.stations {
            wanted[station.id.uuidString] = station
        }

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

        for (identifier, station) in wanted where !alreadyCorrect.contains(identifier) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude),
                radius: effectiveRadius(for: station),
                identifier: identifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }

        if plan.tracksSignificantLocationChanges {
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
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

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion,
              let stationID = UUID(uuidString: circular.identifier) else {
            AppLog.location.debug("対象外の領域に入った: \(region.identifier, privacy: .public)")
            return
        }

        var fix: LocationFix?
        if let location = manager.location {
            fix = LocationFix(
                coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                horizontalAccuracy: location.horizontalAccuracy,
                timestamp: location.timestamp
            )
        }
        // 判定器に渡す時刻は「イベントを受け取った今」。fix.timestamp は古いことがあるので別に持つ。
        let event = TriggerEvent(stationID: stationID, firedAt: Date(), location: fix)
        AppLog.location.info("入域: \(stationID.uuidString, privacy: .public)")
        let callback = state.withValue { $0.onTrigger }
        guard let callback else {
            // 受け側の設定が間に合っていない。入域は履歴にも残らないので、ログだけは確実に残す。
            AppLog.location.error("入域を受けたが onTrigger が未設定: \(stationID.uuidString, privacy: .public)")
            return
        }
        callback(event)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        AppLog.location.error("領域監視の失敗 \(region?.identifier ?? "-", privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = LocationAuthorization(manager.authorizationStatus)
        // ロックの中ではコールバックを呼ばない。必要な情報だけ取り出して外で使う。
        let (callback, shouldAskAlways) = state.withValue { current -> ((@Sendable (LocationAuthorization) -> Void)?, Bool) in
            current.authorization = status
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
            return (current.onAuthorizationChange, ask)
        }
        AppLog.location.info("位置情報の許可: \(status.label, privacy: .public)")
        if shouldAskAlways {
            manager.requestAlwaysAuthorization()
        }
        callback?(status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        let callback = state.withValue { $0.onSignificantMove }
        callback?(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLog.location.error("位置情報のエラー: \(error.localizedDescription, privacy: .public)")
    }
}
