import Foundation
import UIKit
import os

/// ジオフェンスでバックグラウンド起動されたあと、台帳の書き込みの途中で一時停止されないように
/// iOS に少し時間（実測で数十秒）を借りる。返るのは `body` が終わったとき。
/// 時間切れの通知が来たら借りた時間は返す（返さないとアプリごと終了させられる）が、`body` は止めない。
func withBackgroundTime<T>(_ name: String, _ body: () async -> T) async -> T {
    let handle = await MainActor.run { () -> BackgroundTaskHandle in
        let handle = BackgroundTaskHandle()
        handle.begin(name)
        return handle
    }
    let result = await body()
    await MainActor.run { handle.end() }
    return result
}

/// UIApplication はメインでしか触れないので、識別子ごとメインに閉じ込める。
@MainActor
private final class BackgroundTaskHandle {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // 時間切れ。UIKit はこのハンドラをメインスレッドで同期的に呼ぶ。
            // ここで endBackgroundTask しないと、アプリごと終了させられる。
            MainActor.assumeIsolated {
                AppLog.refresh.notice("バックグラウンド時間切れ: \(name, privacy: .public)")
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// 領域イベントを受けた瞬間から、判定・通知の配達まで（新しい位置を待つ間を含む）を覆う共有の借り時間。
/// `withBackgroundTime` は AppEnvironment.handleTrigger が配達のあとで始めるので、その前の待ちはこちらで覆う。
/// begin は何度呼んでも 1 本だけ借りる。メインでだけ使う。
@MainActor
final class BackgroundHold {
    static let shared = BackgroundHold()
    private let handle = BackgroundTaskHandle()
    private var held = false

    func begin(_ name: String) {
        guard !held else { return }
        held = true
        handle.begin(name)
    }

    func end() {
        guard held else { return }
        held = false
        handle.end()
    }
}
