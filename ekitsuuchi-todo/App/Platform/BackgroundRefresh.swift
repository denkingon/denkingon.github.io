import BackgroundTasks
import Foundation
import os

/// 営業時間の週 1 更新（§4 週1更新）を iOS のバックグラウンド更新に乗せる。
/// 実行時刻は iOS が決める。Core 側は「7 日より古い行だけ」取り直すので、何度起こされても安い。
enum BackgroundRefresh {
    static let taskID = "dev.denkingon.ekitsuuchi.refresh"

    /// 重要: `application(_:didFinishLaunchingWithOptions:)` が return する前に呼ぶこと
    /// （BGTaskScheduler の制約。後で登録するとクラッシュする）。Info.plist の
    /// BGTaskSchedulerPermittedIdentifiers に `taskID` が要る。
    static func register(work: @escaping @Sendable () async -> Bool) {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            handle(task, work: work)
        }
        if !registered {
            AppLog.refresh.error("バックグラウンド更新の登録に失敗")
        }
    }

    /// 次の起動希望を出す。連続して呼んでも置き換わるだけ。
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        // 「これより前には起こさないで」の下限。実際の時刻は iOS 次第（使用状況・電池）。
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // シミュレータでは常に失敗する。実機でもバックグラウンド更新が切られていると失敗する。
            AppLog.refresh.error("バックグラウンド更新の予約に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGTask, work: @escaping @Sendable () async -> Bool) {
        // 先に次回を予約する（この実行が失敗しても連鎖が切れないように）。
        schedule()

        let completion = TaskCompletion(task)
        let worker = Task {
            let success = await work()
            completion.complete(success: success)
        }
        task.expirationHandler = {
            // 時間切れ。作業を止めて、未完了として返す。work 側は Task のキャンセルで止まる。
            worker.cancel()
            completion.complete(success: false)
        }
    }
}

/// `setTaskCompleted` は 1 回だけ呼ぶ決まり。完了と時間切れが競合しても 1 回にする。
private final class TaskCompletion: @unchecked Sendable {
    // @unchecked Sendable の根拠: BGTask は完了通知にしか使わず、その呼び出しを done フラグ（NSLock）で 1 回に絞る。
    private let task: BGTask
    private let done = Locked(false)

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        let isFirst = done.withValue { finished -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if isFirst {
            task.setTaskCompleted(success: success)
        }
    }
}
