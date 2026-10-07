# 駅通知todo

店名は決まっているが期限のない用事（「ダイソー: フィルム」）を、**自分が使う駅に入った瞬間、その店が開いている時間帯にだけ**通知する iOS アプリ。
人が触るのはタスクを書く一画面だけで、駅・店・営業時間の照合はアプリが裏で持つ。サーバ無し・ログイン無し・全部端末内（外に出るのは Google Places への問い合わせだけ）。

```
藤沢駅｜ダイソー 藤沢店（徒歩4分・21時まで）：フィルム、電池        [完了] [今日は無視]
```

設計は Dropbox の `Projects/駅通知todo/` にある 計画書_v0 と コンテンツ設計書_v0。このディレクトリはそれを実装したもの。
v0 が担うのは「通知レベル②（駅）× 探索レベル①（店名確定・無期限）」の1マスだけ。

## いまの状態（正直に）

| | 状態 |
| --- | --- |
| 判定・台帳・営業時間・取込・Places 応答の解釈（`EkiCore`） | **検証済み**。テスト 460 件超が Linux（Swift 6.0）と macOS の両方で通る。設計書の例文（上の通知文）の完全一致もテストで固定 |
| iOS 層（SwiftUI / CoreLocation / 通知 / MapKit / BGTask） | **Xcode 16・iOS 17 でコンパイルが通る**（CI、警告なし）。シミュレータ上の UI テストと各画面のスクリーンショットも CI で回す |
| 実機での領域監視・通知・バックグラウンド起動 | **未検証**。地下駅や通過時に発火するか、半径がどれくらいが適切かは、計画書 M1 の「1週間の実測」でしか分からない |
| 本物の Google Places API | **未検証**。リクエストとレスポンスの形は API 仕様どおりに作った（テストは仕様に沿った固定データ）が、実際のキーで一度も呼んでいない。最初の呼び出しで形の食い違いが出うる（出たら 店 タブの結果の1行とログに理由が出る） |
| App Store 配布 | 未着手（計画書 §3 の範囲外。配布時に中継サーバと審査用の理由文が要る） |

## 本人の手が要る作業（Claude Code では代替できない）

計画書 §3 の一覧に、このリポジトリでの具体的な手順を当てはめたもの。

- [ ] **Xcode を入れる**（App Store、10GB 超）。このアプリは Xcode 16 でビルドできることを CI で確認している
- [ ] **Apple Developer Program に登録**し、Xcode にそのアカウントでサインインする（無料の Personal Team でも実機に入るが、7日で失効する）
- [ ] **ブートストラップ**：Mac のターミナルで
  ```sh
  cd ekitsuuchi-todo
  scripts/bootstrap.sh        # xcodegen の導入、Config/Secrets.xcconfig の雛形、プロジェクト生成
  ```
- [ ] **`Config/Secrets.xcconfig` を編集**（git には入らない）
  - `DEVELOPMENT_TEAM` = 署名の Team ID（10桁）。ここに書くと `xcodegen generate` し直しても消えない
  - `PLACES_API_KEY` = Google の鍵。**M1 の間は空のままでよい**（M2 から要る）
- [ ] `open EkiTsuuchi.xcodeproj` → 実機を USB で繋ぎ「このコンピュータを信頼」→ Run
- [ ] 初回起動で位置情報と通知を許可する（下の M1 の手順）
- [ ] **M2 の前**：Google Cloud で課金アカウントを作り、**Places API (New)** を有効化して鍵を取る。鍵には必ず制限をかける（アプリケーション: iOS・バンドル ID `dev.denkingon.ekitsuuchi`、API: Places API (New) のみ）。鍵はアプリに同梱されるので、制限が実質の防御
- [ ] **M1 の1週間、普段どおり移動する**（テストデータはこれでしか取れない）

バンドル ID は `dev.denkingon.ekitsuuchi`（`project.yml`）。自分の Team で署名できない場合は、ここと `UIBackgroundModes` 用の `BGTaskSchedulerPermittedIdentifiers`（`dev.denkingon.ekitsuuchi.refresh`）を揃えて変える。

## 段階ごとの使い方（計画書 §3 の完了条件に対応）

### M1 駅→通知（鍵なし・タスクなしで回せる）
完了条件：実生活で1週間、使う駅すべてで発火し、発火位置と時刻がログに残る。ここで駅の半径を決める。

1. **駅** タブ →「駅を追加」→ 駅名で検索して追加する。初回に位置情報の許可ダイアログが出るので「Appの使用中は許可」。続けて iOS の設定アプリ > 駅通知todo > 位置情報 で **「常に」** と **「正確な位置情報」オン** に変える（アプリ内の 設定 タブにも状態と「設定を開く」がある）
2. **設定** タブ → **実測モード をオン**。通知の許可ダイアログが出るので許可する
   - 実測モードは「入域のたびに『藤沢駅に入った』とだけ通知し、位置と時刻を履歴に残す」モード。これを入れないと、タスクが0件のとき電池のため監視を止める（§4）ので、駅を登録しても何も起きない
3. **駅** タブの上に `監視中 N / 20` が出ていることを確認する
4. **登録した駅の中にいる状態では入域イベントは出ない**（iOS の仕様）。一度外に出て入り直す
5. 1週間、普段どおり移動する
6. **履歴** タブ：発火ごとに `M/d HH:mm 駅名 通知した（実測）` と `駅から Nm・精度 ±Nm`（半径内／半径外）が残る。「実測の集計」に駅ごとの発火回数・距離の中央値・最大が出る。これが半径を決める材料。**駅** タブの半径スライダ（100〜1000 m）で変える
   - 鳴らなかった日は、履歴に `通知に失敗`（通知の許可が無い等）が残っていないか見る。何も残っていなければ、そもそも入域を検知できていない（常に許可・正確な位置情報・駅の座標を確認。駅タブの「ピンを動かす」で座標を直せる）

### M2 店・営業時間
完了条件：店画面で「駅→支店→今日の営業時間」が見える。

`Config/Secrets.xcconfig` に `PLACES_API_KEY` を入れて再ビルド → **店** タブ →チェーン名（「ダイソー」）を追加。登録済みの各駅の半径 500 m で支店を探し、営業時間を取ってキャッシュする。
鍵が無い／Places が失敗したときは、店 タブの帯と結果の1行、ログに理由が出る。チェーンは登録されたまま残り、アプリを開くたびに（6時間おきに）支店ゼロのチェーンを自動で探し直す。

### M3 結合
完了条件：抑制理由（営業時間外／今日通知済）がログで確認できる。

**台帳** タブで「店」と「品目」を書く（未登録のチェーン名は自動で店登録される）。実測モードを切る。駅に入ると、駅入域×営業中（閉店まで30分以上）×今日未通知のときだけ通知が来る。**どの門で止まっても履歴に `抑制:理由` が1行残る**ので、鳴らなかった日は履歴を見れば原因が分かる。

通知の「完了」は、その通知に載っていた品目を**すべて**完了にする。「今日は無視」は翌日の0時まで止める（翌日に未完了へ戻る）。台帳画面の「無視」は戻すまで無期限。

### M4 入力口
完了条件：入力 JSON v1 のファイルで10件が入る。

**設定** タブ → 取込 → JSON ファイルを選ぶ（ファイルアプリ経由なので iCloud Drive の好きな場所でよい。Dropbox からは、ショートカットやスクリプトで iCloud Drive にコピーしておく）。

```json
{
  "version": 1,
  "items": [
    {"store": "ダイソー",   "item": "フィルム",         "source": "LINE:友人",  "date": "2026-09-14"},
    {"store": "無印良品",   "item": "ファイルボックス", "source": "Notion:HQ",  "date": "2026-09-20"}
  ]
}
```
同じ「店＋品目」が未完了（または無視）で既にあれば追加しない。不正な行はファイル全体を失敗させず、行ごとに理由を出して飛ばす。

## 構成

```
ekitsuuchi-todo/
  Package.swift            EkiCore（Swift Package。Apple 専用フレームワークに依存しない。Linux でテストできる）
  Sources/EkiCore/
    Model/                 台帳4つ・設定・判定の初期値（設計書 §2・§5）
    Ports/                 差し替え口5つ（店の検索／営業時間／タスクの流入／支店の属性／引き金）と通知・HTTP の口
    Hours/                 営業時間の評価（特別日・日またぎ・閉店までの余裕・支店のタイムゾーン）
    Ledger/ Import/        JSON 台帳（原子的保存・破損退避）、LedgerRepository、入力 JSON v1
    Places/                Google Places (New) の検索と営業時間の写し
    Judge/                 駅入域の4つの門、通知本文、領域監視の計画、入域ハンドラ
    Registration/          店登録（§4）と週1更新
  Tests/EkiCoreTests/      テスト（E2E 32 本を含む）
  App/                     iOS アプリ（SwiftUI）。XcodeGen が project.yml から Xcode プロジェクトを作る
    Platform/              CoreLocation・通知・BGTask・駅名検索・URLSession の実装（差し替え口の iOS 側）
    Model/                 AppEnvironment（起動直後の配線。位置情報起動では UI なしで動く）、AppModel
    Views/                 台帳・駅・店・履歴・設定（無彩色だけ）
  UITests/                 シミュレータ上の UI テスト
  Config/                  xcconfig（Secrets.xcconfig は git に入らない）
  scripts/bootstrap.sh
../.github/workflows/ekitsuuchi-ci.yml
```

## 設計書とコードの対応

| 設計書 | コード |
| --- | --- |
| §2 タスク／駅／支店／通知履歴 | `Model/TodoTask.swift` `Station.swift` `Branch.swift` `NotificationRecord.swift` |
| §2 入力 JSON と重複の扱い | `Import/TaskImporter.swift` `Ledger/TaskDedupe.swift` |
| §3 台帳／駅／店／履歴／設定 | `App/Views/LedgerView.swift` `StationsView.swift` `ShopsView.swift` `HistoryView.swift` `SettingsView.swift` |
| §3 通知本文と2つのボタン | `Judge/NotificationComposer.swift` `App/Platform/UserNotificationPoster.swift` `NotificationActionHandler.swift` |
| §4 店登録時／週1更新 | `Registration/ChainRegistrar.swift` `HoursRefresher.swift` `App/Platform/BackgroundRefresh.swift` |
| §4 駅入域時（4つの門と抑制） | `Judge/NotificationJudge.swift` `StationEntryHandler.swift`、領域監視は `MonitoringPlanner.swift` と `App/Platform/GeofenceTrigger.swift` |
| §5 差し替え口と初期値 | `Ports/Ports.swift` `Model/Tuning.swift` |

## 設計書から外れた点・決めた点

設計書が黙っている、または食い違っている所は次のとおりに決めた。変えたければ該当箇所だけ。

1. **「今日は無視」と状態「無視」**：通知のボタンは `状態=無視` + `翌日0時まで`（`TodoTask.ignoredUntil`）。台帳の「無視」は無期限。設計書の状態は3値のまま、欄を1つ足した
2. **通知の「完了」は通知に載った全品目を完了**（計画書 §4 の未決への既定）。`App/Model/AppEnvironment.swift` の `completeFromNotification` 1か所を変えれば1品目ずつ・店ごと一括にできる。台帳の「戻す」で取り消せる
3. **営業時間が分からない支店は営業中とみなす**（通知文は「営業時間不明」）。営業時間チェックを切ると門自体を通す
4. **履歴に発火位置を持たせた**（`NotificationRecord.location`）。M1 の完了条件「発火位置と時刻がログに残る」のため。駅名も履歴に持つので駅を消しても読める。発火のたびに新しい測位を1回取って残す（6秒で切り、取れなければキャッシュの位置、無ければ空）
5. **実測モード**（設定）：M1 用。入域のたびに駅名だけ通知し、ゲートなし。タスクが0件でも監視を続ける
6. **通知を出せなかったときは `通知に失敗` を履歴に残し、「今日通知済」に数えない**
7. **監視は「未完了がある」だけでなく「今日は無視の期限待ちがある」ときも続ける**（最後の1件に「今日は無視」を押して明日以降ずっと黙るのを防ぐ）
8. **チェーン名の突き合わせは全角/半角・大文字小文字・空白を畳む**（`ＤＡＩＳＯ` と `daiso` は同じ。ただし `ダイソー` と `daiso` は別のチェーン）。Places の結果は、店名にチェーン名を含み、駅から検索半径内のものだけ採る（別の店で通知しないため）
9. **入力ファイルはシステムのファイル選択で**（iCloud のコンテナは使わない）。iCloud の権限があると無料の Personal Team で実機に入らず、M0 が止まるため。使いたくなったら `project.yml` に iCloud の entitlement と `NSUbiquitousContainers` を足す
10. **通知頻度の選択肢**：駅ごとに1日1回（既定）／入域のたび／全駅で1日1回。**今日**は端末のタイムゾーン、営業時間は支店のタイムゾーンで見る
11. **「地図で微調整」**：駅タブで「ピンを動かす」→ 地図をタップした位置に動かす。動かすと、その駅の支店までの距離を取り直す

## 計画書 §4 の未決の問い（いま）

| 問い | いま |
| --- | --- |
| 使う駅は何駅か | 20を超えたら近い20駅に入れ替える仕組みは入っている（位置が大きく変わったら入れ替え）。M1 で実数が出る |
| 駅の半径は実測でどう出るか | 初期値 300 m。履歴の「実測の集計」で決める |
| 「完了」で同じ店の他の品目は | 上の 2 のとおり（通知に載った全品目）。変えやすくしてある |
| 品目に「どの支店で買えたか」を残すか | 残していない |
| タスクの正本はこのアプリで固定か | アプリで固定。Notion への要約は作っていない |
| 配布時の店検索の中継サーバ | 未着手。`StoreSearching` の裏を差し替える（Places の鍵が配布物から抜かれる問題はここで解く） |

## 既知の限界

- **すでに駅の中にいるときに監視を始めても入域は出ない**（iOS の仕様）。一度出て入り直す。駅を追加する画面にも書いてある
- 端末の再起動後、**最初のロック解除前**に入域で起動されると台帳を読めず、その入域は処理できない（ログにだけ残る）
- 「正確な位置情報」をオフにすると領域監視が不安定になりうる。駅画面に警告が出る
- Google の `currentOpeningHours`（特別営業日）は先の1週間ほどしか持たない。週1の更新と合わせても、再取得の間に入る臨時休業は拾えないことがある（公式サイトでの上書きは §6 の将来枠）
- 店の突き合わせは名前の部分一致。Places 側の表記が違う店（ローマ字表記など）は拾えず、`抑制:支店なし` になる
- iOS 26 SDK では MapKit の `placemark` が非推奨になる（警告のみ。動作はする）
- A（LINE・Notion の自動抽出）、在庫・規模調査、通知レベル①③④、探索レベル②は将来枠（設計書 §6）

## 開発

```sh
# Core（Mac なら Xcode のツールチェーンで、Linux なら Docker の swift:6.0 で）
cd ekitsuuchi-todo && swift test

# Xcode プロジェクトの生成（生成物は git に入れない）
xcodegen generate
```

CI（`.github/workflows/ekitsuuchi-ci.yml`）は push と PR で動く。

- **Core (Linux, swift test)**
- **Permission copy matches Info.plist**：位置情報の理由文を、審査用の `Info.plist`（`project.yml`）とアプリ内の表示（`App/Model/PermissionCopy.swift`）で一字一句そろえる（計画書 §2）
- **iOS app (macOS, xcodebuild + UI tests)**：iOS 層のコンパイル（警告は一覧に出る）、Core のテスト、シミュレータでの UI テスト。**各画面のスクリーンショットが `ui-screenshots` という成果物に入る**（Actions の実行ページの下の Artifacts）。Mac が手元になくても画面の様子を見られる

このディレクトリは GitHub Pages のリポジトリの中にあるので、`main` に入るとソースが `denkingon.github.io/ekitsuuchi-todo/` で公開される（鍵・個人情報は入っていない。`Config/Secrets.xcconfig` は `.gitignore` 済み）。分けたくなったら `git subtree split -P ekitsuuchi-todo` で切り出せる。
