import SwiftUI

/// 5 つの画面の入れ物。台帳の購読（`model.start()`）と、画面共通の知らせ（アラート・細いバナー）だけをここで持つ。
/// 配色は無彩色のみ（アプリ側の `.tint(.primary)` と、バナーのシステムグレー）。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// 「壊れた台帳を退避した」知らせを閉じたか。この起動の間だけの表示状態で、保存はしない。
    @State private var warningDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            banners
            tabs
        }
        // start() は台帳の更新を受け取り続け、画面が消える（キャンセル）まで戻らない。
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            // 設定アプリで許可を変えて戻ってきた、取り込み後に前面へ戻った、などをここで拾う。
            if phase == .active {
                Task { await model.didBecomeActive() }
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: alertIsPresented,
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var tabs: some View {
        TabView {
            LedgerView()
                .tabItem { Label("台帳", systemImage: "checklist") }
            StationsView()
                .tabItem { Label("駅", systemImage: "tram.fill") }
            ShopsView()
                .tabItem { Label("店", systemImage: "storefront") }
            HistoryView()
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { presented in
                if !presented { model.alert = nil }
            }
        )
    }

    // MARK: バナー

    /// 画面の上に出す細い帯。常設の知らせ（台帳を開けない・退避した）と、登録・更新・取込の最中の文言。
    private var banners: some View {
        VStack(spacing: 0) {
            if let error = model.ledgerError {
                banner(
                    icon: "exclamationmark.triangle",
                    text: "台帳を開けません: \(error)（変更は保存されません）"
                )
                .transition(.opacity)
            }
            if let warning = model.ledgerWarning, !warningDismissed {
                banner(icon: "info.circle", text: warning) {
                    warningDismissed = true
                }
                .transition(.opacity)
            }
            if let busy = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busy)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.busyMessage)
        .animation(.default, value: model.ledgerError)
        .animation(.default, value: warningDismissed)
    }

    private func banner(icon: String, text: String, onDismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.primary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray5))
    }
}
