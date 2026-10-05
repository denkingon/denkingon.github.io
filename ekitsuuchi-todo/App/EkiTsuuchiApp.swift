import SwiftUI

// 仮のエントリポイント（Phase 3 で AppDelegate・AppModel・画面に置き換える）。
// iOS アダプタ層（App/Platform）を CI でコンパイルして確かめるために置いている。
@main
struct EkiTsuuchiApp: App {
    var body: some Scene {
        WindowGroup { Text("駅通知todo") }
    }
}
