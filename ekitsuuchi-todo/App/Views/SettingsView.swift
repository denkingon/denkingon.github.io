import EkiCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - 設定 画面（コンテンツ設計書 §3）
//
// 通知の頻度・営業時間チェック・実測モード、権限の状態、JSON 取込、店の情報、台帳の件数。
// 値の読み書きはすべて AppModel の操作口を通す（ここでは台帳に直接触れない）。配色は無彩色のみ。

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importFeedback: ImportFeedback?
    @State private var showFormatHint = false

    var body: some View {
        NavigationStack {
            Form {
                notificationSection
                permissionSection
                locationReasonSection
                importSection
                shopInfoSection
                ledgerSection
                aboutSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    // MARK: 通知

    private var frequencyBinding: Binding<NotifyFrequency> {
        Binding(
            get: { model.ledger.settings.frequency },
            set: { newValue in model.updateSettings { $0.frequency = newValue } }
        )
    }

    private var checkHoursBinding: Binding<Bool> {
        Binding(
            get: { model.ledger.settings.checkBusinessHours },
            set: { newValue in model.updateSettings { $0.checkBusinessHours = newValue } }
        )
    }

    private var diagnosticBinding: Binding<Bool> {
        Binding(
            get: { model.ledger.settings.diagnosticMode },
            set: { newValue in model.updateSettings { $0.diagnosticMode = newValue } }
        )
    }

    private var notificationSection: some View {
        Section {
            Picker("通知の頻度", selection: frequencyBinding) {
                ForEach(NotifyFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("営業時間をチェックする", isOn: checkHoursBinding)
                Text("オフにすると、営業時間外や閉店間際の店でも通知します。営業時間が分からない店は、オンでも通知します。")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("実測モード", isOn: diagnosticBinding)
                Text("駅に入るたびに「○○駅に入った」とだけ通知し、位置と時刻を履歴に残します。タスクや営業時間は見ません。駅の半径を決めるための一時的な設定です。")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        } header: {
            Text("通知")
        } footer: {
            if model.ledger.settings.diagnosticMode {
                Text("実測モードがオンです。頻度や営業時間に関係なく、駅に入るたびに通知します。")
            } else {
                Text("既定は「駅ごとに1日1回」です。通知は「完了」「今日は無視」のボタンから、アプリを開かずに操作できます。")
            }
        }
    }

    // MARK: 権限

    private var permissionSection: some View {
        Section {
            LabeledContent("位置情報", value: model.locationAuthorization.label)
            locationAction

            LabeledContent("通知", value: Self.notificationLabel(model.notificationStatus))
            notificationAction
        } header: {
            Text("権限")
        } footer: {
            Text(permissionFooter)
        }
    }

    /// 位置情報が「常に」でないときの案内と操作。
    /// 未設定のときだけアプリ内から許可を求められる。それ以外（使用中のみ・拒否・制限）は iOS が再度は尋ねないので、設定アプリへ案内する。
    @ViewBuilder
    private var locationAction: some View {
        switch model.locationAuthorization {
        case .always:
            EmptyView()
        case .notDetermined:
            Text(PermissionCopy.locationAlwaysRequired)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Button {
                model.requestLocationAuthorization()
            } label: {
                Label("許可する", systemImage: "location")
            }
        case .whenInUse:
            Text("\(PermissionCopy.locationAlwaysRequired)（設定 > 位置情報 > 「常に」）")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            settingsButton
        case .denied, .restricted:
            Text("\(PermissionCopy.locationAlwaysRequired)（設定 > 位置情報 > 「常に」）")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            settingsButton
        }
    }

    @ViewBuilder
    private var notificationAction: some View {
        switch model.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            EmptyView()
        case .notDetermined:
            Text(PermissionCopy.notificationReason)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Button {
                Task { await model.requestNotificationAuthorization() }
            } label: {
                Label("許可する", systemImage: "bell")
            }
        case .denied:
            Text(PermissionCopy.notificationDenied)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            settingsButton
        @unknown default:
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button {
            model.openSystemSettings()
        } label: {
            Label("設定を開く", systemImage: "gearshape")
        }
    }

    private var notificationIsUsable: Bool {
        switch model.notificationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private var permissionFooter: String {
        if model.locationAuthorization.isAlways && notificationIsUsable {
            return "必要な許可はそろっています。"
        }
        return "駅に入ったことをバックグラウンドで知るには、位置情報「常に」と通知の許可が両方必要です。"
    }

    private static func notificationLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "未設定"
        case .denied: return "拒否"
        case .authorized: return "許可"
        case .provisional: return "許可（目立たない通知）"
        case .ephemeral: return "一時的に許可"
        @unknown default: return "不明"
        }
    }

    // MARK: 位置情報の使い方

    private var locationReasonSection: some View {
        Section {
            // App Store 審査の理由文と同じ文（計画書 §2）。PermissionCopy が project.yml の文言と一致させている。
            Text(PermissionCopy.locationReason)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
        } header: {
            Text("位置情報の使い方")
        } footer: {
            Text("位置情報は端末の中だけで使い、外へは送りません。外に出る通信は、店の営業時間を調べる Google Places への問い合わせだけです。")
        }
    }

    // MARK: 取込

    private static let jsonSample = """
    {
      "version": 1,
      "items": [
        {"store": "ダイソー", "item": "フィルム",
         "source": "LINE:友人", "date": "2026-09-14"}
      ]
    }
    """

    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label("JSON ファイルを選ぶ", systemImage: "doc.badge.plus")
            }
            .disabled(isImporting)

            if isImporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("取り込んでいます…")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }

            if let feedback = importFeedback {
                importResult(feedback)
            }

            DisclosureGroup("入力 JSON の形式（v1）", isExpanded: $showFormatHint) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.jsonSample)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                    Text("store（店）と item（品目）は必須です。source（出典）と date（yyyy-MM-dd）は省略できます。")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Text("同じ店・品目が未完了で既にあれば追加しません。形式の合わない行は飛ばして、残りを取り込みます。")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        } header: {
            Text("取込")
        } footer: {
            Text("iCloud Drive などにある .json ファイルを選びます。未登録の店は取り込み後に自動で登録します。")
        }
    }

    @ViewBuilder
    private func importResult(_ feedback: ImportFeedback) -> some View {
        let remaining = feedback.rejected - feedback.rejectedReasons.count
        VStack(alignment: .leading, spacing: 4) {
            // 失敗は色ではなく「!」と太さで示す。
            Text(feedback.isFailure ? "! \(feedback.summaryLine)" : feedback.summaryLine)
                .font(.subheadline.weight(feedback.isFailure ? .semibold : .regular))
                .foregroundStyle(Color.primary)
            ForEach(Array(feedback.rejectedReasons.enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            if remaining > 0 {
                Text("ほか \(remaining) 件")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // 選択をやめただけ（キャンセル）のときは何も出さない。
            if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return }
            importFeedback = ImportFeedback(errorMessage: "ファイルを開けませんでした（\(error.localizedDescription)）")
        case .success(let urls):
            guard let url = urls.first else { return }
            importFeedback = nil
            isImporting = true
            Task { @MainActor in
                let feedback = await model.importJSON(from: url)
                importFeedback = feedback
                isImporting = false
            }
        }
    }

    // MARK: 店の情報

    private var canRefreshHours: Bool {
        model.placesConfigured
            && !model.ledger.registeredChains.isEmpty
            && model.busyMessage == nil
    }

    private var shopInfoSection: some View {
        Section {
            LabeledContent("Places API キー", value: model.placesConfigured ? "設定済み" : "未設定")
            LabeledContent("最終更新", value: Self.refreshText(model.lastHoursRefresh))

            Button {
                Task { await model.refreshAllHours() }
            } label: {
                Label("今すぐ更新", systemImage: "arrow.clockwise")
            }
            .disabled(!canRefreshHours)

            if let report = model.lastReport {
                VStack(alignment: .leading, spacing: 2) {
                    Text("直近の結果")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(Color.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("店の情報")
        } footer: {
            Text(shopInfoFooter)
        }
    }

    private var shopInfoFooter: String {
        if !model.placesConfigured { return PermissionCopy.placesKeyMissing }
        if model.ledger.registeredChains.isEmpty {
            return "登録済みの店がありません。台帳でタスクを書くか、店の画面でチェーン名を追加してください。"
        }
        if model.busyMessage != nil { return "別の処理が終わるまでお待ちください。" }
        return "登録済みの全チェーンの支店と営業時間を取り直します。営業時間は週に1回、自動でも更新します。"
    }

    private static let refreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter
    }()

    private static func refreshText(_ date: Date?) -> String {
        guard let date else { return "未更新" }
        return refreshFormatter.string(from: date)
    }

    // MARK: 台帳

    @ViewBuilder
    private var ledgerSection: some View {
        let ledger = model.ledger
        let now = Date()
        let pending = ledger.tasks.filter { $0.isPending(at: now) }.count
        Section {
            LabeledContent("タスク", value: "\(ledger.tasks.count) 件（未完了 \(pending) 件）")
            LabeledContent("駅", value: "\(ledger.stations.count) 件")
            LabeledContent("登録済みの店", value: "\(ledger.registeredChains.count) 件")
            LabeledContent("支店", value: "\(ledger.branches.count) 件")
            LabeledContent("履歴", value: "\(ledger.history.count) 件")
        } header: {
            Text("台帳")
        } footer: {
            Text("履歴は新しい \(Tuning.maxHistoryRecords) 件まで残し、超えた分は古いものから消えます。")
        }
    }

    // MARK: アプリ

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "\(short)（\(build)）"
        }
        return short
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("バージョン", value: versionText)
        } header: {
            Text("アプリ")
        }
    }
}
