import EkiCore
import SwiftUI

// MARK: - 店 画面（コンテンツ設計書 §3）
//
// チェーン名 → 駅ごとの支店 → 今日の営業時間。チェーン名で追加、支店に属性タグ（規模）、再取得、削除。
// 台帳の読み書きはすべて AppModel の操作口を通す。色は無彩色のみ。
// 破壊的操作に `role: .destructive` を使わない（システムが赤にするため）。確認ダイアログで代える。

/// 1 つのチェーンの下に並べる行。駅の見出し → その駅の近くの支店、を平らに並べる。
private struct ShopRow: Identifiable {
    enum Kind {
        case station(Station, count: Int)
        case branch(Branch, meters: Double)
        case noBranches(Station)
    }

    let id: String
    let kind: Kind
}

struct ShopsView: View {
    @Environment(AppModel.self) private var model

    @State private var newChain = ""
    @State private var addFeedback: String?
    @State private var isAdding = false
    /// 登録・再取得の最中のチェーン（`ChainName.key`）。同じ店への二重の問い合わせ（Places の料金）を防ぐ。
    @State private var busyChainKeys = Set<String>()
    @State private var chainToRemove: String?
    @FocusState private var addFocused: Bool

    private var ledger: Ledger { model.ledger }
    private var chains: [String] { ledger.registeredChains }
    private var registeredKeys: Set<String> { Set(chains.map { ChainName.key($0) }) }

    /// 未完了・無視のタスクには出てくるが、店登録がまだのチェーン（登録に失敗した、削除した、など）。
    /// 完了済みのタスクだけの店は出さない（店を削除しても完了済みの履歴から居座らないように。HoursRefresher と同じ基準）。
    private var unregistered: [String] {
        let keys = registeredKeys
        var seen = Set<String>()
        var names: [String] = []
        for task in ledger.tasks where task.status != .done {
            let key = ChainName.key(task.store)
            if !key.isEmpty, !keys.contains(key), seen.insert(key).inserted {
                names.append(task.store)
            }
        }
        return names
    }

    private var isReadyToEdit: Bool { model.isReady && model.ledgerError == nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                noticeBar
                if isReadyToEdit {
                    addArea
                }
                content
            }
            .navigationTitle("店")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                chainToRemove.map { "\($0) を削除しますか？" } ?? "店を削除しますか？",
                isPresented: Binding(
                    get: { chainToRemove != nil },
                    set: { presented in
                        if !presented { chainToRemove = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: chainToRemove
            ) { chain in
                Button("削除") { model.removeChain(chain) }
                Button("キャンセル", role: .cancel) {}
            } message: { chain in
                Text("\(chain) の支店の記録を消します。この店のタスクは残ります。")
            }
            .onChange(of: newChain) { _, _ in
                addFeedback = nil
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !model.isReady {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.ledgerError {
            ContentUnavailableView(
                "台帳を開けません",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if chains.isEmpty && unregistered.isEmpty {
            ContentUnavailableView {
                Label("店がありません", systemImage: "storefront")
            } description: {
                Text("チェーン名（例: ダイソー）を入れると、登録した駅の近くの支店と営業時間を取ってきます。")
            }
        } else {
            list
        }
    }

    private var list: some View {
        let now = Date()
        return List {
            if !unregistered.isEmpty {
                Section {
                    ForEach(unregistered, id: \.self) { name in
                        unregisteredRow(name)
                    }
                } header: {
                    Text("未登録の店")
                } footer: {
                    Text("タスクにある店です。登録すると、駅の近くの支店を探します。")
                }
            }
            ForEach(chains, id: \.self) { chain in
                Section {
                    ForEach(rows(for: chain)) { row in
                        rowView(row, now: now)
                    }
                } header: {
                    chainHeader(chain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: 通知バー

    private struct Notice: Identifiable {
        let id: String
        let icon: String
        let text: String
    }

    private var notices: [Notice] {
        var list: [Notice] = []
        guard isReadyToEdit else { return list }
        if !model.placesConfigured {
            list.append(Notice(id: "places", icon: "exclamationmark.triangle", text: PermissionCopy.placesKeyMissing))
        }
        if ledger.stations.isEmpty {
            list.append(Notice(
                id: "stations",
                icon: "tram.fill",
                text: "駅が未登録です。「駅」タブで駅を追加すると、近くの支店を探します。"
            ))
        }
        if let report = model.lastReport {
            list.append(Notice(id: "report", icon: "info.circle", text: report))
        }
        return list
    }

    @ViewBuilder
    private var noticeBar: some View {
        let items = notices
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { notice in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: notice.icon)
                            .foregroundStyle(Color.secondary)
                        Text(notice.text)
                            .font(.footnote)
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
        }
    }

    // MARK: チェーンを足す

    private var canSubmitChain: Bool {
        !ChainName.key(newChain).isEmpty && !isAdding && model.busyMessage == nil
    }

    private var addArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("チェーン名（例: ダイソー）", text: $newChain)
                    .focused($addFocused)
                    .submitLabel(.done)
                    .onSubmit { submitChain() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                Button("追加") { submitChain() }
                    .buttonStyle(.bordered)
                    .disabled(!canSubmitChain)
            }
            if let addFeedback {
                Text(addFeedback)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func submitChain() {
        let name = newChain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitChain else { return }
        if registeredKeys.contains(ChainName.key(name)) {
            addFeedback = "「\(name)」はすでに登録されています。支店を取り直すには、見出しの「…」から再取得してください。"
            return
        }
        newChain = ""
        addFeedback = nil
        addFocused = false
        isAdding = true
        let model = self.model
        Task { @MainActor in
            await model.addChain(name)
            isAdding = false
        }
    }

    // MARK: 未登録の店

    private func unregisteredRow(_ name: String) -> some View {
        let key = ChainName.key(name)
        let working = busyChainKeys.contains(key)
        return HStack(spacing: 8) {
            Text(name)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            if working {
                ProgressView()
            } else {
                Button("登録") { register(name) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.busyMessage != nil)
            }
        }
    }

    private func register(_ name: String) {
        let key = ChainName.key(name)
        guard busyChainKeys.insert(key).inserted else { return }
        let model = self.model
        Task { @MainActor in
            await model.addChain(name)
            busyChainKeys.remove(key)
        }
    }

    // MARK: チェーン

    private func chainHeader(_ chain: String) -> some View {
        let key = ChainName.key(chain)
        let working = busyChainKeys.contains(key)
        let total = ledger.branches.filter { ChainName.matches($0.chainName, chain) }.count
        return HStack(spacing: 8) {
            Text(chain)
                .font(.headline)
                .foregroundStyle(Color.primary)
            Text("\(total) 店")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 8)
            if working {
                ProgressView()
            }
            Menu {
                Button {
                    refetch(chain)
                } label: {
                    Label("再取得", systemImage: "arrow.clockwise")
                }
                .disabled(working || model.busyMessage != nil)
                Button {
                    chainToRemove = chain
                } label: {
                    Label("削除…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityLabel("\(chain)の操作")
        }
        .textCase(nil)
    }

    private func refetch(_ chain: String) {
        let key = ChainName.key(chain)
        guard busyChainKeys.insert(key).inserted else { return }
        let model = self.model
        Task { @MainActor in
            await model.reregisterChain(chain)
            busyChainKeys.remove(key)
        }
    }

    // MARK: 行

    private func rows(for chain: String) -> [ShopRow] {
        let key = ChainName.key(chain)
        var rows: [ShopRow] = []
        for station in ledger.stations {
            let found = ledger.branches(ofChain: chain, nearStation: station.id)
            rows.append(ShopRow(id: "\(key)|s|\(station.id)", kind: .station(station, count: found.count)))
            if found.isEmpty {
                rows.append(ShopRow(id: "\(key)|n|\(station.id)", kind: .noBranches(station)))
            }
            for item in found {
                rows.append(ShopRow(
                    id: "\(key)|b|\(station.id)|\(item.branch.id)",
                    kind: .branch(item.branch, meters: item.meters)
                ))
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: ShopRow, now: Date) -> some View {
        switch row.kind {
        case .station(let station, let count):
            HStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .foregroundStyle(Color.secondary)
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(station.isEnabled ? Color.primary : Color.secondary)
                if !station.isEnabled {
                    Text("無効")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(.systemGray5), in: Capsule())
                }
                Spacer(minLength: 8)
                Text("\(count) 店")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .listRowBackground(Color(.systemGray6))
        case .noBranches(let station):
            Text(noBranchesText(station))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        case .branch(let branch, let meters):
            ShopBranchRow(branch: branch, meters: meters, now: now) { value in
                model.setBranchAttribute(branchID: branch.id, key: ShopBranchRow.sizeKey, value: value)
            }
        }
    }

    private func noBranchesText(_ station: Station) -> String {
        if !station.isEnabled { return "駅が無効のため、支店を探していません。" }
        return "駅から \(Int(Tuning.branchSearchRadiusMeters)) m 以内に見つかっていません。"
    }
}

// MARK: - 支店の行

private struct ShopBranchRow: View {
    /// 属性のキー（コンテンツ設計書 §2: 規模=大型 など。v0 は手動）。
    static let sizeKey = "規模"
    private static let sizeOptions = ["", "大型", "小型"]

    let branch: Branch
    let meters: Double
    let now: Date
    /// nil = 属性を消す。
    let onSetSize: (String?) -> Void

    /// 徒歩の分数 = ceil(距離 / 80)（Tuning。D6）。
    private var walkingMinutes: Int {
        max(1, Int((meters / Tuning.walkingMetersPerMinute).rounded(.up)))
    }

    private var hoursText: String {
        guard let hours = branch.hours else { return "営業時間不明" }
        let today = hours.todayText(at: now)
        switch hours.status(at: now) {
        case .open: return "今日 \(today)・営業中"
        case .closed: return "今日 \(today)・営業時間外"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                Text("徒歩\(walkingMinutes)分（\(Int(meters.rounded())) m）")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Text(hoursText)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 8)
            sizeMenu
        }
    }

    private var sizeMenu: some View {
        let current = branch.attributes[Self.sizeKey] ?? ""
        // 将来、在庫調査が書いた別の値が入っていても、選択肢に出して消えないようにする。
        let options = Self.sizeOptions.contains(current) ? Self.sizeOptions : Self.sizeOptions + [current]
        return Menu {
            Picker(
                Self.sizeKey,
                selection: Binding(
                    get: { current },
                    set: { value in onSetSize(value.isEmpty ? nil : value) }
                )
            ) {
                ForEach(options, id: \.self) { value in
                    Text(value.isEmpty ? "なし" : value).tag(value)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.isEmpty ? Self.sizeKey : current)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(current.isEmpty ? Color(.systemGray6) : Color(.systemGray4), in: Capsule())
        }
        .accessibilityLabel("\(Self.sizeKey): \(current.isEmpty ? "なし" : current)")
    }
}
