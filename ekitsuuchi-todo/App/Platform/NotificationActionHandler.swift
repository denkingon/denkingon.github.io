import Foundation
import UserNotifications
import os

/// 通知の操作（ボタン・タップ）を、アプリの言葉に直したもの。
enum NotificationAction: Equatable, Sendable {
    /// 通知に載っていたタスクをすべて完了にする（D3: ボタンは「どれか」を聞けない。変えるときは受け側の 1 か所）。
    case complete(taskIDs: [UUID])
    /// 今日だけ止める（D2: 明日 0 時に未完了へ戻る）。
    case ignoreToday(taskIDs: [UUID])
    /// 通知本体のタップ。
    case open
}

/// UNUserNotificationCenter の delegate。
/// 起動中のなるべく早い段階（`application(_:didFinishLaunchingWithOptions:)`）で
/// `UNUserNotificationCenter.current().delegate` に設定すること。通知のボタンでバックグラウンド起動されたとき、
/// delegate がまだ無いと操作が届かず、タスクが更新されないまま終わる。
/// `UNUserNotificationCenter.delegate` は weak なので、このオブジェクトはアプリ側が強参照で持ち続けること。
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // @unchecked Sendable の根拠: 可変状態は Locked 経由でのみ触る。
    private let handler = Locked<(@Sendable (NotificationAction) async -> Void)?>(nil)

    var onAction: (@Sendable (NotificationAction) async -> Void)? {
        get { handler.withValue { $0 } }
        set { handler.withValue { $0 = newValue } }
    }

    /// 前面表示中でも出す（駅に入った瞬間にアプリを開いていても、見逃さない）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // UNNotificationResponse は await をまたいで持ち回らない。必要な値だけ先に取り出す。
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        guard let action = Self.action(actionIdentifier: actionID, userInfo: userInfo) else {
            AppLog.notify.debug("通知の操作は対象外: \(actionID, privacy: .public)")
            return
        }
        guard let onAction = self.onAction else {
            AppLog.notify.error("通知の操作が届いたが受け側が未設定: \(actionID, privacy: .public)")
            return
        }
        // 戻ると iOS はアプリを再び止める（持ち時間は数秒）ので、台帳への書き込みが終わるまで返らない。
        await withBackgroundTime("notification-action") {
            await onAction(action)
        }
    }

    /// 識別子 → 操作。nil = 何もしない（消去ボタン・知らない ID）。副作用が無いので切り出してある。
    static func action(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationAction? {
        switch actionIdentifier {
        case UserNotificationPoster.completeActionID:
            return .complete(taskIDs: taskIDs(from: userInfo))
        case UserNotificationPoster.ignoreTodayActionID:
            return .ignoreToday(taskIDs: taskIDs(from: userInfo))
        case UNNotificationDefaultActionIdentifier:
            return .open
        default:
            // UNNotificationDismissActionIdentifier もここ。消去しただけでは台帳を動かさない。
            return nil
        }
    }

    static func taskIDs(from userInfo: [AnyHashable: Any]) -> [UUID] {
        guard let strings = userInfo["taskIDs"] as? [String] else { return [] }
        return strings.compactMap { UUID(uuidString: $0) }
    }
}
