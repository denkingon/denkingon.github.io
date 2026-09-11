# 村田亮 — portfolio

村田亮 (denkingon) のポートフォリオサイト。

- 公開URL: https://denkingon.github.io/
- `index.html` — サイト本体(現在は準備中ページ)
- `main` ブランチに push すると GitHub Pages が自動で再公開する

## フォントシャッフル テンプレ

`assets/font-shuffle.js` を読み込むと、テキストのフォントを一定間隔(既定0.1秒)でシャッフルする演出をどこにでも当てられる。依存ゼロ・1ファイルなので他プロジェクトへはコピーするだけ。

```html
<script src="assets/font-shuffle.js"></script>

<!-- 属性を付けるだけで自動開始 -->
<h1 data-font-shuffle>シャッフルされる見出し</h1>
<p data-font-shuffle data-font-shuffle-interval="150" data-font-shuffle-duration="3000">3秒だけ0.15秒間隔</p>
```

```js
// JS から制御する場合
var ctl = FontShuffle.start("h1", { interval: 100 });
ctl.stop(); // 停止して元のフォントに戻す
```

オプション: `interval`(切替間隔ms・既定100) / `duration`(自動停止までのms・既定0=無期限) / `fonts`(font-familyスタック配列・既定は端末内蔵8種)。属性版は `data-font-shuffle-fonts="serif|monospace"` のように `|` 区切り。reduced-motion設定の端末では自動的に無効。

## フォントシャッフル テンプレ

`assets/font-shuffle.js` を読み込むと、任意のテキストのフォントを一定間隔(既定0.1秒)でシャッフルできる。依存なし・1ファイル。

```html
<script src="assets/font-shuffle.js"></script>

<!-- 属性を書くだけで自動開始 -->
<h1 data-font-shuffle>見出し</h1>
<h1 data-font-shuffle data-font-shuffle-interval="150" data-font-shuffle-duration="3000">3秒で止まる</h1>
```

```js
// JSから制御する場合
var ctl = FontShuffle.start("h1", { interval: 100 });
ctl.stop(); // 停止して元のフォントに戻す
```

詳しいオプションは `.claude/skills/font-shuffle/SKILL.md` を参照(Claude Code からは「フォントシャッフル当てて」で使える)。
