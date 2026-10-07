import XCTest

// MARK: - スモークテスト（実際に Simulator で起動して触る）
//
// 各テストは独立（`launchApp()` から始まる）。台帳は端末に残るので、品目名は `uniqueItem` で一意にし、
// 既存データがあっても通るようにしてある（アプリには台帳のリセット口が無い。アプリ側の変更が要る点は README/報告に記載）。
// 権限ダイアログ（通知・位置情報）は EkiUITestCase の監視と SpringBoard の直接操作で「許可」側を押す。
// 外部通信（MKLocalSearch / Places）には依存しない。

final class EkiSmokeTests: EkiUITestCase {
    // MARK: (a) 起動とタブ

    func test01_launch_showsFiveTabs() {
        launchApp()
        for title in Self.tabTitles {
            XCTAssertTrue(
                tabButton(title).waitForExistence(timeout: Self.uiTimeout),
                "タブ「\(title)」が見つかりません"
            )
        }
        XCTAssertEqual(app.tabBars.buttons.count, Self.tabTitles.count, "タブの数が 5 ではありません")
        // 最初の画面は台帳。
        XCTAssertTrue(app.navigationBars["台帳"].waitForExistence(timeout: Self.uiTimeout), "起動直後の画面が台帳ではありません")
        snap("launch-ledger")
    }

    // MARK: (b) 全タブを巡って撮る

    func test02_everyTab_screenshots() {
        launchApp()
        let slugs = ["台帳": "ledger", "駅": "stations", "店": "shops", "履歴": "history", "設定": "settings"]
        for title in Self.tabTitles {
            openTab(title)
            pause(1.5) // 地図タイルや ContentUnavailableView の描画を待つ
            snap("tab-\(slugs[title] ?? title)")
        }
        // 1 周して台帳に戻れる（画面遷移で落ちない）。
        openTab("台帳")
        snap("tab-ledger-again")
    }

    // MARK: (c) 台帳: 追加 → 店ごとの束 → 重複 → 完了（スワイプ）

    func test03_ledger_add_group_duplicate_completeBySwipe() {
        let store = "ダイソー"
        let item = uniqueItem("フィルム")

        launchApp()
        openTab("台帳")
        snap("ledger-before-add")

        // 追加
        fillTask(store: store, item: item)
        snap("ledger-typed")
        submitTask()
        XCTAssertTrue(
            addedFeedback.waitForExistence(timeout: Self.uiTimeout),
            "「追加しました」の表示が出ません（追加できていない）"
        )
        acceptSystemAlertsIfPresent(waitingUpTo: 3) // 初回のタスク追加で通知の許可を聞かれる
        snap("ledger-added")

        // 店ごとの束の下に出る
        assertListed(item: item, underStore: store)

        // 同じものをもう一度 → 重複の案内
        type(item, into: itemField)
        submitTask()
        XCTAssertTrue(
            duplicateFeedback.waitForExistence(timeout: Self.uiTimeout),
            "重複の案内「同じ店・品目が未完了で既にあります」が出ません"
        )
        snap("ledger-duplicate")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", item)).count, 1, "重複したのに行が増えています")

        // スワイプで完了 → 未完了から消える
        dismissKeyboardIfPresent()
        completeBySwiping(item: item)
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts[item]), "完了にしたのに「未完了」の一覧から消えません")
        snap("ledger-completed-left-pending")

        // 完了の絞り込みに出る
        selectFilter("完了")
        XCTAssertTrue(app.staticTexts[item].waitForExistence(timeout: Self.uiTimeout), "「完了」の絞り込みに出ません")
        snap("ledger-done-filter")

        // 未完了に戻して見ても出ない
        selectFilter("未完了")
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts[item]), "未完了に戻して見たら完了済みの行がまた出ています")
    }

    // MARK: (c') 台帳: 複数選択で一括完了

    func test04_ledger_multiSelect_complete() {
        let store = "セリア"
        let item = uniqueItem("テープ")

        launchApp()
        openTab("台帳")
        fillTask(store: store, item: item)
        submitTask()
        XCTAssertTrue(addedFeedback.waitForExistence(timeout: Self.uiTimeout), "「追加しました」の表示が出ません")
        acceptSystemAlertsIfPresent(waitingUpTo: 3)
        XCTAssertTrue(app.staticTexts[item].waitForExistence(timeout: Self.uiTimeout), "追加した行が一覧に出ません")

        dismissKeyboardIfPresent()
        let selectButton = app.buttons["選択"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: Self.uiTimeout), "「選択」ボタンがありません")
        XCTAssertTrue(waitUntil(timeout: Self.settleTimeout) { selectButton.isEnabled })
        selectButton.tap()
        XCTAssertTrue(app.buttons["終了"].waitForExistence(timeout: Self.uiTimeout), "複数選択モードに入れません（「終了」が出ない）")
        snap("ledger-select-mode")

        let row = itemRow(item)
        XCTAssertTrue(row.waitForExistence(timeout: Self.uiTimeout))
        row.tap()
        XCTAssertTrue(
            app.navigationBars["1 件選択"].waitForExistence(timeout: Self.uiTimeout),
            "行を選んだのに「1 件選択」にならない"
        )
        snap("ledger-selected")

        // 下のバーの「完了」（絞り込みの「完了 N」とはラベルが違うので完全一致で探せる）
        let bulkComplete = app.buttons["完了"]
        XCTAssertTrue(bulkComplete.waitForExistence(timeout: Self.uiTimeout), "一括の「完了」ボタンがありません")
        XCTAssertTrue(waitUntil(timeout: Self.settleTimeout) { bulkComplete.isEnabled }, "一括の「完了」が押せる状態になりません")
        bulkComplete.tap()

        XCTAssertTrue(waitForDisappearance(of: app.staticTexts[item]), "一括完了したのに未完了の一覧から消えません")
        XCTAssertTrue(app.navigationBars["台帳"].waitForExistence(timeout: Self.uiTimeout), "一括完了のあと複数選択モードが終わりません")
        snap("ledger-bulk-completed")

        selectFilter("完了")
        XCTAssertTrue(app.staticTexts[item].waitForExistence(timeout: Self.uiTimeout), "一括完了した行が「完了」の絞り込みに出ません")
    }

    // MARK: (d) 設定: トグルと権限の行

    func test05_settings_toggles_stay_set_and_permission_rows() {
        launchApp()
        openTab("設定")
        snap("settings-initial")

        // 権限の行（位置情報 / 通知）
        XCTAssertTrue(
            rowExists(title: "位置情報", values: ["未設定", "拒否", "制限あり", "使用中のみ", "常に"]),
            "設定に「位置情報」の行（状態つき）がありません"
        )
        XCTAssertTrue(
            rowExists(title: "通知", values: ["未設定", "拒否", "許可", "許可（目立たない通知）", "一時的に許可"]),
            "設定に「通知」の行（状態つき）がありません"
        )

        let hours = settingsSwitch("営業時間をチェックする", fallbackIndex: 0)
        let diagnostic = settingsSwitch("実測モード", fallbackIndex: 1)
        let hoursBefore = value(of: hours)
        let diagnosticBefore = value(of: diagnostic)

        flip(hours, name: "営業時間をチェックする")
        flip(diagnostic, name: "実測モード")
        let hoursAfter = value(of: hours)
        let diagnosticAfter = value(of: diagnostic)
        XCTAssertNotEqual(hoursAfter, hoursBefore)
        XCTAssertNotEqual(diagnosticAfter, diagnosticBefore)
        if diagnosticAfter == "1" {
            XCTAssertTrue(
                element(labelBeginsWith: "実測モードがオンです").waitForExistence(timeout: Self.settleTimeout),
                "実測モードをオンにしたのに、説明の文言が変わらない"
            )
        }
        snap("settings-toggled")

        // 別のタブへ行って戻っても残っている
        openTab("台帳")
        openTab("設定")
        XCTAssertEqual(value(of: settingsSwitch("営業時間をチェックする", fallbackIndex: 0)), hoursAfter, "タブを往復したら営業時間チェックが戻った")
        XCTAssertEqual(value(of: settingsSwitch("実測モード", fallbackIndex: 1)), diagnosticAfter, "タブを往復したら実測モードが戻った")

        // 強制終了して起動し直しても残っている（設定が台帳に保存されている）
        relaunchApp()
        openTab("設定")
        XCTAssertEqual(value(of: settingsSwitch("営業時間をチェックする", fallbackIndex: 0)), hoursAfter, "再起動で営業時間チェックが戻った")
        XCTAssertEqual(value(of: settingsSwitch("実測モード", fallbackIndex: 1)), diagnosticAfter, "再起動で実測モードが戻った")
        snap("settings-after-relaunch")

        // 後始末: 他のテストに設定を持ち越さない（実測モードが残ると、ほかの確認が変わる）
        flip(settingsSwitch("営業時間をチェックする", fallbackIndex: 0), name: "営業時間をチェックする")
        flip(settingsSwitch("実測モード", fallbackIndex: 1), name: "実測モード")
        XCTAssertEqual(value(of: settingsSwitch("営業時間をチェックする", fallbackIndex: 0)), hoursBefore)
        XCTAssertEqual(value(of: settingsSwitch("実測モード", fallbackIndex: 1)), diagnosticBefore)
        snap("settings-restored")
    }

    // MARK: (e) 駅: 空の状態と「駅を追加」シート（検索結果には依存しない）

    func test06_stations_emptyState_and_addSheet() {
        launchApp()
        openTab("駅")
        // 駅は UI テストから追加できない（MKLocalSearch に頼らない）ので、駅の無い状態のはず。
        XCTAssertTrue(app.staticTexts["駅がありません"].waitForExistence(timeout: Self.uiTimeout), "空の状態「駅がありません」が出ません")
        snap("stations-empty")

        // ナビゲーションバーの「駅を追加」からシートを開く
        let navAdd = app.navigationBars["駅"].buttons["駅を追加"]
        XCTAssertTrue(navAdd.waitForExistence(timeout: Self.uiTimeout), "ナビゲーションバーに「駅を追加」がありません")
        XCTAssertTrue(waitUntil(timeout: Self.uiTimeout) { navAdd.isEnabled }, "「駅を追加」が有効になりません（台帳の読み込みが終わらない）")
        navAdd.tap()
        let sheetBar = app.navigationBars["駅を追加"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: Self.uiTimeout), "「駅を追加」のシートが開きません")
        XCTAssertTrue(app.textFields["駅名（例: 藤沢）"].waitForExistence(timeout: Self.uiTimeout), "シートに駅名の入力欄がありません")
        snap("stations-add-sheet")
        sheetBar.buttons["閉じる"].tap()
        XCTAssertTrue(waitForDisappearance(of: sheetBar), "「閉じる」を押してもシートが閉じません")
        XCTAssertTrue(app.staticTexts["駅がありません"].waitForExistence(timeout: Self.uiTimeout), "シートを閉じたら空の状態に戻るはず")

        // 空の状態の中の「駅を追加」ボタンからも開ける（ナビゲーションバーの同名ボタンと見分けるため、下にあるほうを使う）
        let addButtons = app.buttons.matching(NSPredicate(format: "label == %@", "駅を追加"))
        XCTAssertTrue(waitUntil(timeout: Self.uiTimeout) { addButtons.count >= 2 }, "空の状態の中に「駅を追加」ボタンがありません")
        addButtons.element(boundBy: addButtons.count - 1).tap()
        XCTAssertTrue(sheetBar.waitForExistence(timeout: Self.uiTimeout), "空の状態のボタンからシートが開きません")
        sheetBar.buttons["閉じる"].tap()
        XCTAssertTrue(waitForDisappearance(of: sheetBar), "2 回目も「閉じる」でシートが閉じません")
        snap("stations-after-sheet")
    }

    // MARK: (f) 履歴: 空の状態

    func test07_history_emptyState() {
        launchApp()
        openTab("履歴")
        let empty = app.staticTexts["履歴はまだありません"]
        if !empty.waitForExistence(timeout: Self.uiTimeout) {
            // 駅に入ることは CI では起きないので空のはずだが、履歴が残っている端末でも壊れていないことだけは見る。
            XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: Self.uiTimeout), "履歴が空でもなく、一覧も出ません")
        }
        snap("history-empty")
    }

    // MARK: (g) 台帳の永続化（強制終了 → 再起動）

    func test08_ledger_persists_across_relaunch() {
        let store = "ダイソー"
        let item = uniqueItem("電池")

        launchApp()
        openTab("台帳")
        fillTask(store: store, item: item)
        submitTask()
        XCTAssertTrue(addedFeedback.waitForExistence(timeout: Self.uiTimeout), "「追加しました」の表示が出ません")
        acceptSystemAlertsIfPresent(waitingUpTo: 3)
        XCTAssertTrue(app.staticTexts[item].waitForExistence(timeout: Self.uiTimeout), "追加した行が一覧に出ません")
        snap("persist-before-kill")

        // 強制終了 → 起動し直す。未完了のまま残っている。
        relaunchApp()
        XCTAssertTrue(
            app.staticTexts[item].waitForExistence(timeout: Self.uiTimeout + 20),
            "再起動したら追加したタスク「\(item)」が消えています（台帳が保存されていない）"
        )
        assertListed(item: item, underStore: store)
        snap("persist-after-relaunch-pending")

        // 完了にして、その状態も再起動で残る。
        let mark = itemRow(item).buttons["完了にする"]
        XCTAssertTrue(mark.waitForExistence(timeout: Self.uiTimeout), "行の「完了にする」ボタンがありません")
        mark.tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts[item]), "完了にしたのに未完了の一覧から消えません")

        relaunchApp()
        selectFilter("完了")
        XCTAssertTrue(
            app.staticTexts[item].waitForExistence(timeout: Self.uiTimeout + 20),
            "完了にしたタスクが再起動後に「完了」の絞り込みに出ません（状態が保存されていない）"
        )
        snap("persist-after-relaunch-done")
        selectFilter("未完了")
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts[item]), "完了済みのタスクが再起動後に未完了へ戻っている")
    }
}

// MARK: - 台帳・設定の操作部品

extension EkiSmokeTests {
    var storeField: XCUIElement { app.textFields["店"] }
    var itemField: XCUIElement { app.textFields["品目"] }
    var addButton: XCUIElement { app.buttons["追加"] }

    var addedFeedback: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "追加しました")).firstMatch
    }

    var duplicateFeedback: XCUIElement {
        app.staticTexts["同じ店・品目が未完了で既にあります"]
    }

    func pause(_ seconds: TimeInterval) {
        _ = waitUntil(timeout: seconds) { false }
    }

    /// 店と品目を欄に入れる。店は追加のあとも残るので、すでに入っていれば打ち直さない。
    func fillTask(store: String, item: String) {
        XCTAssertTrue(storeField.waitForExistence(timeout: Self.uiTimeout), "店の入力欄がありません")
        if (storeField.value as? String) != store {
            type(store, into: storeField)
        }
        type(item, into: itemField)
    }

    func submitTask() {
        XCTAssertTrue(addButton.waitForExistence(timeout: Self.uiTimeout), "「追加」ボタンがありません")
        XCTAssertTrue(waitUntil(timeout: Self.settleTimeout) { self.addButton.isEnabled }, "「追加」が押せる状態になりません")
        addButton.tap()
    }

    /// 品目の文字を持つ行（セル）。
    func itemRow(_ item: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@", item)).firstMatch
    }

    /// 品目が一覧にあり、その店の見出しより下にある（= 店ごとの束の中にいる）。
    func assertListed(item: String, underStore store: String, file: StaticString = #filePath, line: UInt = #line) {
        let itemText = app.staticTexts[item]
        XCTAssertTrue(itemText.waitForExistence(timeout: Self.uiTimeout), "品目「\(item)」が一覧に出ません", file: file, line: line)

        // 見出しは「店名」「店名 + 未登録 + 件数」のどちらの形で見えても拾えるよう、前方一致で探す。
        let prefix = NSPredicate(format: "label BEGINSWITH %@", store)
        var header = app.staticTexts.matching(prefix).firstMatch
        if !header.exists { header = app.otherElements.matching(prefix).firstMatch }
        XCTAssertTrue(header.waitForExistence(timeout: Self.uiTimeout), "店の見出し「\(store)」が一覧に出ません", file: file, line: line)

        if header.frame.height > 0, itemText.frame.height > 0 {
            XCTAssertLessThanOrEqual(
                header.frame.minY, itemText.frame.minY,
                "品目「\(item)」が店の見出し「\(store)」より上にあります（束になっていない）",
                file: file, line: line
            )
        }
    }

    /// 台帳の絞り込み（「未完了 3」のように件数がラベルに付くので前方一致）。
    func selectFilter(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: Self.uiTimeout), "絞り込み「\(title)」が見つかりません", file: file, line: line)
        segment.tap()
    }

    /// 行を右へスワイプして出る「完了」を押す。勢いで全スワイプになって勝手に完了した場合も許す。
    /// それでも行が残るなら、行頭の丸い「完了にする」ボタンで完了する（結果は呼び出し側が確かめる）。
    func completeBySwiping(item: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = itemRow(item)
        XCTAssertTrue(row.waitForExistence(timeout: Self.uiTimeout), "完了にする行「\(item)」がありません", file: file, line: line)
        row.swipeRight()
        let action = app.buttons["完了"]
        if action.waitForExistence(timeout: 3), action.isHittable {
            action.tap()
        }
        if !waitForDisappearance(of: app.staticTexts[item], timeout: 8) {
            let mark = itemRow(item).buttons["完了にする"]
            if mark.exists, mark.isHittable { mark.tap() }
        }
    }

    // MARK: 設定

    func settingsSwitch(_ title: String, fallbackIndex: Int) -> XCUIElement {
        let named = app.switches[title]
        if named.waitForExistence(timeout: Self.uiTimeout) { return named }
        return app.switches.element(boundBy: fallbackIndex)
    }

    func value(of toggle: XCUIElement) -> String {
        (toggle.value as? String) ?? ""
    }

    /// スイッチを 1 回切り替える。行の右端（UISwitch のある場所）を押し、変わらなければ中央を押す。
    func flip(_ toggle: XCUIElement, name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(toggle.waitForExistence(timeout: Self.uiTimeout), "スイッチ「\(name)」がありません", file: file, line: line)
        let before = value(of: toggle)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        // 値は ledger への保存と再描画を経て変わるので少し待つ。
        if waitUntil(timeout: 8, { self.value(of: toggle) != before }) { return }
        toggle.tap()
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.value(of: toggle) != before },
            "スイッチ「\(name)」を押しても値が変わりません（\(before)のまま）",
            file: file, line: line
        )
    }

    /// 設定の「title」の行（セル）があり、同じ行に状態の文言（values のどれか）が見えている。
    /// LabeledContent は「ラベルと値が別々の要素」でも「1 つにまとまって『位置情報, 未設定』」でも拾えるようにしてある。
    /// 「通知」は見出しにも、「未設定」は Places キーの行にも同じ文字があるので、必ず同じセルの中で組み合わせて見る。
    func rowExists(title: String, values: [String]) -> Bool {
        let titleExact = NSPredicate(format: "label == %@", title)
        let valueExact = NSPredicate(format: "label IN %@", values)
        let titlePrefixes = NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            "\(title),", "\(title)、", "\(title) "
        )
        let valueSuffixes = NSCompoundPredicate(orPredicateWithSubpredicates: values.map {
            NSPredicate(format: "label ENDSWITH %@", $0)
        })
        let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [titlePrefixes, valueSuffixes])
        // セルとして見えない場合の保険: 見出しと同じ文字の「通知」は 2 つ（見出し + 行）以上あることを求める。
        let minimumTitles = title == "通知" ? 2 : 1
        let present: () -> Bool = {
            self.app.cells.containing(titleExact).containing(valueExact).firstMatch.exists
                || self.app.cells.matching(combined).firstMatch.exists
                // CI の階層ダンプで確認した実際の形: セルは無名で、中の StaticText が「位置情報、未設定」と 1 本にまとまる。
                || self.app.staticTexts.matching(combined).firstMatch.exists
                || (self.app.staticTexts.matching(titleExact).count >= minimumTitles
                    && self.app.staticTexts.matching(valueExact).firstMatch.exists)
        }
        if waitUntil(timeout: 5, present) { return true }
        // 権限の行は設定画面の下の方にある。SwiftUI の List は画面外の行を作らないので、スクロールして探す。
        var scrolled = 0
        defer { for _ in 0..<scrolled { app.swipeDown() } }   // 上のスイッチを触る次の手順のために戻す
        for _ in 0..<8 {
            app.swipeUp()
            scrolled += 1
            if waitUntil(timeout: 2, present) { return true }
        }
        return false
    }
}
