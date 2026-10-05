import EkiCore
import Foundation
import os
import UserNotifications

/// 通知を出せなかった理由。履歴の「detail」にそのまま載るので、文言は人が読める日本語にする。
enum NotificationPostError: LocalizedError {
    case notAuthorized(UNAuthorizationStatus)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "通知が許可されていません（設定 > 通知）"
        }
    }
}

/// `NotificationPosting` の iOS 実装（UNUserNotificationCenter、ローカル通知）。
final class UserNotificationPoster: NotificationPosting, @unchecked Sendable {
    static let categoryID = "EKI_TASKS"
    static let completeActionID = "COMPLETE"
    static let ignoreTodayActionID = "IGNORE_TODAY"

    // @unchecked Sendable の根拠: 持つ状態が無い（UNUserNotificationCenter.current() は都度取る）。
    init() {}

    /// 完了／今日は無視 の 2 ボタン付きカテゴリを登録する。起動時（delegate 設定と同じ場所）で 1 回呼ぶ。
    /// `.foreground` を付けない: ボタンはアプリを開かずに台帳を更新する（§3）。
    static func registerCategories() {
        let complete = UNNotificationAction(identifier: completeActionID, title: "完了", options: [])
        let ignoreToday = UNNotificationAction(identifier: ignoreTodayActionID, title: "今日は無視", options: [])
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [complete, ignoreToday],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// 許可ダイアログを出す（初回のみ表示される）。結果の可否を返す。
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            AppLog.notify.error("通知の許可要求に失敗: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func post(_ content: NotificationContent) async throws {
        let center = UNUserNotificationCenter.current()

        // 拒否されていても add はエラーにならず通知が黙って捨てられる。履歴に「出せなかった」と残すため、先に自分で確かめる（D9）。
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            throw NotificationPostError.notAuthorized(status)
        }

        let mutable = UNMutableNotificationContent()
        mutable.title = content.title
        mutable.body = content.body
        mutable.sound = .default
        mutable.categoryIdentifier = Self.categoryID
        // 駅ごとにスレッドへ束ねる。
        mutable.threadIdentifier = content.stationID.uuidString
        mutable.userInfo = [
            "stationID": content.stationID.uuidString,
            "taskIDs": content.taskIDs.map { $0.uuidString },
        ]

        // trigger: nil = 今すぐ。識別子は毎回新規（同じ駅の通知を置き換えない）。
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: mutable, trigger: nil)
        try await center.add(request)
        AppLog.notify.info("通知を出した: タスク \(content.taskIDs.count) 件")
    }
}
