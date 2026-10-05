import CoreLocation
import EkiCore
import MapKit
import SwiftUI

// MARK: - 駅 画面（コンテンツ設計書 §3）
//
// 登録駅の一覧と、選んだ駅の地図（半径の円）。駅の追加・半径の変更・有効／無効・削除をここで行う。
// 台帳の読み書きはすべて AppModel の操作口を通す。色は無彩色のみ（地図もグレースケールに落とす）。
// 破壊的操作に `role: .destructive` を使わない（システムが赤にするため）。確認ダイアログで代える。

/// 半径スライダーの範囲（計画書 §5: 初期値 300 m。M1 の実測で決める）。
private enum StationRadiusSlider {
    static let range: ClosedRange<Double> = 100...1000
    static let step: Double = 50
}

/// 同じ名前でこの距離（m）以内の駅は「登録済み」とみなす。AppModel.addStation の重複判定と同じ値。
private let stationDuplicateMeters: Double = 300

private func stationMapCoordinate(_ c: Coordinate) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
}

struct StationsView: View {
    @Environment(AppModel.self) private var model

    @State private var selectedID: UUID?
    @State private var position: MapCameraPosition = .automatic
    /// スライダーを動かしている間の値。指を離したときに台帳へ書く（円はこの値でライブに動く）。
    @State private var draftRadius: Double?
    @State private var showAddSheet = false
    @State private var stationToDelete: Station?

    private var stations: [Station] { model.ledger.stations }

    /// 選択中の駅。未選択・選択した駅が消えたときは先頭。
    private var selectedStation: Station? {
        stations.first { $0.id == selectedID } ?? stations.first
    }

    private var canAdd: Bool { model.isReady && model.ledgerError == nil }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("駅")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("駅を追加", systemImage: "plus")
                        }
                        .disabled(!canAdd)
                    }
                }
                .sheet(isPresented: $showAddSheet) {
                    AddStationSheet()
                }
                .confirmationDialog(
                    stationToDelete.map { "\($0.name) を削除しますか？" } ?? "駅を削除しますか？",
                    isPresented: Binding(
                        get: { stationToDelete != nil },
                        set: { presented in
                            if !presented { stationToDelete = nil }
                        }
                    ),
                    titleVisibility: .visible,
                    presenting: stationToDelete
                ) { station in
                    Button("削除") { model.removeStation(station.id) }
                    Button("キャンセル", role: .cancel) {}
                } message: { _ in
                    Text("この駅の近くの支店の記録も外れます。通知の履歴は残ります。")
                }
                .onAppear { recenter() }
                .onChange(of: selectedStation?.id) { _, _ in
                    draftRadius = nil
                    recenter()
                }
                // 半径が確定（台帳に反映）したら、下書きを捨てて円が収まるように寄せる。
                .onChange(of: selectedStation?.radiusMeters) { _, _ in
                    draftRadius = nil
                    recenter()
                }
                // 保存に失敗したときは alert が出る。スライダーを台帳の値に戻す。
                .onChange(of: model.alert?.id) { _, _ in
                    draftRadius = nil
                }
                // 駅が 1 件増えたら、その駅を選ぶ（追加した駅の円をすぐ確認できる）。
                .onChange(of: stations.map(\.id)) { old, new in
                    let added = new.filter { !old.contains($0) }
                    if !old.isEmpty, added.count == 1, let id = added.first {
                        selectedID = id
                    }
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
        } else if stations.isEmpty {
            ContentUnavailableView {
                Label("駅がありません", systemImage: "tram.fill")
            } description: {
                Text("使う駅を追加すると、その駅に入った瞬間に、近くの開いている店のタスクを通知します。")
            } actions: {
                Button("駅を追加") { showAddSheet = true }
                    .buttonStyle(.bordered)
            }
        } else {
            VStack(spacing: 0) {
                statusBar
                if let station = selectedStation {
                    mapPanel(station)
                }
                stationList
            }
        }
    }

    // MARK: 監視の状態

    private var monitoringNote: String? {
        let ledger = model.ledger
        let enabled = ledger.stations.filter(\.isEnabled)
        let plan = model.monitoringPlan
        if enabled.isEmpty { return "有効な駅がないため、監視していません。" }
        if plan.isMonitoring {
            if enabled.count > Tuning.regionMonitoringCap {
                return "有効な駅が \(Tuning.regionMonitoringCap) を超えているため、いまいる場所に近い \(Tuning.regionMonitoringCap) 駅だけ監視します。"
            }
            return nil
        }
        // D13: 未完了（または今日だけ無視）のタスクがあるか、実測モードのときだけ監視する。
        let wanted = ledger.settings.diagnosticMode
            || ledger.tasks.contains { $0.status == .pending || ($0.status == .ignored && $0.ignoredUntil != nil) }
        if !wanted { return "未完了のタスクがないため、監視を止めています（電池のため）。" }
        return nil
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.secondary)
                Text("監視中 \(model.monitoringPlan.stations.count) / \(Tuning.regionMonitoringCap)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            if let note = monitoringNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.locationAuthorization.isAlways {
                locationNotice
            }
            if let report = model.lastReport {
                Text(report)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
    }

    /// 領域監視がバックグラウンドで効くのは「常に」だけ。許可の取り方は状態で変える。
    private var locationNotice: some View {
        let authorization = model.locationAuthorization
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "location")
                .foregroundStyle(Color.secondary)
            Text("位置情報: \(authorization.label)。\(PermissionCopy.locationAlwaysRequired)")
                .font(.footnote)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if authorization == .notDetermined || authorization == .whenInUse {
                Button("許可する") { model.requestLocationAuthorization() }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            // 「使用中のみ」からの引き上げ確認は iOS が 1 回しか出さないので、設定アプリへの道も残す。
            if authorization != .notDetermined {
                Button("設定を開く") { model.openSystemSettings() }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: 地図と半径

    private func displayedRadius(_ station: Station) -> Double {
        draftRadius ?? station.radiusMeters
    }

    private func mapPanel(_ station: Station) -> some View {
        let radius = displayedRadius(station)
        return VStack(spacing: 0) {
            Map(position: $position) {
                ForEach(stations) { s in
                    Marker(s.name, coordinate: stationMapCoordinate(s.coordinate))
                        .tint(s.id == station.id ? Color.primary : Color.secondary)
                }
                MapCircle(center: stationMapCoordinate(station.coordinate), radius: radius)
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .stroke(Color.primary, lineWidth: 2)
            }
            // 地図の色を落として、画面全体を無彩色にそろえる。
            .grayscale(1)
            .frame(height: 220)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(station.name)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("半径 \(Int(radius.rounded())) m")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                    Button {
                        stationToDelete = station
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Color.secondary)
                    }
                    .accessibilityLabel("\(station.name)を削除")
                }
                Slider(
                    value: Binding(
                        get: { min(max(displayedRadius(station), StationRadiusSlider.range.lowerBound), StationRadiusSlider.range.upperBound) },
                        set: { draftRadius = $0 }
                    ),
                    in: StationRadiusSlider.range,
                    step: StationRadiusSlider.step,
                    onEditingChanged: { editing in
                        if !editing { commitRadius(station) }
                    }
                )
                .tint(Color.primary)
                .accessibilityLabel("\(station.name)の半径")
                HStack {
                    Text("\(Int(StationRadiusSlider.range.lowerBound)) m")
                    Spacer()
                    Text("\(Int(StationRadiusSlider.range.upperBound)) m")
                }
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 指を離したとき、下書きの半径を台帳へ書く。台帳の値が返ってきたら onChange が下書きを捨てる。
    private func commitRadius(_ station: Station) {
        guard let draft = draftRadius else { return }
        if abs(draft - station.radiusMeters) < 0.5 {
            draftRadius = nil
            return
        }
        model.setStationRadius(station.id, meters: draft)
    }

    /// 選択中の駅の円が収まる範囲へ地図を寄せる。
    private func recenter() {
        guard let station = selectedStation else {
            position = .automatic
            return
        }
        let span = max(station.radiusMeters * 4, 600)
        let region = MKCoordinateRegion(
            center: stationMapCoordinate(station.coordinate),
            latitudinalMeters: span,
            longitudinalMeters: span
        )
        withAnimation {
            position = .region(region)
        }
    }

    // MARK: 一覧

    private var stationList: some View {
        List {
            Section {
                ForEach(stations) { station in
                    row(station)
                }
            } header: {
                Text("登録駅 \(stations.count)")
            }
        }
        .listStyle(.plain)
    }

    private func subtitle(_ station: Station) -> String {
        var parts = ["半径 \(Int(station.radiusMeters.rounded())) m"]
        if !model.ledger.registeredChains.isEmpty {
            let count = model.ledger.branches.filter { $0.distance(to: station.id) != nil }.count
            parts.append("支店 \(count) 件")
        }
        if !station.isEnabled {
            parts.append("無効")
        } else if model.monitoringPlan.stations.contains(where: { $0.id == station.id }) {
            parts.append("監視中")
        } else {
            parts.append("監視していません")
        }
        return parts.joined(separator: "・")
    }

    private func row(_ station: Station) -> some View {
        let isSelected = station.id == selectedStation?.id
        let background: Color? = isSelected ? Color(.systemGray5) : nil
        return HStack(spacing: 12) {
            Button {
                selectedID = station.id
            } label: {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(station.isEnabled ? Color.primary : Color.secondary)
                        Text(subtitle(station))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Toggle(
                "\(station.name)を有効にする",
                isOn: Binding(
                    get: { station.isEnabled },
                    set: { model.setStationEnabled(station.id, $0) }
                )
            )
            .labelsHidden()
            .tint(Color.primary)
        }
        .listRowBackground(background)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                stationToDelete = station
            } label: {
                Label("削除", systemImage: "trash")
            }
            .tint(Color(.darkGray))
        }
    }
}

// MARK: - 駅を追加するシート

/// 駅名を入れると MapKit の候補が出る。候補をタップするとその駅を登録して閉じる。
/// 登録のあとの支店探し（時間がかかる）は AppModel が裏で続け、画面上部のバナーが進行を出す。
private struct AddStationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct SearchKey: Equatable {
        var text: String
        var tick: Int
    }

    @State private var query = ""
    @State private var results: [StationCandidate] = []
    /// `results` がどの文字列の検索結果か（入力中は前の結果を見せ続けるため、入力とは別に持つ）。
    @State private var searchedText: String?
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// 「もう一度」用。値が変わると検索がやり直される。
    @State private var retryTick = 0
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    searchField
                } footer: {
                    Text("駅名の一部でも探せます。選ぶとその駅を登録します。")
                }
                resultsSection
            }
            .navigationTitle("駅を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
            // 入力のたびに走り、350 ms 手が止まってから検索する（前の検索は自動でキャンセルされる）。
            .task(id: SearchKey(text: trimmedQuery, tick: retryTick)) {
                await runSearch(SearchKey(text: trimmedQuery, tick: retryTick))
            }
            .onAppear { fieldFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
            TextField("駅名（例: 藤沢）", text: $query)
                .focused($fieldFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if isSearching {
                ProgressView()
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("入力を消す")
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let message = errorMessage {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("検索できませんでした")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                    Button("もう一度") { retryTick += 1 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } else if let searched = searchedText {
            if results.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("「\(searched)」の駅は見つかりませんでした")
                            .font(.subheadline)
                        Text("「駅」を付けずに、駅名だけで試してください。")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(results) { candidate in
                        resultRow(candidate)
                    }
                } header: {
                    Text("候補")
                }
            }
        }
    }

    private func isRegistered(_ candidate: StationCandidate) -> Bool {
        let key = ChainName.key(candidate.name)
        return model.ledger.stations.contains { station in
            ChainName.key(station.name) == key
                && station.coordinate.distance(to: candidate.coordinate) < stationDuplicateMeters
        }
    }

    private func resultRow(_ candidate: StationCandidate) -> some View {
        let registered = isRegistered(candidate)
        return Button {
            add(candidate)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .foregroundStyle(Color.primary)
                    if let subtitle = candidate.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                if registered {
                    Text("登録済み")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(registered)
    }

    /// 登録は AppModel に任せて、シートはすぐ閉じる（支店探しの待ちでシートを塞がない）。
    /// 失敗や重複は AppModel が alert にする。
    private func add(_ candidate: StationCandidate) {
        let model = self.model
        Task { @MainActor in
            await model.addStation(candidate)
        }
        dismiss()
    }

    private func runSearch(_ key: SearchKey) async {
        guard !key.text.isEmpty else {
            results = []
            searchedText = nil
            errorMessage = nil
            isSearching = false
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        isSearching = true
        errorMessage = nil
        do {
            let found = try await model.searchStations(key.text)
            if Task.isCancelled { return }
            results = found
            searchedText = key.text
            isSearching = false
        } catch {
            if Task.isCancelled { return }
            isSearching = false
            results = []
            searchedText = nil
            if error is URLError {
                errorMessage = "通信できませんでした。接続を確認して、もう一度お試しください。"
            } else {
                errorMessage = "しばらくしてから、もう一度お試しください。（\(error.localizedDescription)）"
            }
        }
    }
}
