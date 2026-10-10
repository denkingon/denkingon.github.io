/*!
 * font-shuffle.js — テキストのフォントを一定間隔でシャッフルする演出テンプレ
 * 依存なし・このファイル1枚をコピーするだけで他プロジェクトでも使える。
 * 使い方: README.md「フォントシャッフル テンプレ」/ .claude/skills/font-shuffle/SKILL.md
 *
 *   <script src="assets/font-shuffle.js"></script>
 *   HTML: <span data-font-shuffle>TEXT</span>        … 読み込むだけで自動開始
 *   JS  : var ctl = FontShuffle.start("h1");         … ctl.stop() で停止して元に戻す
 */
(function () {
  "use strict";

  // 既定の端末内蔵フォント8種 (外部読み込みなし。無い環境では末尾の generic に落ちる)
  var FONTS = [
    '"Hiragino Mincho ProN", "Yu Mincho", "MS PMincho", serif',
    '"Hiragino Kaku Gothic ProN", "Yu Gothic", sans-serif',
    '"Courier New", "Osaka-Mono", "MS Gothic", monospace',
    'Georgia, "Times New Roman", "Hiragino Mincho ProN", serif',
    '"Arial Black", Impact, "Hiragino Sans", sans-serif',
    '"Comic Sans MS", "Chalkboard SE", "Hiragino Maru Gothic ProN", cursive',
    '"Brush Script MT", "Segoe Script", cursive',
    'Futura, "Trebuchet MS", Verdana, sans-serif'
  ];

  function toElements(target) {
    if (typeof target === "string") return Array.prototype.slice.call(document.querySelectorAll(target));
    if (target && target.nodeType === 1) return [target];
    if (target && typeof target.length === "number") return Array.prototype.slice.call(target);
    return [];
  }

  function prefersReducedMotion() {
    return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  // target: CSSセレクタ / Element / NodeList / 配列
  // opts:
  //   interval             切替間隔ms (既定100 = 0.1秒)
  //   fonts                font-family スタックの配列 (既定 FontShuffle.FONTS)
  //   duration             自動停止までのms (既定0 = 止めるまで続く)
  //   respectReducedMotion 既定true。reduce設定の端末では何もしない
  // 戻り値: { stop() } — 停止して元のフォントに戻す。何度呼んでも安全
  function start(target, opts) {
    opts = opts || {};
    var els = toElements(target);
    var fonts = opts.fonts && opts.fonts.length >= 2 ? opts.fonts : FONTS;
    var interval = opts.interval > 0 ? opts.interval : 100;
    var noop = { stop: function () {} };
    if (!els.length) return noop;
    if (opts.respectReducedMotion !== false && prefersReducedMotion()) return noop;

    var original = els.map(function (el) { return el.style.fontFamily; });
    var current = els.map(function () { return -1; });
    var stopped = false;
    var durTimer = null;

    // 要素ごとに独立して抽選。直前と同じフォントは引き直す
    function roll(i) {
      var next;
      do {
        next = Math.floor(Math.random() * fonts.length);
      } while (next === current[i]);
      current[i] = next;
      els[i].style.fontFamily = fonts[next];
    }

    var iv = setInterval(function () {
      if (document.hidden) return; // 非表示タブで切り替え続けない
      for (var i = 0; i < els.length; i++) roll(i);
    }, interval);

    function stop() {
      if (stopped) return;
      stopped = true;
      clearInterval(iv);
      if (durTimer) clearTimeout(durTimer);
      els.forEach(function (el, i) { el.style.fontFamily = original[i]; });
    }

    if (opts.duration > 0) durTimer = setTimeout(stop, opts.duration);
    return { stop: stop };
  }

  // data-font-shuffle 属性の自動起動:
  //   <span data-font-shuffle>TEXT</span>
  //   任意: data-font-shuffle-interval="150"  data-font-shuffle-duration="3000"
  //         data-font-shuffle-fonts="serif|monospace|cursive"  (| 区切り)
  function autoInit() {
    toElements("[data-font-shuffle]").forEach(function (el) {
      var fonts = el.getAttribute("data-font-shuffle-fonts");
      start(el, {
        interval: parseInt(el.getAttribute("data-font-shuffle-interval"), 10) || 0,
        duration: parseInt(el.getAttribute("data-font-shuffle-duration"), 10) || 0,
        fonts: fonts ? fonts.split("|") : null
      });
    });
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", autoInit);
  } else {
    autoInit();
  }

  window.FontShuffle = { start: start, FONTS: FONTS };
})();
