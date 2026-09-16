/* ============================================================
   view.js — シートの描画 / ミニタイムライン / 適合平面
   描く側は状態を持たない。S（app.js が持つ）を読んで HTML を返すだけ
   ============================================================ */
import { KINDS, REC, blockDur, tc, projectEnd, hasPin, plainJa } from "./core.js";

const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;" }[c]));
/** 訳文の HTML：《…》を <mark> にする。対になっていない記号はそのまま見せる */
export const jaHTML = s => esc(s).replace(/《([^《》]*)》/g, "<mark>$1</mark>");

/* ---------------- 1ブロックの判定をまとめる ---------------- */
export function blockInfo(S, b){
  const cells = b.kind === "SILENT" ? [] : b.cells.map((_, ci) => S.J.cells.get(b.id + ":" + ci));
  const take = S.takes ? S.takes.get(b.id) : null;      // 本番の録音が枠に収まっているか
  return { cells, over: cells.some(j => j.red) || !!(take && take.over), rescued: cells.some(j => j.rescued),
           takeOver: !!(take && take.over), dur: blockDur(b) };
}
export const laneRedCount = (S, li) => [...S.J.cells.values()].filter(v => v.lane === li && v.red).length;

/* ピンの行に出す、その時刻から始まる区間の収支（レーンごと） */
export function sectionAt(S, t, li){
  return S.J.sections.find(s => s.lane === li && Math.abs(s.t0 - t) < 0.05) || null;
}
export function pinBalanceHTML(S, t, li){
  const s = sectionAt(S, t, li);
  if (!s) return "";
  const n = Math.round(s.balance), sign = n > 0 ? "+" : n < 0 ? "−" : "±";
  return `<b class="${s.over ? "red" : ""}">${sign}${Math.abs(n)}</b>` +
         `<span title="モーラ ${s.mora} / 予算 ${Math.round(s.budget)}（${s.keys.length}セル・${s.dur.toFixed(1)}秒）">${s.mora}/${Math.round(s.budget)}</span>`;
}
export function pinFlowHTML(S, t){
  const parts = S.proj.lanes.map((n, li) => {
    const h = pinBalanceHTML(S, t, li);
    return h ? `<span class="pl"><i>${esc(n)}</i>${h}</span>` : "";
  }).filter(Boolean);
  return `<span class="pt">${tc(t)}</span>` + parts.join("");
}

/* ---------------- シート ---------------- */
export function renderSheet(S){
  const { proj } = S;
  const vis = proj.lanes.map((_, i) => i).filter(i => S.show[i]);
  const el = document.getElementById("sheet");
  el.classList.toggle("flow", S.flow);

  // 表示する行を時間順に組む。ブロックの前に、その時刻までのピンを差し込む
  const pins = S.J.pins, items = [];
  let pi = 0, nBlocks = 0;
  for (const b of proj.blocks) {
    if (!S.show[b.lane]) continue;
    const info = blockInfo(S, b);
    if (S.onlyRed && !info.over) continue;
    while (pi < pins.length && pins[pi] <= b.t + 1e-6) items.push({ pin: pins[pi++] });
    items.push({ b, info }); nBlocks++;
  }
  while (pi < pins.length) items.push({ pin: pins[pi++] });

  if (!nBlocks) {
    el.style.gridTemplateColumns = "minmax(0,1fr)";
    el.style.gridTemplateRows = "auto";
    el.innerHTML = `<div class="empty-state">${
      proj.blocks.length
        ? (S.onlyRed ? "赤はありません。" : "表示するレーンがありません。")
        : "ブロックがありません。<br>SRT/VTT を取り込むか、サンプルを読み込んでください。"
    }</div>`;
    return;
  }

  if (S.flow) {
    el.style.gridTemplateColumns = "minmax(0,1fr)";
    el.style.gridTemplateRows = "";
    el.innerHTML = items.map(it => it.pin != null
      ? `<div class="pinflow" data-pin="${it.pin}">${pinFlowHTML(S, it.pin)}<button class="unpin" data-unpin="${it.pin}" title="このピンを外す" aria-label="ピンを外す">×</button></div>`
      : `<div class="tc" data-pin-at="${it.b.t}" title="押すとここにピンを打つ">${hasPin(S.proj, it.b.t) ? "" : tc(it.b.t)}</div>` + cardHTML(S, it.b, it.info, true)
    ).join("");
    return;
  }

  // 列表示：時刻レール + レーン列。列ごとに罫を1本通し、空きが「穴」でなく「休み」に見えるようにする
  el.style.gridTemplateColumns = "58px " + vis.map(() => "minmax(0,1fr)").join(" ");
  el.style.gridTemplateRows = "auto " + items.map(() => "auto").join(" ");

  let h = `<div class="head" style="grid-row:1;grid-column:1"></div>`;
  vis.forEach((li, k) => {
    const n = laneRedCount(S, li);
    h += `<div class="head" style="grid-row:1;grid-column:${k + 2}"><b>${esc(proj.lanes[li])}</b>` +
         `<span class="n${n ? " red" : ""}" data-lane-head="${li}">${n ? "赤" + n : "—"}</span></div>`;
  });
  vis.forEach((_, k) => {
    h += `<div class="rail" style="grid-row:2/-1;grid-column:${k + 2}"></div>`;
  });

  items.forEach((it, i) => {
    const r = i + 2;
    if (it.pin != null) {
      h += `<div class="pintc" data-pin="${it.pin}" style="grid-row:${r};grid-column:1"><button class="unpin" data-unpin="${it.pin}" title="このピンを外す" aria-label="ピンを外す">×</button>${tc(it.pin)}</div>`;
      vis.forEach((li, k) => {
        const s = sectionAt(S, it.pin, li);
        h += `<div class="pincell${s && s.over ? " over" : ""}" data-pin="${it.pin}" data-lane="${li}"` +
             ` style="grid-row:${r};grid-column:${k + 2}">${pinBalanceHTML(S, it.pin, li)}</div>`;
      });
      return;
    }
    const { b, info } = it, col = vis.indexOf(b.lane) + 2;
    // ピンがその時刻にあるなら、時刻はピンの行が出しているので二重に出さない
    h += `<div class="tc${S.curBlock === b.id ? " hot" : ""}" data-pin-at="${b.t}" title="${hasPin(S.proj, b.t) ? "ピンあり（外すのはピンの行の ×）" : "押すとここにピンを打つ"}"` +
         ` style="grid-row:${r};grid-column:1">${hasPin(S.proj, b.t) ? "" : tc(b.t)}<u></u></div>`;
    h += cardHTML(S, b, info, false, `grid-row:${r};grid-column:${col}`);
  });
  el.innerHTML = h;
}

function cardHTML(S, b, info, flow, style = ""){
  const laneName = S.proj.lanes[b.lane] || "?";
  const range = tc(b.t) + " – " + tc(b.t + info.dur);

  if (b.kind === "SILENT") {
    return `<div class="silent" data-b="${b.id}" style="${style}">` +
      `<span>無音（クリップ）</span><span class="hint">触れない空白。跨げない</span>` +
      `<span class="span" style="margin-left:auto">${range}</span></div>`;
  }

  const cls = ["card", info.over ? "over" : "", S.sel === b.id ? "sel" : "",
               S.curBlock === b.id ? "playing" : ""].filter(Boolean).join(" ");
  const one = b.cells.length === 1;

  let cellsH = "";
  let t = b.t;
  b.cells.forEach((c, ci) => {
    const j = info.cells[ci];
    cellsH += `<div class="cell${j.red ? " bad" : ""}" data-cell="${ci}">` +
      (one ? "" : `<div class="gut"><span class="no">${ci + 1}</span><span class="gbar"></span></div>`) +
      `<div class="cbody">` +
        `<div class="slot"><b>${j.dur.toFixed(1)}秒</b><span class="at">${tc(t)}</span></div>` +
        (c.en ? `<p class="en">${esc(c.en)}</p>` : "") +
        `<div class="ja" contenteditable="true" spellcheck="false" role="textbox" aria-label="訳文"` +
          ` data-b="${b.id}" data-c="${ci}">${jaHTML(c.ja)}</div>` +
        `<div class="kana${(c.kana || S.kanaOpen.has(b.id + ":" + ci)) ? " on" : ""}" contenteditable="true"` +
          ` spellcheck="false" role="textbox" aria-label="よみ" data-kb="${b.id}" data-kc="${ci}">${esc(c.kana)}</div>` +
        `<div class="meta">${metaHTML(j)}` +
          `<button class="kanabtn" data-kana="${b.id}:${ci}">よみ</button>` +
        `</div>` +
      `</div></div>`;
    t += j.dur;
  });

  const frame = S.frames[b.id];
  const kindName = KINDS[b.kind];
  // レーン名と種別が同じ語のときは片方だけ出す（「ナレーション ナレーション」を避ける）
  const showLane = flow || S.show.filter(Boolean).length > 1;
  const labels = (showLane ? `<span class="lane-chip">${esc(laneName)}</span>` : "") +
    (laneName === kindName && showLane ? "" : `<span class="kind" title="ブロックを編集">${kindName}</span>`);

  return `<div class="${cls}" data-b="${b.id}" style="${style}">` +
    `<div class="chead">` +
      `<div class="film${frame ? "" : " empty"}">` +
        (frame ? `<img src="${frame}" alt="">` : `<span>コマ</span>`) +
        `<em>${tc(b.t)}</em></div>` +
      `<div class="cmeta">` +
        `<div class="crow">` +
          `<button class="rec" data-rec="${b.id}" data-state="${b.rec}" title="録音ステータス（未→仮→済）">${REC[b.rec]}</button>` +
          labels +
        `</div>` +
        `<span class="span">${range}</span>` +
      `</div>` +
    `</div>` +
    (S.wav ? `<div class="wavebox"><canvas class="wave" data-wave="${b.id}" width="640" height="36"></canvas>` +
             `<span class="wmeta" data-wmeta="${b.id}"></span></div>` : "") +
    `<div class="cells${one ? " one" : ""}">${cellsH}</div>` +
  `</div>`;
}

export function metaHTML(j){
  return `<span>${j.mora}モーラ</span>` +
    (j.exact ? "" : `<span class="est" title="漢字のよみは辞書がないと確定しない">推</span>`) +
    `<span class="${j.red ? "bad" : ""}"><b>${j.req.toFixed(1)}</b> /秒</span>` +
    `<span class="${j.red ? "bad" : ""}">${j.over ? "超過 +" + Math.ceil(j.delta) : "余裕 " + Math.floor(-j.delta)}</span>` +
    (j.rescued ? `<span class="est" title="このセル単体では入らないが、ピンで囲んだ区間の合計では入る">区間で吸収</span>` : "");
}

/* ---------------- ミニタイムライン（赤の一望装置） ---------------- */
export function renderMini(S){
  const { proj } = S;
  const end = projectEnd(proj) || 1;
  const rowsEl = document.getElementById("mrows");
  const pct = x => (x / end * 100) + "%";

  document.getElementById("mlabs").innerHTML =
    (S.wav ? `<span class="mw">録</span>` : "") +
    shortLabels(proj.lanes).map(s => `<span>${esc(s)}</span>`).join("");
  document.getElementById("mwave").hidden = !S.wav;

  rowsEl.innerHTML = proj.lanes.map((name, li) => {
    let segs = "";
    for (const b of proj.blocks) {
      if (b.lane !== li) continue;
      const info = blockInfo(S, b);
      if (b.kind === "SILENT") {
        segs += `<i class="clip" style="left:${pct(b.t)};width:${pct(info.dur)}"></i>`;
        continue;
      }
      // セル単位で描く。どのセルが赤かまでここで分かる
      let t = b.t;
      b.cells.forEach((c, ci) => {
        const j = info.cells[ci], w = Math.max(j.dur, end * 0.0015);
        segs += `<i class="${j.red ? "red " : ""}${S.curBlock === b.id ? "cur" : ""}"` +
                ` style="left:${pct(t)};width:${pct(w)}"></i>`;
        t += j.dur;
      });
    }
    return `<div class="mrow" data-mlane="${li}">${segs}</div>`;
  }).join("");

  // レーンを畳んでも赤の位置は消さない
  let sum = "";
  for (const v of S.J.cells.values())
    if (v.red) sum += `<i style="left:${pct(v.t)};width:${pct(Math.max(v.dur, end * 0.002))}"></i>`;
  if (S.takes) for (const [, tk] of S.takes)     // 録音のはみ出しも「入らない」なので同じ帯に出す
    if (tk.over && tk.take) sum += `<i style="left:${pct(tk.take.start)};width:${pct(Math.max(tk.take.dur, end * 0.002))}"></i>`;
  document.getElementById("msum").innerHTML = sum;
  document.getElementById("mpins").innerHTML = S.J.pins.map(t => `<i style="left:${pct(t)}"></i>`).join("");

  const ticks = document.getElementById("mticks");
  const step = end > 1800 ? 300 : end > 600 ? 120 : end > 180 ? 30 : 10;
  let tk = "";
  for (let x = step; x < end; x += step) {
    tk += `<u class="${x % (step * 5) === 0 ? "big" : ""}" style="left:${pct(x)}"></u>`;
  }
  ticks.innerHTML = tk;
}

/* ---------------- 適合平面（パレットB） ---------------- */
export function renderPlane(S){
  const { proj } = S;
  const pts = [];
  for (const v of S.J.cells.values()) {
    if (v.dur <= 0) continue;
    pts.push({ ...v, ja: v.b.cells[v.ci].ja });
  }
  const secs = S.J.sections;
  const W = 900, H = 470, P = { l: 52, r: 18, t: 26, b: 52 };
  const maxX = Math.max(6, ...pts.map(p => p.dur), ...secs.map(s => s.dur)) * 1.12;
  const maxY = Math.max(20, ...pts.map(p => p.mora), ...secs.map(s => s.mora), maxX * S.limit) * 1.08;
  const X = v => P.l + v / maxX * (W - P.l - P.r);
  const Y = v => H - P.b - v / maxY * (H - P.t - P.b);

  const gridStepX = niceStep(maxX), gridStepY = niceStep(maxY);
  let g = "";
  for (let v = 0; v <= maxX; v += gridStepX)
    g += `<line x1="${X(v)}" y1="${P.t}" x2="${X(v)}" y2="${H - P.b}" stroke="#2e3236"/>` +
         `<text x="${X(v)}" y="${H - P.b + 15}" fill="#6d7378" font-size="10" text-anchor="middle" font-family="ui-monospace,monospace">${v}</text>`;
  for (let v = 0; v <= maxY; v += gridStepY)
    g += `<line x1="${P.l}" y1="${Y(v)}" x2="${W - P.r}" y2="${Y(v)}" stroke="#2e3236"/>` +
         `<text x="${P.l - 8}" y="${Y(v) + 3}" fill="#6d7378" font-size="10" text-anchor="end" font-family="ui-monospace,monospace">${v}</text>`;

  const lineTo = r => {
    const x = Math.min(maxX, maxY / r);
    return `${X(0)},${Y(0)} ${X(x)},${Y(r * x)}`;
  };

  const dots = pts.map((p, i) =>
    `<circle class="pt" data-i="${i}" cx="${X(p.dur)}" cy="${Y(p.mora)}" r="${p.red ? 4.5 : 3.5}"` +
    ` fill="${p.red ? "#c03a2b" : p.rescued ? "none" : "#7d858c"}"` +
    ` stroke="${p.red ? "#e0503c" : p.rescued ? "#9ba1a7" : "none"}" stroke-width="${p.rescued ? 1.5 : 1}">` +
    `<title>${esc(tc(p.t))}　${p.dur.toFixed(1)}秒 / ${p.mora}モーラ / ${p.req.toFixed(1)}per秒` +
    (p.over ? `　超過 +${Math.ceil(p.delta)}モーラ` : "") + (p.rescued ? "（区間で吸収）" : "") + `</title></circle>`).join("");

  // 区間は大きな輪。セルと同じ平面に乗せると「まとめて入るか」がそのまま見える
  const rings = secs.map(s =>
    `<circle cx="${X(s.dur)}" cy="${Y(s.mora)}" r="7" fill="none" stroke="${s.over ? "#c03a2b" : "#6d7378"}"` +
    ` stroke-width="1.5" stroke-dasharray="3 2"><title>区間 ${esc(proj.lanes[s.lane])}　${esc(tc(s.t0))}–${esc(tc(s.t1))}` +
    `　${s.dur.toFixed(1)}秒 / ${s.mora}モーラ　収支 ${Math.round(s.balance)}</title></circle>`).join("");

  const drops = pts.filter(p => p.red).map(p =>
    `<line x1="${X(p.dur)}" y1="${Y(p.mora)}" x2="${X(p.dur)}" y2="${Y(S.rate * p.dur)}"` +
    ` stroke="#c03a2b" stroke-width="1" stroke-dasharray="2 2"/>`).join("");

  document.getElementById("planesvg").innerHTML =
    `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="適合平面">
      ${g}
      <line x1="${P.l}" y1="${P.t}" x2="${P.l}" y2="${H - P.b}" stroke="#525860"/>
      <line x1="${P.l}" y1="${H - P.b}" x2="${W - P.r}" y2="${H - P.b}" stroke="#525860"/>
      <polyline points="${lineTo(S.limit)}" fill="none" stroke="#6d7378" stroke-width="1" stroke-dasharray="5 4"/>
      <polyline points="${lineTo(S.rate)}" fill="none" stroke="#9ba1a7" stroke-width="1.5"/>
      ${drops}${rings}${dots}
      <text x="${(P.l + W - P.r) / 2}" y="${H - 6}" fill="#6d7378" font-size="10" text-anchor="middle">持ち時間（秒）</text>
      <text x="${P.l - 8}" y="${P.t - 10}" fill="#6d7378" font-size="10" text-anchor="end">モーラ</text>
    </svg>`;

  const worst = pts.filter(p => p.red).sort((a, b) => b.delta - a.delta).slice(0, 40);
  const secRows = secs.filter(s => s.over).sort((a, b) => a.balance - b.balance).map(s => {
    const first = S.J.cells.get(s.keys[0]);
    return `<tr data-jump="${first ? first.b.id : ""}"><td class="m">${tc(s.t0)}–${tc(s.t1)}</td>` +
      `<td class="m">${s.dur.toFixed(1)}</td><td class="m">${s.mora}</td>` +
      `<td class="m bad">${(s.mora / s.dur).toFixed(1)}</td><td class="m bad">−${Math.abs(Math.round(s.balance))}</td>` +
      `<td><div class="ja">区間 ${esc(proj.lanes[s.lane])}（${s.keys.length}セル）</div></td></tr>`;
  }).join("");
  document.getElementById("worstbody").innerHTML = (worst.length || secRows)
    ? secRows + worst.map(p =>
        `<tr data-jump="${p.b.id}"><td class="m">${tc(p.t)}</td>` +
        `<td class="m">${p.dur.toFixed(1)}</td><td class="m">${p.mora}</td>` +
        `<td class="m bad">${p.req.toFixed(1)}</td>` +
        `<td class="m bad">−${Math.ceil(p.delta)}</td>` +
        `<td><div class="ja">${esc(plainJa(p.ja))}</div></td></tr>`).join("")
    : `<tr><td colspan="6" style="color:#6d7378">赤はありません。</td></tr>`;

  const sp = S.proj.speedup > 0 ? S.proj.speedup : 1;
  document.getElementById("planestat").textContent =
    `${pts.length} セル中 ${pts.filter(p => p.red).length} 件が赤。基準 ${S.rate.toFixed(1)} /秒・限界 ${S.limit.toFixed(1)} /秒` +
    (sp !== 1 ? `（録音 ${sp}× 前提）` : "") +
    (secs.length ? `　区間 ${secs.length}（超過 ${secs.filter(s => s.over).length}）` : "");
  S.planePts = pts;
}

/** レーン名から、互いに区別のつく1文字を作る。
    「ナレーション / 人物A / 人物B」→「ナ / A / B」（頭文字がぶつかる組だけ末尾に落とす） */
function shortLabels(names){
  const first = names.map(n => (n || "?").trim().slice(0, 1) || "?");
  const dup = new Set(first.filter((c, i) => first.indexOf(c) !== i));
  return names.map((n, i) => {
    if (!dup.has(first[i])) return first[i];
    const s = (n || "?").trim();
    return s.slice(-1) || first[i];
  });
}

function niceStep(max){
  const raw = max / 6, p = Math.pow(10, Math.floor(Math.log10(raw))), n = raw / p;
  return (n >= 5 ? 5 : n >= 2 ? 2 : 1) * p;
}
