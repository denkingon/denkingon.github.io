import UIKit
import os

/// 起動の入口。画面（SwiftUI の Scene）より先に、ここで全部の受け口を揃える。
///
/// 駅入域でアプリがバックグラウンド起動されたとき（`launchOptions[.location]`）は、画面は作られない。
/// それでも `didFinishLaunching` が return する前に、
///  - CLLocationManager とその delegate（GeofenceTrigger）
///  - UNUserNotificationCenter の delegate（通知ボタン）
///  - BGTaskScheduler への登録
/// が済んでいないと、保留中の入域イベントやボタン操作を取りこぼす。それを `AppEnvironment.launch()` が担う。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchedByRegionEvent = launchOptions?[.location] != nil
        AppEnvironment.shared.launch()
        if launchedByRegionEvent {
            AppLog.location.info("起動理由: 領域イベント（画面なしで判定する）")
        }
        return true
    }
}
