import SwiftUI

@main
@MainActor
struct EkiTsuuchiApp: App {
    // 起動の受け口（領域イベント・通知ボタン・バックグラウンド更新）は AppDelegate 経由で AppEnvironment が揃える。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.primary)
        }
    }
}
