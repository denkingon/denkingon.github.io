/* ============================================================
   view.js — シートの描画 / ミニタイムライン / 適合平面
   描く側は状態を持たない。S（app.js が持つ）を読んで HTML を返すだけ
   ============================================================ */
import { KINDS, REC, blockDur, judgeCell, tc, projectEnd, eachCell } from "./core.js";

const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;" }[c]));

/* ---------------- 1ブロックの判定をまとめる ---------------- */
export function blockInfo(S, b){
  const dict = S.proj.dict, rate = S.rate;
  const cells = b.kind === "SILENT" ? [] : b.cells.map(c => judgeCell(c, dict, rate));
  return { cells, over: cells.some(j => j.over), dur: blockDur(b) };
}

/* ---------------- シート ---------------- */
export function renderSheet(S){
  const { proj } = S;
  const vis = proj.lanes.map((_, i) => i).filter(i => S.show[i]);
  const el = document.getElementById("sheet");
  el.classList.toggle("flow", S.flow);

  const rows = [];                              // 表示するブロック（時間順）
  for (const b of proj.blocks) {
    if (!S.show[b.lane]) continue;
    const info = blockInfo(S, b);
    if (S.onlyRed && !info.over) continue;
    rows.push({ b, info });
  }

  if (!rows.length) {
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
    el.innerHTML = rows.map(({ b, info }) =>
      `<div class="tc">${tc(b.t)}</div>` + cardHTML(S, b, info, true)).join("");
    return;
  }

  // 列表示：時刻レール + レーン列。列ごとに罫を1本通し、空きが「穴」でなく「休み」に見えるようにする
  el.style.gridTemplateColumns = "58px " + vis.map(() => "minmax(0,1fr)").join(" ");
  el.style.gridTemplateRows = "auto " + rows.map(() => "auto").join(" ");

  const redPerLane = proj.lanes.map(() => 0);
  for (const { c, b } of eachCell(proj)) if (judgeCell(c, proj.dict, S.rate).over) redPerLane[b.lane]++;

  let h = `<div class="head" style="grid-row:1;grid-column:1"></div>`;
  vis.forEach((li, k) => {
    const n = redPerLane[li];
    h += `<div class="head" style="grid-row:1;grid-column:${k + 2}"><b>${esc(proj.lanes[li])}</b>` +
         `<span class="n${n ? " red" : ""}">${n ? "赤" + n : "—"}</span></div>`;
  });
  vis.forEach((_, k) => {
    h += `<div class="rail" style="grid-row:2/-1;grid-column:${k + 2}"></div>`;
  });

  rows.forEach(({ b, info }, i) => {
    const r = i + 2, col = vis.indexOf(b.lane) + 2;
    h += `<div class="tc${S.curBlock === b.id ? " hot" : ""}" style="grid-row:${r};grid-column:1">${tc(b.t)}<u></u></div>`;
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
    cellsH += `<div class="cell${j.over ? " bad" : ""}" data-cell="${ci}">` +
      (one ? "" : `<div class="gut"><span class="no">${ci + 1}</span><span class="gbar"></span></div>`) +
      `<div class="cbody">` +
        `<div class="slot"><b>${j.dur.toFixed(1)}秒</b><span class="at">${tc(t)}</span></div>` +
        (c.en ? `<p class="en">${esc(c.en)}</p>` : "") +
        `<div class="ja" contenteditable="true" spellcheck="false" role="textbox" aria-label="訳文"` +
          ` data-b="${b.id}" data-c="${ci}">${esc(c.ja)}</div>` +
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
    `<div class="cells${one ? " one" : ""}">${cellsH}</div>` +
  `</div>`;
}

export function metaHTML(j){
  return `<span>${j.mora}モーラ</span>` +
    (j.exact ? "" : `<span class="est" title="漢字のよみは辞書がないと確定しない">推</span>`) +
    `<span class="${j.over ? "bad" : ""}"><b>${j.req.toFixed(1)}</b> /秒</span>` +
    `<span class="${j.over ? "bad" : ""}">${j.over ? "超過 +" + Math.ceil(j.delta) : "余裕 " + Math.floor(-j.delta)}</span>`;
}

/* ---------------- ミニタイムライン（赤の一望装置） ---------------- */
export function renderMini(S){
  const { proj } = S;
  const end = projectEnd(proj) || 1;
  const rowsEl = document.getElementById("mrows");
  const pct = x => (x / end * 100) + "%";

  document.getElementById("mlabs").innerHTML =
    shortLabels(proj.lanes).map(s => `<span>${esc(s)}</span>`).join("");

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
        segs += `<i class="${j.over ? "red " : ""}${S.curBlock === b.id ? "cur" : ""}"` +
                ` style="left:${pct(t)};width:${pct(w)}"></i>`;
        t += j.dur;
      });
    }
    return `<div class="mrow" data-mlane="${li}">${segs}</div>`;
  }).join("");

  // レーンを畳んでも赤の位置は消さない
  let sum = "";
  for (const { c, t } of eachCell(proj)) {
    const j = judgeCell(c, proj.dict, S.rate);
    if (j.over) sum += `<i style="left:${pct(t)};width:${pct(Math.max(j.dur, end * 0.002))}"></i>`;
  }
  document.getElementById("msum").innerHTML = sum;

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
  for (const { b, c, ci, t } of eachCell(proj)) {
    const j = judgeCell(c, proj.dict, S.rate);
    if (j.dur <= 0) continue;
    pts.push({ b, ci, t, ...j, ja: c.ja });
  }
  const W = 900, H = 470, P = { l: 52, r: 18, t: 26, b: 52 };
  const maxX = Math.max(6, ...pts.map(p => p.dur)) * 1.12;
  const maxY = Math.max(20, ...pts.map(p => p.mora), maxX * S.limit) * 1.08;
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
    `<circle class="pt" data-i="${i}" cx="${X(p.dur)}" cy="${Y(p.mora)}" r="${p.over ? 4.5 : 3.5}"` +
    ` fill="${p.over ? "#c03a2b" : "#7d858c"}" stroke="${p.over ? "#e0503c" : "none"}" stroke-width="1">` +
    `<title>${esc(tc(p.t))}　${p.dur.toFixed(1)}秒 / ${p.mora}モーラ / ${p.req.toFixed(1)}per秒` +
    (p.over ? `　超過 +${Math.ceil(p.delta)}モーラ` : "") + `</title></circle>`).join("");

  const drops = pts.filter(p => p.over).map(p =>
    `<line x1="${X(p.dur)}" y1="${Y(p.mora)}" x2="${X(p.dur)}" y2="${Y(S.rate * p.dur)}"` +
    ` stroke="#c03a2b" stroke-width="1" stroke-dasharray="2 2"/>`).join("");

  document.getElementById("planesvg").innerHTML =
    `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="適合平面">
      ${g}
      <line x1="${P.l}" y1="${P.t}" x2="${P.l}" y2="${H - P.b}" stroke="#525860"/>
      <line x1="${P.l}" y1="${H - P.b}" x2="${W - P.r}" y2="${H - P.b}" stroke="#525860"/>
      <polyline points="${lineTo(S.limit)}" fill="none" stroke="#6d7378" stroke-width="1" stroke-dasharray="5 4"/>
      <polyline points="${lineTo(S.rate)}" fill="none" stroke="#9ba1a7" stroke-width="1.5"/>
      ${drops}${dots}
      <text x="${(P.l + W - P.r) / 2}" y="${H - 6}" fill="#6d7378" font-size="10" text-anchor="middle">持ち時間（秒）</text>
      <text x="${P.l - 8}" y="${P.t - 10}" fill="#6d7378" font-size="10" text-anchor="end">モーラ</text>
    </svg>`;

  const worst = pts.filter(p => p.over).sort((a, b) => b.delta - a.delta).slice(0, 40);
  document.getElementById("worstbody").innerHTML = worst.length
    ? worst.map(p =>
        `<tr data-jump="${p.b.id}"><td class="m">${tc(p.t)}</td>` +
        `<td class="m">${p.dur.toFixed(1)}</td><td class="m">${p.mora}</td>` +
        `<td class="m bad">${p.req.toFixed(1)}</td>` +
        `<td class="m bad">−${Math.ceil(p.delta)}</td>` +
        `<td><div class="ja">${esc(p.ja)}</div></td></tr>`).join("")
    : `<tr><td colspan="6" style="color:#6d7378">赤はありません。</td></tr>`;

  document.getElementById("planestat").textContent =
    `${pts.length} セル中 ${pts.filter(p => p.over).length} 件が線の上。基準 ${S.rate.toFixed(1)} /秒・限界 ${S.limit.toFixed(1)} /秒`;
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
