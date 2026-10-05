import XCTest

// MARK: - UI テストの土台
//
// 実機・Simulator でアプリを実際に起動して触るスモークテスト用の共通部品（CI の macOS ジョブで走る。ローカルでは未検証）。
// 方針:
//  - ラベルは見えている日本語で探す（RootView / LedgerView / SettingsView / StationsView / HistoryView の実コードに合わせた）。
//  - 待ちは必ず有限のタイムアウト。CI の Simulator は初回起動が遅いので、起動は長め、画面内の待ちは中くらい。
//  - 状態の持ち越し（台帳は端末に残る）を前提に、品目名はテストごとに一意にする（アプリ側にリセット口は無い）。
//  - `setUp` を override しない。XCTestCase の actor 隔離の宣言が SDK ごとに違っても通るよう、
//    クラス全体を @MainActor にして、各テストが最初に `launchApp()` を呼ぶ。

/// 権限ダイアログの「許可する側」のボタンを押す。押したら true。
/// 通知: 「許可」/ Allow。位置情報: 「Appの使用中は許可」/ Allow While Using App、なければ「1回のみ許可」/ Allow Once。
/// 「許可しない」/ Don't Allow は絶対に押さない（完全一致と部分一致の選び方でそうなっている）。
@MainActor
func tapAllowButton(in alert: XCUIElement) -> Bool {
    let candidates: [NSPredicate] = [
        NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "使用中", "While Using"),
        NSPredicate(format: "label == %@ OR label == %@", "許可", "Allow"),
        NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "1回のみ", "Allow Once"),
    ]
    for predicate in candidates {
        let button = alert.buttons.matching(predicate).firstMatch
        if button.exists {
            button.tap()
            return true
        }
    }
    return false
}

@MainActor
class EkiUITestCase: XCTestCase {
    /// 起動直後にタブが出るまで。CI の初回起動（Simulator が温まっていない）を見込んで長い。
    static let launchTimeout: TimeInterval = 120
    /// 画面内の要素を待つ時間。
    static let uiTimeout: TimeInterval = 25
    /// 台帳の保存・再描画のように「すぐのはず」の変化を待つ時間。
    static let settleTimeout: TimeInterval = 12

    static let tabTitles = ["台帳", "駅", "店", "履歴", "設定"]

    var app: XCUIApplication!
    private var screenshotIndex = 0
    private var monitorToken: NSObjectProtocol?

    /// この実行の中で一意な品目名の接尾辞（月日時分秒）。前回までの台帳の中身と重ならないようにする。
    static let runTag: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMddHHmmss"
        return formatter.string(from: Date())
    }()

    func uniqueItem(_ base: String) -> String {
        "\(base)\(Self.runTag)"
    }

    // MARK: 起動

    /// アプリを（再）起動する。日本語ロケールで起動し、権限ダイアログの監視を仕掛け、タブが出るまで待つ。
    func launchApp(file: StaticString = #filePath, line: UInt = #line) {
        continueAfterFailure = false
        if app == nil {
            app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            installPermissionMonitors()
            installFailureDiagnostics()
        }
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        // 監視は「ダイアログで操作が遮られたとき」に呼ばれる。起動直後に一度アプリを触って呼び水にする
        //（XCTest のドキュメントの要求。台帳の中央を 1 回タップするだけで、何も起きない）。
        app.tap()

        let ledgerTab = app.tabBars.buttons["台帳"]
        XCTAssertTrue(
            ledgerTab.waitForExistence(timeout: Self.launchTimeout),
            "起動後 \(Int(Self.launchTimeout)) 秒以内にタブバー（台帳）が出ませんでした。state=\(app.state.rawValue)",
            file: file, line: line
        )
        XCTAssertEqual(app.state, .runningForeground, "アプリが前面で動いていません", file: file, line: line)
    }

    /// 強制終了して起動し直す（台帳が保存されているかの確認用）。
    func relaunchApp(file: StaticString = #filePath, line: UInt = #line) {
        app.terminate()
        launchApp(file: file, line: line)
    }

    private func installPermissionMonitors() {
        // 通知・位置情報の許可ダイアログは SpringBoard が出す。
        monitorToken = addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            tapAllowButton(in: alert)
        }
    }

    /// 失敗したテストの最後の画面と、アプリの要素ツリーを添付する（ラベルの食い違いを CI のログだけで直せるように）。
    private func installFailureDiagnostics() {
        addTeardownBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let app = self.app, self.testRun?.hasSucceeded == false else { return }
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "failure-final-screen"
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "failure-ui-hierarchy"
                tree.lifetime = .keepAlways
                self.add(tree)
            }
        }
    }

    /// SpringBoard 側の許可ダイアログを直接探して許可する（監視に頼らない保険）。何か押したら true。
    @discardableResult
    func acceptSystemAlertsIfPresent(waitingUpTo timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return false }
        var handled = false
        // 通知 → 位置情報のように続けて出ることがあるので数回見る。
        for _ in 0..<3 {
            guard alert.exists, tapAllowButton(in: alert) else { break }
            handled = true
            _ = waitUntil(timeout: 5) { !alert.exists }
        }
        return handled
    }

    // MARK: 待つ

    /// 条件が成り立つまで 0.25 秒ごとに確認する（タイムアウトは有限）。
    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// timeout を省くと `settleTimeout`。
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        waitUntil(timeout: timeout ?? Self.settleTimeout) { !element.exists }
    }

    // MARK: スクリーンショット

    /// 画面全体を撮って、名前付きで必ず残す（成功したテストの分も）。名前の頭に通し番号を付けて並びを保つ。
    func snap(_ name: String) {
        screenshotIndex += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", screenshotIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: タブ

    func tabButton(_ title: String) -> XCUIElement {
        app.tabBars.buttons[title]
    }

    /// タブを開いて、その画面のナビゲーションバーが出るまで待つ。
    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        dismissKeyboardIfPresent()
        let tab = tabButton(title)
        XCTAssertTrue(tab.waitForExistence(timeout: Self.uiTimeout), "タブ「\(title)」が見つかりません", file: file, line: line)
        // キーボードや別の面に隠れていないか（隠れたまま押すと別のキーを打ってしまう）。
        XCTAssertTrue(waitUntil(timeout: Self.settleTimeout) { tab.isHittable }, "タブ「\(title)」が押せる状態になりません", file: file, line: line)
        tab.tap()
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: Self.uiTimeout),
            "タブ「\(title)」を開いたのにナビゲーションバー「\(title)」が出ません",
            file: file, line: line
        )
    }

    // MARK: キーボード

    var keyboardVisible: Bool { app.keyboards.count > 0 }

    /// 初回のキーボード紹介（「続ける」など）が出ていたら閉じる。
    private func dismissKeyboardTip() {
        for title in ["続ける", "Continue"] {
            let button = app.keyboards.buttons[title]
            if button.exists, button.isHittable { button.tap() }
        }
    }

    /// キーボードが出ていたら閉じる。
    /// 品目欄の Return は onSubmit で追加を試みる。品目が空なら何も追加せずに欄が閉じるだけで、
    /// 中身が残っているとき（重複で追加できなかった直後）は同じ重複の案内がもう一度出るだけで害はない。
    func dismissKeyboardIfPresent() {
        guard keyboardVisible else { return }
        let item = app.textFields["品目"]
        if item.exists {
            item.typeText("\n")
        }
        if waitUntil(timeout: 4, { !keyboardVisible }) { return }
        // 保険: Return キーを直接押す（ラベルは言語や returnKeyType で変わる）。
        for title in ["Return", "return", "完了", "Done", "改行", "確定"] {
            let key = app.keyboards.buttons[title]
            if key.exists {
                key.tap()
                if waitUntil(timeout: 3, { !keyboardVisible }) { return }
            }
        }
    }

    /// 欄をタップして文字を打つ。打った結果が欄の値と一致することまで確かめる（日本語入力の取りこぼしを早く見つけるため）。
    func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: Self.uiTimeout), "入力欄が見つかりません（\(text)）", file: file, line: line)
        field.tap()
        dismissKeyboardTip()
        field.typeText(text)
        let typed = waitUntil(timeout: 5) { (field.value as? String) == text }
        XCTAssertTrue(
            typed,
            "「\(text)」を打ったが欄の値は「\((field.value as? String) ?? "nil")」でした（日本語の入力が通っていない可能性）",
            file: file, line: line
        )
    }

    // MARK: 要素の探索

    /// 種類を問わず、ラベルが一致する要素（最初の 1 つ）。
    func element(labelEquals label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func element(labelBeginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
}
