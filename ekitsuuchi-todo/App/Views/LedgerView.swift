import EkiCore
import SwiftUI
import UserNotifications

// MARK: - 台帳 画面（コンテンツ設計書 §3）
//
// 全タスクを一括で扱う統一層。未完了を店ごとに束ねて見せ、追加・完了・無視・戻す・削除・複数選択をここで行う。
// 台帳の読み書きはすべて AppModel の操作口を通す（ここでは Repository に触れない）。
// 色は無彩色のみ。破壊的操作に `role: .destructive` を使わない（システムが赤にするため）。確認ダイアログで代える。

private enum LedgerFilter: String, CaseIterable, Identifiable {
    case pending
    case ignored
    case done
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending: return "未完了"
        case .ignored: return "無視"
        case .done: return "完了"
        case .all: return "すべて"
        }
    }
}

private enum AddField: Hashable {
    case store
    case item
}

private enum AddFeedback: Equatable {
    case added(store: String, item: String)
    case duplicate
    case failed(String)

    var text: String {
        switch self {
        case .added(let store, let item): return "追加しました: \(store)／\(item)"
        case .duplicate: return "同じ店・品目が未完了で既にあります"
        case .failed(let message): return message
        }
    }
}

/// 店ごとの束。`id` は `ChainName.key`（表記ゆれを同じ店にまとめる）。
private struct StoreGroup: Identifiable {
    let id: String
    let name: String
    let tasks: [TodoTask]
}

/// 画面の上に出す、通知が鳴らない原因の案内（駅が無い・許可が無い）。
private struct LedgerNotice: Identifiable {
    let id: String
    let icon: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

struct LedgerView: View {
    @Environment(AppModel.self) private var model

    @State private var filter: LedgerFilter = .pending
    @State private var searchText = ""

    @State private var storeText = ""
    @State private var itemText = ""
    @State private var feedback: AddFeedback?
    @State private var isAdding = false
    @FocusState private var focus: AddField?

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmDelete = false

    /// 複数選択中か。`EditMode.isEditing` は `.transient` でも true になり、行をスワイプしている間に
    /// List が `.transient` へ変えるので、使うと追加欄・タブバーがスワイプ中に消える。`.active` だけを見る。
    private var isEditing: Bool { editMode == .active }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                noticeBar
                if !isEditing {
                    addArea
                }
                filterPicker
                content
            }
            .navigationTitle(isEditing ? "\(selectedTasks.count) 件選択" : "台帳")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "店名・品目で絞る"
            )
            .toolbar { toolbarContent }
            // 一括操作のバーを出すので、編集中はタブバーを隠す。
            .toolbar(isEditing ? Visibility.hidden : Visibility.automatic, for: .tabBar)
            .confirmationDialog(
                "選択した \(selectedTasks.count) 件を削除しますか？",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("削除") { bulkDelete() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("削除したタスクは戻せません。")
            }
            .onChange(of: isEditing) { _, editing in
                if !editing { selection.removeAll() }
            }
        }
    }

    // MARK: 絞り込み

    private func matches(_ task: TodoTask, _ filter: LedgerFilter, now: Date) -> Bool {
        switch filter {
        case .pending: return task.isPending(at: now)
        case .ignored: return task.status == .ignored && !task.isPending(at: now)
        case .done: return task.status == .done
        case .all: return true
        }
    }

    private func matchesSearch(_ task: TodoTask) -> Bool {
        let key = ChainName.key(searchText)
        if key.isEmpty { return true }
        return ChainName.key(task.store).contains(key)
            || ChainName.key(task.item).contains(key)
    }

    /// いま見えているタスク（絞り込みと検索を通ったもの）。
    private var visibleTasks: [TodoTask] {
        let now = Date()
        return model.ledger.tasks.filter { matches($0, filter, now: now) && matchesSearch($0) }
    }

    private func count(for filter: LedgerFilter) -> Int {
        let now = Date()
        return model.ledger.tasks.filter { matches($0, filter, now: now) }.count
    }

    /// 選択中のうち、いま見えているもの（絞り込みや検索を変えたあとに、見えない行へ操作が及ばないように）。
    private var selectedTasks: [TodoTask] {
        visibleTasks.filter { selection.contains($0.id) }
    }

    private func groups(of tasks: [TodoTask], now: Date) -> [StoreGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var buckets: [String: [TodoTask]] = [:]
        for task in tasks {
            let key = ChainName.key(task.store).isEmpty ? task.store : ChainName.key(task.store)
            if names[key] == nil {
                order.append(key)
                names[key] = task.store
            }
            buckets[key, default: []].append(task)
        }
        let built = order.map { key -> StoreGroup in
            let sorted = (buckets[key] ?? []).sorted { a, b in
                let ra = rank(a, now: now), rb = rank(b, now: now)
                if ra != rb { return ra < rb }
                return a.createdAt < b.createdAt
            }
            return StoreGroup(id: key, name: names[key] ?? key, tasks: sorted)
        }
        return built.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 束の中の並び: 未完了、無視、完了の順。
    private func rank(_ task: TodoTask, now: Date) -> Int {
        if task.isPending(at: now) { return 0 }
        return task.status == .done ? 2 : 1
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !model.isReady {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let tasks = visibleTasks
            if tasks.isEmpty {
                emptyState
            } else {
                taskList(tasks)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if model.ledger.tasks.isEmpty {
            ContentUnavailableView(
                "タスクがありません",
                systemImage: "checklist",
                description: Text("上の欄に店と品目を入れて追加します。例: ダイソー／フィルム")
            )
        } else {
            switch filter {
            case .pending:
                ContentUnavailableView(
                    "未完了のタスクはありません",
                    systemImage: "checkmark.circle",
                    description: Text("完了・無視したタスクは「完了」「無視」「すべて」で見られます。")
                )
            case .ignored:
                ContentUnavailableView(
                    "無視中のタスクはありません",
                    systemImage: "bell.slash",
                    description: Text("「無視」したタスクは、ここから未完了に戻せます。")
                )
            case .done:
                ContentUnavailableView(
                    "完了したタスクはありません",
                    systemImage: "checkmark.circle",
                    description: Text("完了したタスクは、ここから未完了に戻せます。")
                )
            case .all:
                ContentUnavailableView("タスクがありません", systemImage: "checklist")
            }
        }
    }

    private func taskList(_ tasks: [TodoTask]) -> some View {
        let now = Date()
        let registered = Set(model.ledger.registeredChains.map { ChainName.key($0) })
        return List(selection: $selection) {
            ForEach(groups(of: tasks, now: now)) { group in
                Section {
                    ForEach(group.tasks) { task in
                        row(task, now: now)
                    }
                } header: {
                    groupHeader(group, isRegistered: registered.contains(group.id))
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .scrollDismissesKeyboard(.interactively)
    }

    private func groupHeader(_ group: StoreGroup, isRegistered: Bool) -> some View {
        HStack(spacing: 6) {
            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
            if !isRegistered {
                // 店登録がまだ（取り込み直後・登録中・検索に失敗など）。支店が無いので通知の対象にならない。
                Text("未登録")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(.systemGray5), in: Capsule())
            }
            Spacer(minLength: 0)
            Text("\(group.tasks.count)")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .textCase(nil)
    }

    // MARK: 行

    private func row(_ task: TodoTask, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !isEditing {
                statusMark(task, now: now)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.item)
                    .strikethrough(task.status == .done)
                    .font(.body)
                    .foregroundStyle(task.status == .done ? Color.secondary : Color.primary)
                if let detail = detailText(task, now: now) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            leadingActions(task, now: now)
        }
        // 末端の操作が削除だけの行（完了済み）で、全スワイプが即削除にならないようにする。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            trailingActions(task, now: now)
        }
        .contextMenu {
            menuActions(task, now: now)
        }
    }

    /// 行頭の印。未完了は押して完了、完了は押して戻す。無視中は状態を示すだけ（戻すのはスワイプかメニュー）。
    @ViewBuilder
    private func statusMark(_ task: TodoTask, now: Date) -> some View {
        if task.isPending(at: now) {
            Button {
                model.complete([task.id])
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("完了にする")
        } else if task.status == .done {
            Button {
                model.reopen([task.id])
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("未完了に戻す")
        } else {
            Image(systemName: "bell.slash")
                .font(.title3)
                .foregroundStyle(Color.secondary)
                .accessibilityLabel("無視中")
        }
    }

    @ViewBuilder
    private func leadingActions(_ task: TodoTask, now: Date) -> some View {
        if task.status == .done {
            reopenButton(task)
        } else {
            completeButton(task)
        }
    }

    @ViewBuilder
    private func trailingActions(_ task: TodoTask, now: Date) -> some View {
        if task.isPending(at: now) {
            ignoreButton(task)
        } else if task.status == .ignored {
            reopenButton(task)
        }
        deleteButton(task)
    }

    @ViewBuilder
    private func menuActions(_ task: TodoTask, now: Date) -> some View {
        if task.status != .done {
            completeButton(task)
        }
        if task.isPending(at: now) {
            ignoreButton(task)
        }
        if !task.isPending(at: now) {
            reopenButton(task)
        }
        deleteButton(task)
    }

    private func completeButton(_ task: TodoTask) -> some View {
        Button {
            model.complete([task.id])
        } label: {
            Label("完了", systemImage: "checkmark")
        }
        .tint(Color(.darkGray))
    }

    private func ignoreButton(_ task: TodoTask) -> some View {
        Button {
            // 台帳画面の「無視」は戻すまで無期限（通知ボタンの「今日は無視」とは別。D2）。
            model.ignore([task.id], untilTomorrow: false)
        } label: {
            Label("無視", systemImage: "bell.slash")
        }
        .tint(Color(.systemGray))
    }

    private func reopenButton(_ task: TodoTask) -> some View {
        Button {
            model.reopen([task.id])
        } label: {
            Label("戻す", systemImage: "arrow.uturn.backward")
        }
        .tint(Color(.systemGray))
    }

    private func deleteButton(_ task: TodoTask) -> some View {
        Button {
            model.delete([task.id])
        } label: {
            Label("削除", systemImage: "trash")
        }
        .tint(Color(.darkGray))
    }

    private func detailText(_ task: TodoTask, now: Date) -> String? {
        var parts: [String] = []
        switch task.status {
        case .pending:
            break
        case .ignored:
            if !task.isPending(at: now) {
                parts.append(task.ignoredUntil != nil ? "今日は無視" : "無視中")
            }
        case .done:
            if let completedAt = task.completedAt {
                parts.append("完了 \(Self.monthDay.string(from: completedAt))")
            }
        }
        if task.source != TodoTask.manualSource {
            parts.append(task.source)
        }
        if let day = task.sourceDate {
            let text = "\(day.month)/\(day.day)"
            parts.append(task.source == TodoTask.manualSource ? "出典日 \(text)" : text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    // MARK: 絞り込みの帯

    private var filterPicker: some View {
        Picker("表示", selection: $filter) {
            ForEach(LedgerFilter.allCases) { option in
                Text("\(option.label) \(count(for: option))").tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: 追加

    private var trimmedStore: String { storeText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedItem: String { itemText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !trimmedStore.isEmpty && !trimmedItem.isEmpty && !isAdding }

    /// 店欄の候補: 登録済みのチェーンと、タスクで使っている店のうち、入力中の文字を含むもの。
    private var suggestions: [String] {
        let typed = ChainName.key(storeText)
        let names = model.knownStoreNames.filter { name in
            let key = ChainName.key(name)
            return key != typed && (typed.isEmpty || key.contains(typed))
        }
        return Array(names.prefix(10))
    }

    /// 入力した店がまだどこにも無い（新しいチェーン）か。追加すると店登録が裏で始まる（D11）。
    private var isNewStore: Bool {
        let key = ChainName.key(storeText)
        guard !key.isEmpty else { return false }
        return !model.knownStoreNames.contains { ChainName.key($0) == key }
    }

    private var addArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("店", text: $storeText)
                        .focused($focus, equals: .store)
                        .submitLabel(.next)
                        .autocorrectionDisabled()
                        .onSubmit { focus = .item }
                        .frame(maxWidth: 140)
                    Divider()
                        .frame(height: 20)
                    TextField("品目", text: $itemText)
                        .focused($focus, equals: .item)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))

                Button("追加") { submit() }
                    .buttonStyle(.bordered)
                    .disabled(!canAdd)
            }

            if focus == .store, !suggestions.isEmpty {
                suggestionChips
            }
            if let feedback {
                Text(feedback.text)
                    .font(.footnote)
                    .foregroundStyle(feedback == .duplicate || isFailure(feedback) ? Color.primary : Color.secondary)
            }
            if isNewStore {
                Text(model.placesConfigured
                    ? "新しい店です。追加すると、登録済みの駅の近くの支店を自動で探します。"
                    : PermissionCopy.placesKeyMissing)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: storeText) { _, _ in feedback = nil }
        .onChange(of: itemText) { _, text in
            // 追加直後に品目欄を空にする変更では、いま出した結果を消さない。
            if !text.isEmpty { feedback = nil }
        }
    }

    private func isFailure(_ feedback: AddFeedback) -> Bool {
        if case .failed = feedback { return true }
        return false
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { name in
                    Button {
                        storeText = name
                        focus = .item
                    } label: {
                        Text(name)
                            .font(.footnote)
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func submit() {
        let store = trimmedStore
        let item = trimmedItem
        guard !store.isEmpty, !item.isEmpty, !isAdding else { return }
        isAdding = true
        Task { @MainActor in
            let result = await model.addTask(store: store, item: item)
            isAdding = false
            switch result {
            case .added:
                // 店は残す（同じ店で続けて入れる）。品目だけ空にして、続けて入力できるようにする。
                itemText = ""
                feedback = .added(store: store, item: item)
                focus = .item
                // 初めてタスクを書いたこのとき、通知の許可を聞く（聞く場所が他に無い）。
                if model.notificationStatus == .notDetermined {
                    await model.requestNotificationAuthorization()
                }
            case .duplicate:
                feedback = .duplicate
            case .invalid(let message):
                feedback = .failed(message)
            }
        }
    }

    // MARK: 通知が鳴らない原因の案内

    private var notices: [LedgerNotice] {
        guard model.isReady, model.ledgerError == nil else { return [] }
        var list: [LedgerNotice] = []
        if model.ledger.stations.isEmpty {
            list.append(LedgerNotice(
                id: "stations",
                icon: "tram.fill",
                text: "駅が未登録です。「駅」タブで使う駅を追加すると通知されます。"
            ))
        } else if !model.locationAuthorization.isAlways {
            let needsPrompt = model.locationAuthorization == .notDetermined
            list.append(LedgerNotice(
                id: "location",
                icon: "location",
                text: "位置情報: \(model.locationAuthorization.label)。\(PermissionCopy.locationAlwaysRequired)",
                actionTitle: needsPrompt ? "許可する" : "設定を開く",
                action: {
                    if needsPrompt {
                        model.requestLocationAuthorization()
                    } else {
                        model.openSystemSettings()
                    }
                }
            ))
        }
        if model.notificationStatus == .denied {
            list.append(LedgerNotice(
                id: "notification",
                icon: "bell.slash",
                text: PermissionCopy.notificationDenied,
                actionTitle: "設定を開く",
                action: { model.openSystemSettings() }
            ))
        }
        return list
    }

    @ViewBuilder
    private var noticeBar: some View {
        let items = isEditing ? [] : notices
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
                        Spacer(minLength: 8)
                        if let title = notice.actionTitle, let action = notice.action {
                            Button(title, action: action)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
        }
    }

    // MARK: ツールバーと一括操作

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 中身を条件にした空の ToolbarItem は空のバー項目として残り得るので、項目ごと条件にする。
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "選択解除" : "すべて選択") {
                    toggleSelectAll()
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(isEditing ? "終了" : "選択") {
                editMode = isEditing ? .inactive : .active
            }
            .disabled(!isEditing && visibleTasks.isEmpty)
        }
        if isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("完了") { bulkComplete() }
                    .disabled(!selectedTasks.contains { $0.status != .done })
                Spacer()
                Button("無視") { bulkIgnore() }
                    .disabled(!selectedTasks.contains { $0.status != .done })
                if filter != .pending {
                    Spacer()
                    Button("戻す") { bulkReopen() }
                        .disabled(!selectedTasks.contains { $0.status != .pending })
                }
                Spacer()
                Button("削除") { confirmDelete = true }
                    .disabled(selectedTasks.isEmpty)
            }
        }
    }

    private var allVisibleSelected: Bool {
        let tasks = visibleTasks
        return !tasks.isEmpty && tasks.allSatisfy { selection.contains($0.id) }
    }

    private func toggleSelectAll() {
        if allVisibleSelected {
            selection.removeAll()
        } else {
            selection = Set(visibleTasks.map(\.id))
        }
    }

    private func finishEditing() {
        selection.removeAll()
        editMode = .inactive
    }

    private func bulkComplete() {
        let ids = selectedTasks.filter { $0.status != .done }.map(\.id)
        if !ids.isEmpty { model.complete(ids) }
        finishEditing()
    }

    private func bulkIgnore() {
        let ids = selectedTasks.filter { $0.status != .done }.map(\.id)
        if !ids.isEmpty { model.ignore(ids, untilTomorrow: false) }
        finishEditing()
    }

    private func bulkReopen() {
        let ids = selectedTasks.filter { $0.status != .pending }.map(\.id)
        if !ids.isEmpty { model.reopen(ids) }
        finishEditing()
    }

    private func bulkDelete() {
        let ids = selectedTasks.map(\.id)
        if !ids.isEmpty { model.delete(ids) }
        finishEditing()
    }
}
