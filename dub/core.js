/* ============================================================
   core.js — モーラ計算 / データモデル / 入出力
   ============================================================ */

/* ---------------- モーラ ----------------
   数え方（設計メモ 5節）:
     かな1文字 = 1 / 拗音・小書きは前と合わせて 1
     促音「っ」= 1  撥音「ん」= 1  長音「ー」= 1
   漢字は辞書が無いと確定できない。よって:
     ・よみ（かな）が入っていれば確定
     ・読み辞書に載っていれば確定
     ・どちらも無ければ推定。推定のセルには「推」が付く
   推定係数は pykakasi の実測に合わせた:
     熟語（漢字2字以上の連続）… 1.9 / 字（音読み）
     単独漢字（送り仮名つき）… 1.4 / 字（訓読みの語幹は1〜2モーラが多い）
   ---------------------------------------- */

export const SMALL = "ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ";
const RE_KANA  = /[ぁ-んァ-ヴｦ-ﾟ]/;
const RE_KANJI = /[々〆ヵヶ一-鿿豈-﫿]/;
const RE_LAT   = /[A-Za-zＡ-Ｚａ-ｚ]/;
const RE_NUM   = /[0-9０-９]/;

export function moraFromKana(s){
  let m = 0;
  for (const ch of String(s)) {
    if (SMALL.includes(ch)) continue;          // 拗音・小書きは前と合わせて1
    if (ch === "ー" || ch === "ｰ") { m++; continue }
    if (RE_KANA.test(ch)) m++;                 // 「っ」「ん」もここで1
  }
  return m;
}

function applyDict(text, dict){
  if (!dict) return text;
  const keys = Object.keys(dict).filter(k => k).sort((a,b) => b.length - a.length);
  let s = text;
  for (const k of keys) s = s.split(k).join(dict[k]);
  return s;
}

/** 訳文から推定。{ mora, exact } */
export function estimateMora(text, dict){
  const s = applyDict(String(text || ""), dict);
  let m = 0, exact = true, i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (RE_KANJI.test(ch)) {
      let j = i; while (j < s.length && RE_KANJI.test(s[j])) j++;
      const run = j - i;
      m += run >= 2 ? run * 1.9 : 1.4;
      exact = false; i = j; continue;
    }
    if (ch === "ー" || ch === "ｰ") { m += 1; i++; continue }
    if (SMALL.includes(ch)) { i++; continue }
    if (RE_KANA.test(ch)) { m += 1; i++; continue }
    if (RE_LAT.test(ch)) {
      let j = i; while (j < s.length && RE_LAT.test(s[j])) j++;
      m += Math.max(1, Math.round((j - i) * 1.6));   // 英字はおおよそ
      exact = false; i = j; continue;
    }
    if (RE_NUM.test(ch)) { m += 2; exact = false; i++; continue }
    i++;                                              // 記号・空白は0
  }
  return { mora: Math.round(m), exact };
}

/** セル1つのモーラ。よみが入っていれば確定 */
export function cellMora(cell, dict){
  const k = (cell.kana || "").trim();
  if (k) return { mora: moraFromKana(k), exact: true };
  return estimateMora(cell.ja || "", dict);
}

/* ---------------- モデル ---------------- */

export const KINDS = { NARR:"ナレーション", LIP:"口合わせ", SILENT:"無音（クリップ）" };
export const REC   = ["未", "仮", "済"];

let _seq = 0;
export const uid = (p = "x") => p + "_" + (Date.now().toString(36)) + (_seq++).toString(36);

export function newCell(o = {}){
  return { id: uid("c"), dur: o.dur ?? 4, en: o.en ?? "", ja: o.ja ?? "", kana: o.kana ?? "" };
}
export function newBlock(o = {}){
  return {
    id: uid("b"), lane: o.lane ?? 0, kind: o.kind ?? "NARR", t: o.t ?? 0, rec: o.rec ?? 0,
    cells: (o.cells || [newCell()]).map(newCell),
  };
}
export const blockDur = b =>
  b.kind === "SILENT" ? (b.dur ?? 0) : b.cells.reduce((s, c) => s + (+c.dur || 0), 0);

export function newProject(o = {}){
  return {
    v: 1,
    title: o.title ?? "無題",
    lanes: o.lanes ?? ["ナレーション", "人物A", "人物B"],
    duration: o.duration ?? 90,
    baseRate: o.baseRate ?? 7.0,
    limitRate: o.limitRate ?? 9.0,
    rateManual: o.rateManual ?? null,   // スライダーで仮に動かした値。null なら実測の中央値
    speedup: o.speedup ?? 1,            // 録音をあとで何倍速にするか。判定話速と限界に掛かる
    samples: o.samples ?? [],           // {kind:'base'|'limit', mora, sec, note, at}
    dict: o.dict ?? {},
    blocks: (o.blocks || []).map(newBlock),
    demo: o.demo ?? false,
  };
}

export function* eachCell(proj){
  for (let bi = 0; bi < proj.blocks.length; bi++) {
    const b = proj.blocks[bi];
    if (b.kind === "SILENT") continue;
    let t = b.t;
    for (let ci = 0; ci < b.cells.length; ci++) {
      const c = b.cells[ci];
      yield { b, bi, c, ci, t, end: t + (+c.dur || 0) };
      t += (+c.dur || 0);
    }
  }
}

export function sortBlocks(proj){
  proj.blocks.sort((a, b) => a.t - b.t || a.lane - b.lane);
}

export function projectEnd(proj){
  let e = 0;
  for (const b of proj.blocks) e = Math.max(e, b.t + blockDur(b));
  return Math.max(e, proj.duration || 0);
}

/* ---------------- 話速（D3：設定値ではなく実測値の集まり） ---------------- */

export function median(xs){
  if (!xs.length) return null;
  const a = [...xs].sort((p, q) => p - q), m = a.length >> 1;
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}
/** 記録1件の話速。外で測った値は rate をそのまま持つ */
export const sampleRate = s => s.rate > 0 ? s.rate : (s.sec > 0 ? s.mora / s.sec : null);
export function measuredRate(proj, kind = "base"){
  const rs = proj.samples.filter(s => s.kind === kind).map(sampleRate).filter(r => r > 0);
  return median(rs);
}
/** 倍速を掛ける前の基準話速。手で動かしていればその値、なければ実測の中央値、それも無ければ仮値 */
export function baseRateOf(proj){
  if (proj.rateManual != null) return proj.rateManual;
  return measuredRate(proj, "base") ?? proj.baseRate;
}
export const speedupOf = proj => (proj.speedup > 0 ? proj.speedup : 1);
/** 実際に判定に使う話速 ＝ 基準 × 倍速。録音を 1.1 倍にするなら、入る量も 1.1 倍になる */
export const effectiveRate  = proj => baseRateOf(proj) * speedupOf(proj);
export const effectiveLimit = proj => (measuredRate(proj, "limit") ?? proj.limitRate) * speedupOf(proj);

/* ---------------- 判定 ---------------- */
export function judgeCell(cell, dict, rate){
  const { mora, exact } = cellMora(cell, dict);
  const dur = +cell.dur || 0;
  const cap = dur * rate;
  const req = dur > 0 ? mora / dur : Infinity;
  return { mora, exact, dur, cap, req, over: mora > cap, delta: mora - cap };
}
export function countReds(proj, rate){
  let n = 0;
  for (const { c } of eachCell(proj)) if (judgeCell(c, proj.dict, rate).over) n++;
  return n;
}

/* ---------------- 時刻 ---------------- */
export const tc = s => {
  s = Math.max(0, s || 0);
  const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = Math.floor(s % 60);
  return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(x).padStart(2, "0");
};
export const tcms = s => tc(s) + "." + String(Math.floor((Math.max(0, s || 0) % 1) * 10));

/* ---------------- SRT / VTT ---------------- */
const toSec = t => {
  const m = String(t).trim().match(/(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})/);
  if (!m) return null;
  return (+(m[1] || 0)) * 3600 + (+m[2]) * 60 + (+m[3]) + (+m[4]) / (m[4].length === 2 ? 100 : 1000);
};
const srtTime = s => {
  s = Math.max(0, s);
  const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = Math.floor(s % 60);
  const ms = Math.round((s % 1) * 1000);
  return [h, m, x].map(n => String(n).padStart(2, "0")).join(":") + "," + String(ms).padStart(3, "0");
};

/** SRT / VTT を字幕キューの配列にする */
export function parseCues(text){
  const out = [];
  const body = String(text).replace(/\r/g, "").replace(/^WEBVTT[^\n]*\n/, "");
  for (const chunk of body.split(/\n{2,}/)) {
    const lines = chunk.split("\n").filter(l => l.trim() !== "");
    if (!lines.length) continue;
    let i = 0;
    if (/^\d+$/.test(lines[0].trim())) i = 1;
    const tl = lines[i] || "";
    if (!tl.includes("-->")) continue;
    const [a, b] = tl.split("-->");
    const t0 = toSec(a), t1 = toSec(b);
    if (t0 == null || t1 == null) continue;
    const txt = lines.slice(i + 1).join(" ").replace(/<[^>]+>/g, "").trim();
    out.push({ t0, t1, text: txt });
  }
  return out.sort((p, q) => p.t0 - q.t0);
}

/** キューを「無音閾値」でブロックに束ねる（4節：1本動かすと全境界が切り直る）
    セルの持ち時間は「前のセルの終わりから自分の終わりまで」。息継ぎの間も持ち時間に入る */
export function cuesToBlocks(cues, { gap = 0.7, lane = 0, kind = "LIP" } = {}){
  const groups = [];
  let cur = null;
  for (const q of cues) {
    if (!cur || q.t0 - cur.end > gap) { cur = { t: q.t0, end: q.t0, cues: [] }; groups.push(cur) }
    cur.cues.push(q);
    cur.end = Math.max(cur.end, q.t1);
  }
  return groups.map(g => {
    let prev = g.t;
    const cells = g.cues.map(q => {
      const c = newCell({ dur: Math.max(.1, +(q.t1 - prev).toFixed(2)), en: q.text });
      prev = q.t1;
      return c;
    });
    return newBlock({ lane, kind, t: +g.t.toFixed(2), cells });
  });
}

export function toSRT(proj, { field = "ja" } = {}){
  let n = 0, out = [];
  for (const { c, t } of eachCell(proj)) {
    const txt = (field === "ja" ? c.ja : c.en || "").trim();
    if (!txt) continue;
    n++;
    out.push(n + "\n" + srtTime(t) + " --> " + srtTime(t + (+c.dur || 0)) + "\n" + txt + "\n");
  }
  return out.join("\n");
}

/* ---------------- 保存 ---------------- */
const KEY = "dub.palette.project.v1";
export function saveLocal(proj){
  try { localStorage.setItem(KEY, JSON.stringify(proj)); return true } catch { return false }
}
export function loadLocal(){
  try {
    const s = localStorage.getItem(KEY);
    return s ? newProject(JSON.parse(s)) : null;
  } catch { return null }
}
export function clearLocal(){ try { localStorage.removeItem(KEY) } catch {} }

export function download(name, text, mime = "application/json"){
  const a = document.createElement("a");
  const url = URL.createObjectURL(new Blob([text], { type: mime + ";charset=utf-8" }));
  a.href = url; a.download = name; document.body.appendChild(a); a.click();
  a.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
