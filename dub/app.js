/* ============================================================
   app.js — 状態と配線
   ============================================================ */
import * as C from "./core.js";
import { renderSheet, renderMini, renderPlane, blockInfo, metaHTML, laneRedCount, pinBalanceHTML, pinFlowHTML, sectionAt, jaHTML } from "./view.js";
import { SAMPLE } from "./sample.js";
import * as AU from "./audio.js";

const $  = id => document.getElementById(id);
const $$ = q => Array.from(document.querySelectorAll(q));

/* ---------------- 状態 ---------------- */
const S = {
  proj: null,
  rate: 7, limit: 9,
  show: [true, true, true],
  onlyRed: false, flow: false, plane: false,
  sel: null, curBlock: null, selCell: null,
  t: 0, playing: false, speed: 1, loop: false, orig: true,
  frames: Object.create(null),
  kanaOpen: new Set(),
  hasMedia: false,
  recs: new Map(),      // 本番の録音の音（name → rec）。JSON には入らない
  wav: null,          // 本番の録音：{ name, format, sampleRate, duration, A:{env,rms}, segs }
  takes: null,        // ブロックID → { slot, span, take, over }
};
const player = new AU.MultiPlayer();
window.dub = { S, player };   // 外から触る口（自動化・確認用）

const media = $("media"), grabber = $("grabber"), canvas = $("canvas");

/* ---------------- 起動 ---------------- */
function boot(){
  S.proj = C.loadLocal() || C.newProject(SAMPLE);
  S.show = S.proj.lanes.map(() => true);
  applyReadPrefs();
  buildLaneButtons();
  syncRate();
  render();
  frame();
  toast(S.proj.demo ? "サンプルを読み込みました（中身はダミー）" : "前回の続きを開きました");
}

/* ---------------- 描画 ---------------- */
let saveTimer = null, saveDirty = false;
function render({ save = true } = {}){
  S.rate  = C.effectiveRate(S.proj);
  S.limit = C.effectiveLimit(S.proj);
  S.J     = C.judgeAll(S.proj, S.rate);
  computeTakes();
  if (S.plane) renderPlane(S); else renderSheet(S);
  renderMini(S);
  syncToolbar();
  observeFilms();
  observeWaves();
  if (save) queueSave();
}
function queueSave(){
  saveDirty = true;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, 400);
}
function flushSave(){
  if (!saveDirty) return;
  clearTimeout(saveTimer); saveDirty = false;
  C.saveLocal(S.proj);
  $("fSaved").textContent = "自動保存 " + new Date().toLocaleTimeString("ja-JP");
  scheduleDirWrite();
}
// 閉じる・隠れるときは待たずに書く。数百ミリ秒の取りこぼしで原稿を失わせない
addEventListener("pagehide", flushSave);
addEventListener("beforeunload", flushSave);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushSave();
});

function syncToolbar(){
  let n = 0; for (const v of S.J.cells.values()) if (v.red) n++;
  const so = S.J.sections.filter(s => s.over).length;
  let to = 0; if (S.takes) for (const [, tk] of S.takes) if (tk.over) to++;
  const t = $("tally");
  t.textContent = "赤 " + n + (so ? "　区間 " + so : "") + (to ? "　録音 " + to : "");
  t.classList.toggle("zero", n === 0 && so === 0 && to === 0);
  $("prevred").disabled = $("nextred").disabled = n === 0;
  $("dur").textContent = C.tc(C.projectEnd(S.proj));
  const base = C.baseRateOf(S.proj), sp = C.speedupOf(S.proj);
  $("rateval").textContent = base.toFixed(1) + " /秒";
  $("rate").value = String(Math.min(12, Math.max(4, base)));
  $("speedup").value = String(sp);
  $("rateeff").hidden = sp === 1;
  $("rateeff").textContent = "→ " + S.rate.toFixed(1) + " /秒";

  const med = C.measuredRate(S.proj, "base");
  const nb = S.proj.samples.filter(s => s.kind === "base").length;
  $("ratesrc").textContent =
    S.proj.rateManual != null ? "手で動かした仮値" + (med ? "（実測 " + med.toFixed(1) + "）" : "")
    : med ? "実測 " + nb + "件の中央値"
    : "未測定の仮値";
  $("viewmode").textContent = S.flow ? "列" : "流し";
  $("viewmode").setAttribute("aria-pressed", String(S.flow));
  $("planebtn").setAttribute("aria-pressed", String(S.plane));
  $("sheet").hidden = S.plane;
  $("plane").hidden = !S.plane;
  $("fTitle").value = S.proj.title;
}

function syncRate(){
  S.rate = C.effectiveRate(S.proj);
  S.limit = C.effectiveLimit(S.proj);
  S.J = C.judgeAll(S.proj, S.rate);
  computeTakes();
}

/* ---------------- 本番の録音：枠に収まっているか ----------------
   発声区間は「いちばん重なりの大きい枠」1つに帰属させる（隣で二重に数えない）。
   はみ出しの判定は、ピンで囲んだ区間の中ならその区間の幅、外なら枠そのもの */
function computeTakes(){
  S.takes = null;
  if (!S.wav) return;
  const slots = [];
  for (const b of S.proj.blocks) {
    if (b.kind === "SILENT") continue;
    const d = C.blockDur(b);
    slots.push({ b, s0: b.t, s1: b.t + d });
  }
  const owned = new Map();                                   // blockId → [seg,...]
  for (const seg of S.wav.segs) {
    let best = null, bestOv = 0;
    for (const sl of slots) {
      const ov = Math.min(seg[1], sl.s1) - Math.max(seg[0], sl.s0);
      if (ov > bestOv) { bestOv = ov; best = sl }
    }
    if (best) (owned.get(best.b.id) || owned.set(best.b.id, []).get(best.b.id)).push(seg);
  }
  S.takes = new Map();
  for (const sl of slots) {
    const segs = owned.get(sl.b.id) || [];
    const take = segs.length ? (() => {
      const start = Math.min(...segs.map(s => s[0])), end = Math.max(...segs.map(s => s[1]));
      return { start, end, dur: end - start, lead: sl.s0 - start, tail: end - sl.s1 };
    })() : null;
    const sec = S.J.sections.find(x => x.lane === sl.b.lane && sl.b.t >= x.t0 - 1e-6 && sl.b.t < x.t1 - 1e-6);
    const span = sec ? [sec.t0, sec.t1] : [sl.s0, sl.s1];
    const over = !!(take && (take.start < span[0] - 0.05 || take.end > span[1] + 0.05));
    S.takes.set(sl.b.id, { slot: [sl.s0, sl.s1], span, take, over });
  }
}

/* ============================================================
   本番の録音：テイク（WAV 1 本）を何本でも時間軸に置く
   S.recs: name → { wav(生。ch を持つ), format, A(生の包絡), segs(生の発声・WAV 秒), out:{ wav, A, segs } }
   proj.takes: 置き方（name, offset, in, out, speed）。音そのものは JSON に入らない
   ============================================================ */
const takeMeta = name => S.proj.takes.find(t => t.name === name) || null;
const clipsOf = name => S.proj.clips.filter(c => c.take === name).sort((a, b) => a.in - b.in);
const escT = v => String(v).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

/** 新しいテイクの置き場所：まだテイクの置かれていない区間の頭。無ければ 0 */
function suggestOffset(){
  const pins = S.proj.pins || [];
  for (let i = 0; i + 1 < pins.length; i++)
    if (!S.proj.takes.some(m => Math.abs(m.offset - pins[i]) < 0.05)) return pins[i];
  return 0;
}
async function addTakeFile(f){
  const wav = AU.parseWav(await f.arrayBuffer());
  const rec = { name: f.name, wav, format: wav.format, A: AU.envelope(wav), segs: [], out: null };
  S.recs.set(f.name, rec);
  if (!takeMeta(f.name)) S.proj.takes.push(C.newTake({ name: f.name, offset: suggestOffset() }));
  detectRaw(rec); renderTake(f.name);
  return rec;
}
function detectRaw(rec){
  const r = AU.speechSegments(rec.A.rms, { thr: S.proj.recThr });
  Object.assign(rec, { segs: r.segs, thr: r.thr, floor: r.floor, loud: r.loud });
}
/** テイクの [i0,i1) を切り出し、速度で伸縮して「置く音」1 片を作る */
function renderPiece(rec, i0, i1, speed){
  const sr = rec.wav.sampleRate;
  let ch = rec.wav.ch.map(c => c.subarray(i0, i1));
  if (Math.abs(speed - 1) > 0.005) ch = ch.map(c => AU.stretch(c, sr, speed));
  const wav = { sampleRate: sr, channels: ch.length, frames: ch[0].length, duration: ch[0].length / sr, ch };
  const A = AU.envelope(wav), r = AU.speechSegments(A.rms, { thr: S.proj.recThr });
  return { wav, A, segs: r.segs };
}
/** 置く音を作り直す。割り付け（clips）があればブロックごとに、無ければテイク 1 本として */
function renderTake(name){
  const rec = S.recs.get(name), m = takeMeta(name); if (!rec || !m) return;
  const sr = rec.wav.sampleRate, fr = rec.wav.frames, idx = t => Math.min(fr, Math.max(0, Math.round(t * sr)));
  for (const id of [...player.takes.keys()]) if (id === name || id.startsWith(name + "#")) player.remove(id);
  const clips = clipsOf(name), pieces = [];
  if (clips.length) {
    for (const c of clips) {
      const i0 = idx(c.in), i1 = Math.max(i0 + 1, idx(c.out));
      const p = renderPiece(rec, i0, i1, m.speed); p.at = c.at; p.id = name + "#" + c.block; p.clip = c; pieces.push(p);
    }
  } else {
    const i0 = idx(m.in), i1 = m.out == null ? fr : Math.max(i0 + 1, idx(m.out));
    const p = renderPiece(rec, i0, i1, m.speed); p.at = m.offset; p.id = name; pieces.push(p);
  }
  for (const p of pieces) player.setTake(p.id, p.wav, p.at);
  rec.out = { pieces };
}
function livePieces(){
  const out = [];
  for (const m of S.proj.takes) { const rec = S.recs.get(m.name); if (rec && rec.out) for (const p of rec.out.pieces) out.push({ m, rec, p }) }
  return out;
}
/** 全テイクの全片を時間軸に重ねて S.wav（包絡と発声）を作り直す */
function rebuildTimeline(){
  const live = livePieces(), ids = new Set(live.map(x => x.p.id));
  for (const id of [...player.takes.keys()]) if (!ids.has(id)) player.remove(id);
  if (!live.length) { S.wav = null; $("jaon").disabled = true; }
  else {
    let end = S.proj.duration || 0;
    for (const x of live) end = Math.max(end, x.p.at + x.p.wav.duration);
    if (!S.hasMedia) S.proj.duration = end;
    const n = Math.ceil(END() / AU.BIN) + 2, env = new Float32Array(n), segs = [];
    for (const x of live) {
      const b0 = Math.round(x.p.at / AU.BIN), e = x.p.A.env;
      for (let i = 0; i < e.length && b0 + i < n; i++) if (e[i] > env[b0 + i]) env[b0 + i] = e[i];
      for (const [p, q] of x.p.segs) segs.push([p + x.p.at, q + x.p.at]);
    }
    segs.sort((p, q) => p[0] - q[0]);
    S.wav = { A: { env }, segs, count: new Set(live.map(x => x.m.name)).size };
    $("jaon").disabled = false;
  }
  render(); frame(); drawMiniWave(); syncRecUI();
}
/** JSON を読み直したあと：名前の合う音を付け直す */
function rebuildAll(){
  for (const m of S.proj.takes) if (S.recs.get(m.name)) { detectRaw(S.recs.get(m.name)); renderTake(m.name) }
  rebuildTimeline();
}
function commitTake(name, { rerender = true } = {}){
  const m = takeMeta(name);
  if (m && S.recs.get(name)) {
    if (rerender || clipsOf(name).length) renderTake(name); else player.setOffset(name, m.offset);
  }
  rebuildTimeline(); queueSave();
}

/* ---------------- ブロックへの割り付け ----------------
   テイクの発声（息継ぎで切れた束）を、区間の中のブロックへ順番に割り付ける。
   音声認識はしない。原稿のモーラ比で「各ブロックが使うはずの発声時間」を決め、
   発声の束をその比にいちばん近くなるように連続した組に分ける（動的計画法）。
   各組は自分のブロックの枠の頭に置く。ずれは表の ◁ ▷ で直す */
function blocksForTake(m){
  const pins = S.proj.pins || [], rec = S.recs.get(m.name);
  const rawLen = ((m.out == null ? (rec ? rec.wav.duration : 0) : m.out) - m.in) / m.speed;
  let t1 = m.offset + rawLen + 1;
  const pi = pins.findIndex(p => Math.abs(p - m.offset) < 0.05);
  if (pi >= 0 && pi + 1 < pins.length) t1 = pins[pi + 1];
  return S.proj.blocks
    .filter(b => b.kind !== "SILENT" && b.t >= m.offset - 0.05 && b.t < t1 - 1e-6 && (m.lane == null || b.lane === m.lane))
    .sort((a, b) => a.t - b.t);
}
function autoAlign(name){
  const m = takeMeta(name), rec = S.recs.get(name); if (!m || !rec) return null;
  const blocks = blocksForTake(m);
  if (!blocks.length) { toast("開始位置から先の区間にブロックが無い（開始位置とレーンを確かめる）"); return null }
  const inT = m.in, outT = m.out == null ? rec.wav.duration : m.out;
  let segs = [];
  for (const offN of [50, 24, 12]) {                     // 束が足りなければ、息継ぎの粘りを短くして細かく切る
    const r = AU.speechSegments(rec.A.rms, { thr: S.proj.recThr, offN });
    segs = r.segs.filter(([a, b]) => b > inT && a < outT).map(([a, b]) => [Math.max(a, inT), Math.min(b, outT)]);
    if (segs.length >= blocks.length) break;
  }
  if (!segs.length) { toast("発声が見つからない。しきい値を下げてみる"); return null }
  const mora = blocks.map(b => Math.max(1, b.cells.reduce((s, c) => s + C.cellMora(c, S.proj.dict).mora, 0)));
  const total = segs.reduce((s, [a, b]) => s + (b - a), 0), sumM = mora.reduce((a, b) => a + b, 0);
  const want = mora.map(x => total * x / sumM);
  const n = blocks.length, k = segs.length, allowEmpty = k < n;
  const pre = [0]; for (const [a, b] of segs) pre.push(pre[pre.length - 1] + (b - a));
  const INF = 1e18;
  const cost = Array.from({ length: n + 1 }, () => new Float64Array(k + 1).fill(INF));
  const from = Array.from({ length: n + 1 }, () => new Int32Array(k + 1));
  cost[0][0] = 0;
  for (let j = 1; j <= n; j++) for (let e = 0; e <= k; e++) for (let st = 0; st <= e; st++) {
    if (st === e && !allowEmpty) continue;
    if (cost[j - 1][st] >= INF) continue;
    const c = cost[j - 1][st] + ((pre[e] - pre[st]) - want[j - 1]) ** 2;
    if (c < cost[j][e]) { cost[j][e] = c; from[j][e] = st }
  }
  const bounds = new Array(n + 1); bounds[n] = k;
  for (let j = n; j >= 1; j--) bounds[j - 1] = from[j][bounds[j]];
  const clips = [];
  for (let j = 0; j < n; j++) {
    const st = bounds[j], e = bounds[j + 1]; if (e <= st) continue;
    clips.push(C.newClip({ take: name, block: blocks[j].id, in: Math.max(inT, segs[st][0] - 0.05), out: Math.min(outT, segs[e - 1][1] + 0.05), at: blocks[j].t }));
  }
  for (let j = 1; j < clips.length; j++) if (clips[j].in < clips[j - 1].out) { const mid = (clips[j].in + clips[j - 1].out) / 2; clips[j - 1].out = mid; clips[j].in = mid }
  S.proj.clips = S.proj.clips.filter(c => c.take !== name).concat(clips);
  return { clips: clips.length, blocks: n, segs: k };
}

function syncRecUI(){
  const w = S.wav, takes = S.proj.takes;
  const nClips = S.proj.clips.length;
  $("wavhint").textContent = (w ? `録音 ${w.count} 本　発声 ${w.segs.length}` : takes.length ? `録音 ${takes.length} 本（未読込）` : "録音なし") + (nClips ? `　割り付け ${nClips}` : "");
  const manual = S.proj.recThr > 0, first = [...S.recs.values()][0];
  const thrShown = manual ? S.proj.recThr : (first ? first.thr : 0.01);
  $("recThr").value = Math.round(AU.dB(thrShown));
  $("recThrVal").textContent = (manual ? "" : "自動 ") + `${Math.round(AU.dB(thrShown))} dBFS`;
  $("recAuto").hidden = !manual;
  $("recFromDir").hidden = !(DIR.handle && takes.some(m => !S.recs.get(m.name)));
  if (!w) {
    $("recDiag").textContent = takes.length
      ? "テイクの音がまだ読まれていない。「録音を足す…」で同じ名前の WAV を読むか、書き出し先フォルダに置いて「フォルダから読む」"
      : "録音なし。テイク（区間ごとに録った WAV）を何本でも足せる。音は触らず、置き方だけを JSON に残す。";
  } else {
    const onSlot = S.takes ? [...S.takes.values()].filter(t => t.take).length : 0, nSlot = S.takes ? S.takes.size : 0;
    $("recDiag").textContent = `発声 ${w.segs.length} 箇所、${nSlot} 枠のうち ${onSlot} 枠に録音が載った` +
      (w.segs.length === 0 ? "。何も拾えていない。しきい値を下げてみる" : onSlot === 0 ? "。どの枠にも載っていない。開始位置がずれている" : "");
  }
  renderTakeList();
}
function renderTakeList(){
  const box = $("takes"), pins = S.proj.pins || [];
  const secOpts = pins.slice(0, -1).map((p, i) => `<option value="${p}">区間 ${i + 1}　${C.tc(p)}–${C.tc(pins[i + 1])}</option>`).join("");
  const laneOpts = S.proj.lanes.map((n, i) => `<option value="${i}">${escT(n)}</option>`).join("");
  box.innerHTML = S.proj.takes.map(m => {
    const rec = S.recs.get(m.name), clips = clipsOf(m.name);
    const info = rec
      ? `${rec.format} ${rec.wav.sampleRate}Hz ${rec.wav.channels}ch ${C.tc(rec.wav.duration)}　発声 ${rec.segs.length}` + (clips.length ? `　割り付け ${clips.length} ブロック` : "")
      : "";
    return `<div class="take" data-take="${escT(m.name)}">
      <div class="trow"><b class="tname">${escT(m.name)}</b><span class="hint">${info}</span>${rec ? "" : `<span class="hint miss">未読込</span>`}<span style="flex:1"></span><button class="tg tdel">外す</button></div>
      ${rec ? `<canvas class="tstrip" width="800" height="56" title="取っ手をつかんで入り／出を動かす"></canvas>` : ""}
      <div class="trow">
        <label>入り</label><input type="text" class="tin" value="${tcTenth(m.in)}">
        <button class="tg thead" ${rec ? "" : "disabled"} title="最初の発声の直前まで入りを進める">頭の沈黙を切る</button>
        <label>出</label><input type="text" class="tout" value="${m.out == null ? "" : tcTenth(m.out)}" placeholder="末尾">
        <label>速度</label><input type="range" class="tspd" min="1" max="1.4" step="0.01" value="${m.speed}"><span class="tspdv">${m.speed.toFixed(2)}×</span>
      </div>
      <div class="trow">
        <label>開始位置</label><input type="text" class="toff" value="${tcTenth(m.offset)}">
        <select class="tsec"><option value="">区間の頭に…</option>${secOpts}</select>
        <button class="tg tsel">選んだブロックの頭に</button>
        <label>レーン</label><select class="tlane"><option value="">全部</option>${laneOpts}</select>
        <button class="tg talign" ${rec ? "" : "disabled"} title="発声を原稿のモーラ比でブロックに分け、それぞれ枠の頭に置く">ブロックに割り付ける</button>
        ${clips.length ? `<button class="tg tunalign">割り付けを外す</button>` : ""}
      </div>
      ${clips.length ? clipTableHTML(m, clips) : ""}
    </div>`;
  }).join("");
  for (const el of box.querySelectorAll(".take")) {
    const m = takeMeta(el.dataset.take);
    const ln = el.querySelector(".tlane"); if (ln && m) ln.value = m.lane == null ? "" : String(m.lane);
    drawStrip(el);
  }
}
function clipTableHTML(m, clips){
  const rows = clips.map(c => {
    const b = S.proj.blocks.find(x => x.id === c.block);
    if (!b) return "";
    const slot = C.blockDur(b), dur = (c.out - c.in) / m.speed, bal = slot - dur, shift = c.at - b.t;
    const head = C.plainJa(b.cells[0] && (b.cells[0].ja || b.cells[0].en) || "").replace(/\s+/g, " ").slice(0, 22);
    return `<tr data-clip="${escT(c.block)}">
      <td class="num">${C.tc(b.t)}</td><td>${escT(S.proj.lanes[b.lane] || "")}</td><td class="head">${escT(head)}</td>
      <td class="num">${dur.toFixed(1)}</td><td class="num">${slot.toFixed(1)}</td>
      <td class="num${bal < -0.05 ? " bad" : ""}">${bal >= 0 ? "+" : ""}${bal.toFixed(1)}</td>
      <td class="num">${Math.abs(shift) < 0.005 ? "0" : (shift > 0 ? "+" : "") + shift.toFixed(1)}</td>
      <td><button class="tg cnudge" data-d="-0.1" title="0.1 秒前へ">◁</button> <button class="tg cnudge" data-d="0.1" title="0.1 秒後ろへ">▷</button> <button class="tg csnap" title="枠の頭に戻す">枠の頭</button> <button class="tg cplay" title="この片を聴く">▶</button></td>
    </tr>`;
  }).join("");
  return `<table class="clips"><tr><th>枠</th><th>レーン</th><th>原稿</th><th>録音 秒</th><th>枠 秒</th><th>±</th><th>ずらし</th><th></th></tr>${rows}</table>`;
}
function drawStrip(el){
  const m = takeMeta(el.dataset.take), rec = S.recs.get(el.dataset.take), cv = el.querySelector(".tstrip");
  if (!m || !rec || !cv) return;
  cv.width = cv.clientWidth || 800;
  AU.drawTakeStrip(cv, rec.A, { duration: rec.wav.duration, tin: m.in, tout: m.out, segs: rec.segs, clips: clipsOf(m.name) });
}
/** 0:52.3 のように十分の一秒まで（開始位置の欄用） */
function tcTenth(t){
  const s = Math.max(0, +t || 0), m = Math.floor(s / 60), r = s - m * 60;
  return `${m}:${r < 10 ? "0" : ""}${r.toFixed(1)}`;
}
/** "1:23.4" / "83.4" / "0:01:23" を秒に */
function parseTC(s){
  const parts = String(s).trim().split(":").map(x => x.trim()).filter(x => x !== "");
  if (!parts.length || parts.some(x => isNaN(+x))) return null;
  return parts.reduce((acc, x) => acc * 60 + +x, 0);
}
$("takes").addEventListener("click", e => {
  const el = e.target.closest(".take"); if (!el) return;
  const name = el.dataset.take, m = takeMeta(name), rec = S.recs.get(name); if (!m) return;
  if (e.target.closest(".tdel")) {
    if (!confirm(`テイク「${name}」を外す？（ファイルは消えない。置き方だけ消える）`)) return;
    S.proj.takes = S.proj.takes.filter(x => x !== m); S.proj.clips = S.proj.clips.filter(c => c.take !== name); S.recs.delete(name);
    for (const id of [...player.takes.keys()]) if (id === name || id.startsWith(name + "#")) player.remove(id);
    rebuildTimeline(); queueSave(); return;
  }
  if (e.target.closest(".thead")) {
    if (!rec || !rec.segs.length) { toast("発声が見つかっていない"); return }
    m.in = +Math.max(0, rec.segs[0][0] - 0.05).toFixed(3);
    if (m.out != null && m.out <= m.in + 0.1) m.out = null;
    commitTake(name); toast(`頭の沈黙 ${tcTenth(m.in)} を切った`); return;
  }
  if (e.target.closest(".tsel")) {
    const b = selBlock(); if (!b) { toast("先にブロックを選ぶ"); return }
    m.offset = +b.t.toFixed(3); commitTake(name, { rerender: false }); toast(`「${name}」の頭を ${C.tc(b.t)} に置いた`); return;
  }
  if (e.target.closest(".talign")) {
    const r = autoAlign(name); if (!r) return;
    commitTake(name);
    toast(`発声 ${r.segs} 束を ${r.blocks} ブロックに割り付けた` + (r.clips < r.blocks ? `（${r.blocks - r.clips} ブロックは発声が足りず空）` : "")); return;
  }
  if (e.target.closest(".tunalign")) {
    S.proj.clips = S.proj.clips.filter(c => c.take !== name); commitTake(name); toast("割り付けを外した（テイク 1 本に戻る）"); return;
  }
  const tr = e.target.closest("tr[data-clip]");
  if (tr) {
    const c = S.proj.clips.find(x => x.take === name && x.block === tr.dataset.clip); if (!c) return;
    const b = S.proj.blocks.find(x => x.id === c.block);
    if (e.target.closest(".cnudge")) { c.at = +Math.max(0, c.at + (+e.target.closest(".cnudge").dataset.d)).toFixed(3); player.setOffset(name + "#" + c.block, c.at); rebuildTimeline(); queueSave(); return }
    if (e.target.closest(".csnap") && b) { c.at = +b.t.toFixed(3); player.setOffset(name + "#" + c.block, c.at); rebuildTimeline(); queueSave(); return }
    if (e.target.closest(".cplay")) { seek(c.at); setPlay(true); return }
  }
});
$("takes").addEventListener("change", e => {
  const el = e.target.closest(".take"); if (!el) return;
  const name = el.dataset.take, m = takeMeta(name); if (!m) return;
  const t = e.target;
  if (t.classList.contains("tin") || t.classList.contains("tout") || t.classList.contains("toff")) {
    const v = t.value.trim() === "" && t.classList.contains("tout") ? null : parseTC(t.value);
    if (v === undefined || (v !== null && (isNaN(v) || v < 0))) { toast("時刻の形が読めない（1:23.4 か秒）"); renderTakeList(); return }
    if (t.classList.contains("tin")) { m.in = +v.toFixed(3); if (m.out != null && m.out <= m.in + 0.1) m.out = null; commitTake(name) }
    else if (t.classList.contains("tout")) { m.out = v == null ? null : +Math.max(m.in + 0.1, v).toFixed(3); commitTake(name) }
    else { m.offset = +v.toFixed(3); commitTake(name, { rerender: false }) }
  } else if (t.classList.contains("tlane")) {
    m.lane = t.value === "" ? null : +t.value; queueSave();
  } else if (t.classList.contains("tsec")) {
    if (t.value !== "") { m.offset = +(+t.value).toFixed(3); commitTake(name, { rerender: false }) }
  } else if (t.classList.contains("tspd")) {
    m.speed = +(+t.value).toFixed(2); commitTake(name);
    toast(m.speed === 1 ? "等速に戻した" : `「${name}」を ${m.speed.toFixed(2)}× に伸縮（ピッチはそのまま）`);
  }
});
$("takes").addEventListener("input", e => {
  if (e.target.classList.contains("tspd")) { const v = e.target.closest(".trow").querySelector(".tspdv"); if (v) v.textContent = (+e.target.value).toFixed(2) + "×" }
});
// 帯の取っ手：近い方（入り／出）をつかんで動かす
$("takes").addEventListener("pointerdown", e => {
  const cv = e.target.closest(".tstrip"); if (!cv) return;
  const el = cv.closest(".take"), name = el.dataset.take, m = takeMeta(name), rec = S.recs.get(name); if (!m || !rec) return;
  const W = cv.clientWidth || cv.width, dur = rec.wav.duration;
  const xIn = m.in / dur * W, xOut = (m.out == null ? dur : m.out) / dur * W;
  const which = Math.abs(e.offsetX - xIn) <= Math.abs(e.offsetX - xOut) ? "in" : "out";
  cv.setPointerCapture(e.pointerId);
  const move = ev => {
    const t = Math.max(0, Math.min(dur, ev.offsetX / W * dur));
    if (which === "in") m.in = +Math.min(t, (m.out == null ? dur : m.out) - 0.1).toFixed(3);
    else m.out = t >= dur - 0.05 ? null : +Math.max(t, m.in + 0.1).toFixed(3);
    drawStrip(el);
    el.querySelector(".tin").value = tcTenth(m.in);
    el.querySelector(".tout").value = m.out == null ? "" : tcTenth(m.out);
  };
  const up = () => { cv.removeEventListener("pointermove", move); cv.removeEventListener("pointerup", up); cv.removeEventListener("pointercancel", up); commitTake(name) };
  cv.addEventListener("pointermove", move); cv.addEventListener("pointerup", up); cv.addEventListener("pointercancel", up);
  move(e);
});
$("recThr").addEventListener("input", e => {
  S.proj.recThr = AU.fromDB(+e.target.value);
  redetectAll(); rebuildTimeline(); queueSave();
});
$("recAuto").addEventListener("click", () => { S.proj.recThr = null; redetectAll(); rebuildTimeline(); queueSave(); });
function redetectAll(){
  for (const rec of S.recs.values()) { detectRaw(rec); if (rec.out) for (const p of rec.out.pieces) p.segs = AU.speechSegments(p.A.rms, { thr: S.proj.recThr }).segs }
}
/** 書き出し先フォルダから、未読込のテイクを名前で読む */
async function loadTakesFromDir(ask){
  if (!DIR.handle || !S.proj.takes.some(m => !S.recs.get(m.name))) return 0;
  if (!await dirPermitted(ask)) return 0;
  let n = 0;
  for (const m of S.proj.takes) {
    if (S.recs.get(m.name)) continue;
    try { const fh = await DIR.handle.getFileHandle(m.name); await addTakeFile(await fh.getFile()); n++ } catch {}
  }
  if (n) rebuildTimeline();
  return n;
}
function openRec(){ syncRecUI(); if (!$("dlgRec").open) $("dlgRec").showModal(); }
$("recbtn").addEventListener("click", openRec);
$("fRecOpen").addEventListener("click", () => { $("dlgFile").close(); openRec(); });
$("recFromDir").addEventListener("click", async () => {
  const n = await loadTakesFromDir(true);
  toast(n ? `フォルダから ${n} 本読んだ` : "同じ名前の WAV がフォルダに無い");
});

/* 波形の帯：見えたカードから描く */
const wio = new IntersectionObserver(es => {
  for (const e of es) if (e.isIntersecting) drawWaveFor(e.target.dataset.wave);
}, { rootMargin: "400px 0px" });
function observeWaves(){
  wio.disconnect();
  if (!S.wav) return;
  $$("canvas.wave[data-wave]").forEach(el => wio.observe(el));
}
function drawWaveFor(id){
  const b = S.proj.blocks.find(x => x.id === id), tk = S.takes && S.takes.get(id);
  const canvas = document.querySelector(`canvas.wave[data-wave="${id}"]`);
  if (!b || !tk || !canvas) return;
  const [s0, s1] = tk.slot, m = Math.max(0.3, (s1 - s0) * 0.08);
  let t = b.t; const ticks = [];
  b.cells.slice(0, -1).forEach(c => { t += +c.dur || 0; ticks.push(t) });
  AU.drawWave(canvas, S.wav.A, { t0: s0 - m, t1: s1 + m, slot: tk.slot, take: tk.take, ticks, red: tk.over });
  const meta = document.querySelector(`.wmeta[data-wmeta="${id}"]`);
  if (meta) {
    const tkk = tk.take;
    meta.textContent = !tkk ? "録音なし"
      : `録音 ${tkk.dur.toFixed(1)}秒 ／ 枠 ${(s1 - s0).toFixed(1)}秒` +
        (tk.over ? "　はみ出し" + (tkk.lead > 0.05 ? ` 前 ${tkk.lead.toFixed(1)}` : "") + (tkk.tail > 0.05 ? ` 後 ${tkk.tail.toFixed(1)}` : "")
                 : `　余り ${Math.max(0, (s1 - s0) - tkk.dur).toFixed(1)}`);
    meta.classList.toggle("bad", tk.over);
  }
}
window.dub.drawWaves = () => $$("canvas.wave[data-wave]").forEach(el => drawWaveFor(el.dataset.wave));

function drawMiniWave(){
  const cv = $("mwave"); if (!S.wav || cv.hidden) return;
  const W = cv.clientWidth || 300; cv.width = W;
  const g = cv.getContext("2d"), H = cv.height, end = END() || 1;
  g.clearRect(0, 0, W, H);
  const A = S.wav.A, perPx = (end / AU.BIN) / W;
  g.fillStyle = "#5a6167";
  for (let x = 0; x < W; x++) {
    const a = Math.floor(x * perPx), b = Math.floor((x + 1) * perPx);
    let mx = 0; for (let i = a; i < b && i < A.env.length; i++) if (A.env[i] > mx) mx = A.env[i];
    const h = Math.max(1, mx * (H - 2));
    g.fillRect(x, H / 2 - h / 2, 1, h);
  }
}

function buildLaneButtons(){
  $("lanes").innerHTML = S.proj.lanes.map((n, i) =>
    `<button class="tg" data-lane="${i}" aria-pressed="${S.show[i]}">${n}</button>`).join("");
}

/* ---------------- 再生 ---------------- */
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const END = () => C.projectEnd(S.proj);

function blockAt(x){
  for (const b of S.proj.blocks) {
    const d = C.blockDur(b);
    if (x >= b.t && x < b.t + d) return b;
  }
  return null;
}
function selBlock(){ return S.proj.blocks.find(b => b.id === S.sel) || null }

function seek(x){
  S.t = Math.max(0, Math.min(END(), x));
  if (S.hasMedia) media.currentTime = S.t;
  if (S.wav) player.seek(S.t);
  frame();
}
function setPlay(v){
  S.playing = v;
  $("play").textContent = v ? "❚❚" : "▶";
  $("play").setAttribute("aria-label", v ? "停止" : "再生");
  if (S.hasMedia) { v ? media.play().catch(() => {}) : media.pause(); }
  if (S.wav) { v ? player.play(S.t) : player.stop(); }
  if (v) { rafLast = performance.now(); requestAnimationFrame(tick); }
}
let rafLast = 0, lastSync = 0;
function tick(now){
  if (!S.playing) return;
  const dt = (now - rafLast) / 1000; rafLast = now;
  if (S.hasMedia) {
    S.t = media.currentTime;
    // 映像が時計。録音がずれてきたら合わせ直す
    if (S.wav && player.playing && now - lastSync > 1500) {
      lastSync = now;
      if (Math.abs(player.now() - S.t) > 0.08) player.play(S.t);
    }
  } else if (S.wav && player.playing) {
    S.t = player.now();
  } else if (S.wav && !player.playing) {
    setPlay(false); frame(); return;          // 録音が終わった
  } else S.t += dt * S.speed;

  const b = S.loop ? selBlock() : null;
  if (b) {
    const e = b.t + C.blockDur(b);
    if (S.t >= e || S.t < b.t - 0.05) seek(b.t);
  } else if (S.t >= END()) {
    S.hasMedia ? setPlay(false) : (S.t = 0);
  }
  frame();
  requestAnimationFrame(tick);
}
function frame(){
  const end = END() || 1;
  $("now").textContent = C.tc(S.t);
  const p = Math.max(0, Math.min(1, S.t / end)) * 100;
  $("mhead").style.left = p + "%";
  $("mini").setAttribute("aria-valuenow", String(Math.round(S.t)));
  $("mini").setAttribute("aria-valuetext", C.tc(S.t));

  const b = blockAt(S.t), id = b ? b.id : null;
  if (id !== S.curBlock) {
    const prev = S.curBlock; S.curBlock = id;
    if (prev) document.querySelector(`.card[data-b="${prev}"]`)?.classList.remove("playing");
    if (id) {
      const el = document.querySelector(`.card[data-b="${id}"]`);
      el?.classList.add("playing");
      if (S.playing && el && !S.plane)
        el.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
    }
    renderMini(S);
  }
}

/* ---------------- 赤へ飛ぶ ---------------- */
function redTimes(){
  return [...S.J.cells.values()].filter(v => v.red).map(v => ({ t: v.t, b: v.b })).sort((a, b) => a.t - b.t);
}
function jumpRed(dir){
  const r = redTimes();
  if (!r.length) return;
  let target = dir > 0
    ? r.find(x => x.t > S.t + 0.05) || r[0]
    : [...r].reverse().find(x => x.t < S.t - 0.05) || r[r.length - 1];
  if (S.plane) { S.plane = false; render({ save: false }) }
  S.sel = target.b.id;
  render({ save: false });
  seek(target.t);
  const el = document.querySelector(`.card[data-b="${target.b.id}"]`);
  el?.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
  const i = r.findIndex(x => x === target);
  toast(`赤 ${i + 1} / ${r.length}　${C.tc(target.t)}`);
}

/* ---------------- コマ撮り（見えたところから順に取る） ---------------- */
let grabQ = [], grabbing = false;
const io = new IntersectionObserver(es => {
  for (const e of es) if (e.isIntersecting) {
    const id = e.target.closest("[data-b]")?.dataset.b;
    if (id && !S.frames[id] && !grabQ.includes(id)) { grabQ.push(id); pump() }
  }
}, { rootMargin: "500px 0px" });

function observeFilms(){
  io.disconnect();
  if (!S.hasMedia) return;
  $$(".film.empty").forEach(el => io.observe(el));
}
async function pump(){
  if (grabbing || !S.hasMedia) return;
  grabbing = true;
  while (grabQ.length) {
    const id = grabQ.shift();
    if (S.frames[id]) continue;
    const b = S.proj.blocks.find(x => x.id === id);
    if (!b) continue;
    try { S.frames[id] = await grabAt(b.t + 0.08) } catch { S.frames[id] = null }
    const film = document.querySelector(`.card[data-b="${id}"] .film`);
    if (film && S.frames[id]) {
      film.classList.remove("empty");
      film.querySelector("span")?.remove();
      const img = document.createElement("img");
      img.src = S.frames[id]; img.alt = "";
      film.prepend(img);
    }
  }
  grabbing = false;
}
function grabAt(t){
  return new Promise((res, rej) => {
    if (!grabber.src || !grabber.videoWidth && grabber.readyState < 2) return rej();
    const done = () => {
      grabber.removeEventListener("seeked", done);
      try {
        const g = canvas.getContext("2d");
        const vw = grabber.videoWidth, vh = grabber.videoHeight;
        if (!vw) return rej();
        canvas.height = Math.round(320 * vh / vw);
        g.drawImage(grabber, 0, 0, canvas.width, canvas.height);
        res(canvas.toDataURL("image/jpeg", 0.62));
      } catch (e) { rej(e) }
    };
    grabber.addEventListener("seeked", done, { once: true });
    grabber.currentTime = Math.min(t, Math.max(0, (grabber.duration || t) - 0.05));
    setTimeout(() => rej(), 3000);
  });
}

/* ---------------- トースト ---------------- */
let toastT = null;
function toast(msg){
  const el = $("toast");
  el.textContent = msg; el.classList.add("on");
  clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove("on"), 2200);
}

/* ============================================================
   配線
   ============================================================ */

/* --- 再生バー --- */
$("play").addEventListener("click", () => setPlay(!S.playing));
$("mini").addEventListener("pointerdown", e => {
  const move = ev => {
    const r = $("mtrack").getBoundingClientRect();
    seek((ev.clientX - r.left) / r.width * END());
  };
  move(e);
  const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up) };
  addEventListener("pointermove", move); addEventListener("pointerup", up);
});
$("mini").addEventListener("keydown", e => {
  if (e.key === "ArrowRight") { seek(S.t + 1); e.preventDefault() }
  if (e.key === "ArrowLeft")  { seek(S.t - 1); e.preventDefault() }
});
$("loop").addEventListener("click", e => {
  S.loop = !S.loop; e.currentTarget.setAttribute("aria-pressed", String(S.loop));
  if (S.loop && !S.sel) toast("ループするブロックをカードで選んでください");
});
$("orig").addEventListener("click", e => {
  S.orig = !S.orig; e.currentTarget.setAttribute("aria-pressed", String(S.orig));
  media.volume = S.orig ? 1 : 0;
});
$("spd").addEventListener("change", e => {
  S.speed = parseFloat(e.target.value); media.playbackRate = S.speed; player.setRate(S.speed);
});
$("jaon").addEventListener("click", e => {
  const v = e.currentTarget.getAttribute("aria-pressed") !== "true";
  e.currentTarget.setAttribute("aria-pressed", String(v)); player.setOn(v);
});
$("vidwin").addEventListener("click", e => {
  const v = e.currentTarget.getAttribute("aria-pressed") !== "true";
  e.currentTarget.setAttribute("aria-pressed", String(v)); $("vwin").hidden = !v;
});
$("wavfile").addEventListener("change", async e => {
  const files = [...e.target.files]; e.target.value = ""; if (!files.length) return;
  $("wavhint").textContent = "読んでいます…";
  let n = 0;
  for (const f of files) {
    try { await addTakeFile(f); n++ }
    catch (err) { toast(`${f.name}: 読めませんでした（${err && err.message || err}）`) }
  }
  rebuildTimeline();
  if (n) { toast(`録音を ${n} 本読んだ。発声 ${S.wav ? S.wav.segs.length : 0} 箇所`); openRec(); }
});
$("mediafile").addEventListener("change", e => {
  const f = e.target.files[0]; if (!f) return;
  const url = URL.createObjectURL(f);
  media.src = url; grabber.src = url;
  S.hasMedia = true; S.frames = Object.create(null);
  media.playbackRate = S.speed; media.volume = S.orig ? 1 : 0;
  $("mediahint").textContent = f.name;
  $("vidwin").disabled = false;
  $("vidwin").setAttribute("aria-pressed", "true"); $("vwin").hidden = false;
  media.addEventListener("loadedmetadata", () => {
    if (isFinite(media.duration)) S.proj.duration = media.duration;
    render(); frame(); drawMiniWave(); toast("映像を接続しました（コマは見えたところから取り込みます）");
  }, { once: true });
});

/* --- 判定バー --- */
$("rate").addEventListener("input", e => {
  S.proj.rateManual = parseFloat(e.target.value);
  render();
});
$("speedup").addEventListener("change", e => {
  S.proj.speedup = parseFloat(e.target.value) || 1;
  render();
  toast(S.proj.speedup === 1 ? "等速で判定" : `録音を ${S.proj.speedup}× にする前提で判定`);
});
$("measure").addEventListener("click", openRate);
$("prevred").addEventListener("click", () => jumpRed(-1));
$("nextred").addEventListener("click", () => jumpRed(1));
$("onlyred").addEventListener("click", e => {
  S.onlyRed = !S.onlyRed; e.currentTarget.setAttribute("aria-pressed", String(S.onlyRed)); render({ save: false });
});
$("lanes").addEventListener("click", e => {
  const b = e.target.closest("[data-lane]"); if (!b) return;
  const i = +b.dataset.lane;
  if (S.show[i] && S.show.filter(Boolean).length === 1) return toast("最低1レーンは表示します");
  S.show[i] = !S.show[i]; b.setAttribute("aria-pressed", String(S.show[i])); render({ save: false });
});
$("viewmode").addEventListener("click", () => { S.flow = !S.flow; render({ save: false }) });
$("planebtn").addEventListener("click", () => { S.plane = !S.plane; render({ save: false }) });
$("filebtn").addEventListener("click", () => {
  $("fSaved").textContent = "";
  $("fClearLane").innerHTML = S.proj.lanes.map((n, i) => {
    const k = S.proj.blocks.filter(b => b.lane === i).length;
    return `<option value="${i}">${n}（${k}）</option>`;
  }).join("");
  $("dlgFile").showModal();
});

/* ---------------- 訳文のハイライト ----------------
   選んだ範囲を《…》で囲む。見た目は <mark>、保存は記号付きの文字列。
   選択があると小さな帯（#hlbar）が出る。⌘⇧H / Ctrl+Shift+H でも */
function serializeJa(el){
  let out = "", depth = 0;
  const walk = n => {
    for (const k of n.childNodes) {
      if (k.nodeType === 3) out += k.nodeValue;
      else if (k.nodeName === "BR") out += "\n";
      else if (k.nodeName === "MARK") { if (!depth) out += C.HL_OPEN; depth++; walk(k); depth--; if (!depth) out += C.HL_CLOSE }
      else if (k.nodeName === "DIV" || k.nodeName === "P") { if (out && !out.endsWith("\n")) out += "\n"; walk(k) }
      else walk(k);
    }
  };
  walk(el);
  return out.replace(/\n$/, "").replace(/《》/g, "");
}
const hlbar = $("hlbar"); let hlCtx = null, hlT = 0;
function hlContext(){
  const sel = document.getSelection(); if (!sel || !sel.rangeCount) return null;
  const r = sel.getRangeAt(0);
  const elOf = n => n.nodeType === 1 ? n : n.parentElement;
  const ja = elOf(r.commonAncestorContainer)?.closest(".ja"); if (!ja || !ja.dataset.b) return null;
  const m0 = elOf(r.startContainer)?.closest("mark"), m1 = elOf(r.endContainer)?.closest("mark");
  const mark = m0 && m0 === m1 && ja.contains(m0) ? m0 : null;     // 範囲が 1 つのハイライトの中に収まっている
  return { ja, range: r, collapsed: sel.isCollapsed, mark };
}
function updateHlbar(){
  const c = hlContext();
  if (!c || (c.collapsed && !c.mark)) { hlbar.hidden = true; hlCtx = null; return }
  const rect = c.mark && c.collapsed ? c.mark.getBoundingClientRect() : c.range.getBoundingClientRect();
  if (!rect.width && !rect.height) { hlbar.hidden = true; hlCtx = null; return }
  hlCtx = c;
  $("hlbtn").textContent = c.mark ? "ハイライトを外す" : "ハイライト";
  hlbar.hidden = false;
  const w = hlbar.offsetWidth, h = hlbar.offsetHeight;
  hlbar.style.left = Math.max(6, Math.min(innerWidth - w - 6, rect.left)) + "px";
  hlbar.style.top = Math.max(6, rect.top - h - 6) + "px";
}
function finishHl(ja){
  const bid = ja.dataset.b, ci = +ja.dataset.c, b = S.proj.blocks.find(x => x.id === bid); if (!b) return;
  const text = serializeJa(ja);
  b.cells[ci].ja = text; ja.innerHTML = jaHTML(text);
  repaintCell(bid, ci); queueSave();
  const sel = document.getSelection(), r = document.createRange(); r.selectNodeContents(ja); r.collapse(false);
  sel.removeAllRanges(); sel.addRange(r);
  hlbar.hidden = true; hlCtx = null;
}
function toggleHighlight(c = hlContext()){
  if (!c) return false;
  if (c.mark) { c.mark.replaceWith(...c.mark.childNodes); finishHl(c.ja); toast("ハイライトを外した"); return true }
  if (c.collapsed) return false;
  const frag = c.range.extractContents();
  frag.querySelectorAll("mark").forEach(m => m.replaceWith(...m.childNodes));
  const mk = document.createElement("mark"); mk.appendChild(frag); c.range.insertNode(mk);
  finishHl(c.ja); return true;
}
document.addEventListener("selectionchange", () => { clearTimeout(hlT); hlT = setTimeout(updateHlbar, 60) });
hlbar.addEventListener("pointerdown", e => { e.preventDefault(); if (hlCtx) toggleHighlight(hlCtx) });
addEventListener("scroll", () => { if (!hlbar.hidden) updateHlbar() }, true);

/* --- シート --- */
const sheet = $("sheet");
sheet.addEventListener("keydown", e => {
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "h" && e.target.closest(".ja")) { e.preventDefault(); toggleHighlight() }
});
sheet.addEventListener("input", e => {
  const ja = e.target.closest(".ja"), ka = e.target.closest(".kana");
  const el = ja || ka; if (!el) return;
  const bid = ja ? el.dataset.b : el.dataset.kb;
  const ci  = +(ja ? el.dataset.c : el.dataset.kc);
  const b = S.proj.blocks.find(x => x.id === bid); if (!b) return;
  if (ja) b.cells[ci].ja = serializeJa(el);
  else    b.cells[ci].kana = el.innerText.replace(/\n$/, "");
  repaintCell(bid, ci);
  queueSave();
});
sheet.addEventListener("click", e => {
  const pinAt = e.target.closest("[data-pin-at]");
  if (pinAt) { togglePinAt(+pinAt.dataset.pinAt); return }
  const pinRow = e.target.closest("[data-pin]");
  if (pinRow && !e.target.closest(".card")) { togglePinAt(+pinRow.dataset.pin); return }
  const rec = e.target.closest("[data-rec]");
  if (rec) {
    const b = S.proj.blocks.find(x => x.id === rec.dataset.rec);
    b.rec = (b.rec + 1) % 3;
    rec.dataset.state = b.rec; rec.textContent = C.REC[b.rec];
    queueSave(); return;
  }
  const kb = e.target.closest("[data-kana]");
  if (kb) {
    const key = kb.dataset.kana;
    const fld = kb.closest(".cbody").querySelector(".kana");
    const on = fld.classList.toggle("on");
    on ? S.kanaOpen.add(key) : S.kanaOpen.delete(key);
    if (on) fld.focus();
    return;
  }
  const kind = e.target.closest(".kind");
  if (kind) { openBlock(kind.closest("[data-b]").dataset.b); return }
  if (e.target.closest(".ja") || e.target.closest(".kana")) {
    const c = e.target.closest("[data-b]");
    if (c) S.sel = c.dataset.b;
    const cell = e.target.closest("[data-cell]");
    S.selCell = cell ? { b: S.sel, ci: +cell.dataset.cell } : null;
    $$(".card.sel").forEach(x => x.classList.remove("sel"));
    document.querySelector(`.card[data-b="${S.sel}"]`)?.classList.add("sel");
    return;
  }
  const card = e.target.closest("[data-b]"); if (!card) return;
  S.sel = card.dataset.b;
  const cell = e.target.closest("[data-cell]");
  S.selCell = cell ? { b: S.sel, ci: +cell.dataset.cell } : null;
  $$(".card.sel").forEach(x => x.classList.remove("sel"));
  card.classList.add("sel");
  const b = S.proj.blocks.find(x => x.id === S.sel);
  if (b) seek(b.t);
});
function repaintCell(){
  S.J = C.judgeAll(S.proj, S.rate);
  refreshVerdicts();
  syncToolbar(); renderMini(S);
}
/* 区間があると、1セルの編集で同じ区間の他セルの判定も変わる。
   シートは作り直さず（編集中のカーソルが飛ぶ）、印だけ全部貼り直す */
function refreshVerdicts(){
  for (const card of $$(".card[data-b]")) {
    const b = S.proj.blocks.find(x => x.id === card.dataset.b); if (!b) continue;
    const info = blockInfo(S, b);
    card.classList.toggle("over", info.over);
    card.querySelectorAll("[data-cell]").forEach(cell => {
      const j = info.cells[+cell.dataset.cell]; if (!j) return;
      cell.classList.toggle("bad", j.red);
      const meta = cell.querySelector(".meta");
      if (meta) meta.innerHTML = metaHTML(j) + `<button class="kanabtn" data-kana="${b.id}:${cell.dataset.cell}">よみ</button>`;
    });
  }
  $$(".pincell[data-pin]").forEach(el => {
    const t = +el.dataset.pin, li = +el.dataset.lane, s = sectionAt(S, t, li);
    el.classList.toggle("over", !!(s && s.over));
    el.innerHTML = pinBalanceHTML(S, t, li);
  });
  $$(".pinflow[data-pin]").forEach(el => { el.innerHTML = pinFlowHTML(S, +el.dataset.pin) });
  $$("[data-lane-head]").forEach(el => {
    const n = laneRedCount(S, +el.dataset.laneHead);
    el.textContent = n ? "赤" + n : "—"; el.classList.toggle("red", n > 0);
  });
}
function togglePinAt(t){
  const on = C.togglePin(S.proj, t);
  render();
  toast(on ? `${C.tc(t)} にピンを打ちました${S.J.pins.length === 1 ? "（もう1本でひとつの区間になります）" : ""}` : "ピンを外しました");
}

/* --- 適合平面から飛ぶ --- */
$("plane").addEventListener("click", e => {
  const tr = e.target.closest("[data-jump]");
  const pt = e.target.closest(".pt");
  let id = tr?.dataset.jump;
  if (pt && S.planePts) id = S.planePts[+pt.dataset.i]?.b.id;
  if (!id) return;
  S.plane = false; S.sel = id; render({ save: false });
  const b = S.proj.blocks.find(x => x.id === id);
  if (b) seek(b.t);
  document.querySelector(`.card[data-b="${id}"]`)
    ?.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
});

/* --- キー --- */
addEventListener("keydown", e => {
  const tag = (e.target.tagName || "").toLowerCase();
  if (e.target.isContentEditable || tag === "input" || tag === "textarea" || tag === "select") return;
  if (document.querySelector("dialog[open]")) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key.toLowerCase();
  if (e.code === "Space") { e.preventDefault(); setPlay(!S.playing) }
  else if (e.key === "]") jumpRed(1);
  else if (e.key === "[") jumpRed(-1);
  else if (k === "l") $("loop").click();
  else if (k === "o") $("orig").click();
  else if (k === "j" && !$("jaon").disabled) $("jaon").click();
  else if (k === "v" && !$("vidwin").disabled) $("vidwin").click();
  else if (k === "f") $("viewmode").click();
  else if (k === "t") openRec();
  else if (k === "r" && S.sel) {
    const b = selBlock(); b.rec = (b.rec + 1) % 3;
    const el = document.querySelector(`[data-rec="${b.id}"]`);
    if (el) { el.dataset.state = b.rec; el.textContent = C.REC[b.rec] }
    queueSave();
  }
  else if (k === "e" && S.sel) openBlock(S.sel);
  else if (k === "p" && S.sel) { const b = selBlock(); if (b) togglePinAt(b.t) }
});

/* --- ダイアログ共通 --- */
$$("dialog").forEach(d => {
  d.addEventListener("click", e => { if (e.target.closest("[data-close]")) d.close() });
});

/* ============================================================
   話速の実測（D3）
   ============================================================ */
let rateKind = "base", swStart = 0, swTimer = null;

function openRate(){
  drawRate();
  $("dlgRate").showModal();
}
function drawRate(){
  const med = C.measuredRate(S.proj, rateKind);
  $("medval").textContent = med ? med.toFixed(1) : "—";
  const list = S.proj.samples.filter(s => s.kind === rateKind);
  $("medsrc").textContent = list.length ? list.length + " 件の中央値" : "まだ測っていない";
  $("sampleList").innerHTML = list.length ? list.map((s, i) => {
    const r = C.sampleRate(s);
    const isMed = med != null && Math.abs(r - med) < 1e-9;
    return `<li class="${isMed ? "med" : ""}"><span>${r.toFixed(2)} /秒</span>` +
      `<span style="color:var(--ctext2)">${s.rate > 0 ? "直接入力" : s.mora + "モーラ / " + s.sec.toFixed(1) + "秒"}</span>` +
      (s.note ? `<span class="tagm">${s.note}</span>` : "") +
      (isMed ? `<span class="tagm">中央値</span>` : "") +
      `<button data-del="${i}" aria-label="削除">×</button></li>`;
  }).join("") : `<li class="none">記録がありません</li>`;
  const t = $("rateText").value;
  $("rateMora").textContent = C.estimateMora(t, S.proj.dict).mora;
  const cell = curCell();
  const tk = cell && S.takes ? S.takes.get(cell.b.id) : null;
  const fromWav = tk && tk.take && cell.b.cells.length === 1 ? tk.take.dur : null;
  $("takeInfo").textContent = cell
    ? `選択中：${C.tc(cell.t)}　${C.cellMora(cell.c, S.proj.dict).mora} モーラ` + (fromWav != null ? `　録音 ${fromWav.toFixed(1)} 秒` : "")
    : "セルが選ばれていません";
  if (fromWav != null && !$("takeSec").value) $("takeSec").value = fromWav.toFixed(1);
}
function curCell(){
  if (!S.selCell) return null;
  for (const x of C.eachCell(S.proj))
    if (x.b.id === S.selCell.b && x.ci === S.selCell.ci) return x;
  return null;
}
function addSample(mora, sec, note){
  if (!(mora > 0) || !(sec > 0)) return toast("モーラ数と秒数が要ります");
  S.proj.samples.push({ kind: rateKind, mora, sec: +sec.toFixed(2), note: note || "", at: Date.now() });
  if (rateKind === "base" && S.proj.rateManual != null) S.proj.rateManual = null;
  drawRate(); syncRate(); render();
  toast("記録しました");
}
function scriptMora(){
  const fix = parseFloat($("rateMoraFix").value);
  if (fix > 0) return Math.round(fix);
  return C.estimateMora($("rateText").value, S.proj.dict).mora;
}
$("rateTabs").addEventListener("click", e => {
  const b = e.target.closest("[data-k]"); if (!b) return;
  rateKind = b.dataset.k;
  $$("#rateTabs button").forEach(x => x.setAttribute("aria-selected", String(x === b)));
  $("applyMed").textContent = rateKind === "base" ? "これを基準にする" : "これを限界にする";
  drawRate();
});
$("rateText").addEventListener("input", drawRate);
$("rateMoraFix").addEventListener("input", drawRate);
$("stopwatch").addEventListener("click", () => {
  if (swTimer) {
    clearInterval(swTimer); swTimer = null;
    const sec = (performance.now() - swStart) / 1000;
    $("stopwatch").textContent = "計測開始";
    addSample(scriptMora(), sec, "実読");
  } else {
    swStart = performance.now();
    $("stopwatch").textContent = "止める";
    swTimer = setInterval(() => {
      $("swval").innerHTML = ((performance.now() - swStart) / 1000).toFixed(1) + "<small>秒</small>";
    }, 100);
  }
});
$("addDirect").addEventListener("click", () => {
  const r = parseFloat($("directRate").value);
  if (!(r > 0)) return toast("話速（/秒）を入れてください");
  S.proj.samples.push({ kind: rateKind, rate: +r.toFixed(2), note: $("directNote").value.trim() || "直接入力", at: Date.now() });
  if (rateKind === "base" && S.proj.rateManual != null) S.proj.rateManual = null;
  $("directRate").value = ""; $("directNote").value = "";
  drawRate(); syncRate(); render(); toast("記録しました");
});
$("addManual").addEventListener("click", () => {
  addSample(scriptMora(), parseFloat($("manualSec").value), "手入力");
});
$("addTake").addEventListener("click", () => {
  const cell = curCell(); if (!cell) return toast("先にセルを選んでください");
  addSample(C.cellMora(cell.c, S.proj.dict).mora, parseFloat($("takeSec").value), "本番");
});
$("sampleList").addEventListener("click", e => {
  const b = e.target.closest("[data-del]"); if (!b) return;
  const list = S.proj.samples.filter(s => s.kind === rateKind);
  const victim = list[+b.dataset.del];
  S.proj.samples = S.proj.samples.filter(s => s !== victim);
  drawRate(); syncRate(); render();
});
$("applyMed").addEventListener("click", () => {
  const med = C.measuredRate(S.proj, rateKind);
  if (med == null) return toast("まだ記録がありません");
  if (rateKind === "base") { S.proj.rateManual = null; S.proj.baseRate = med }
  else S.proj.limitRate = med;
  syncRate(); render(); toast("実測値を反映しました");
});

/* ============================================================
   取り込み
   ============================================================ */
function openImport(){
  $("impLane").innerHTML = S.proj.lanes.map((n, i) => `<option value="${i}">${n}</option>`).join("");
  previewImport();
  $("dlgImport").showModal();
}
function previewImport(){
  const cues = C.parseCues($("impText").value);
  const gap = parseFloat($("impGap").value);
  $("impGapVal").textContent = gap.toFixed(1) + " 秒";
  if (!cues.length) { $("impStat").textContent = "—"; $("impPreview").textContent = "貼ると件数が出ます"; return }
  const blocks = C.cuesToBlocks(cues, { gap });
  $("impStat").textContent = `${cues.length} 行 → ${blocks.length} ブロック`;
  $("impPreview").textContent = `${cues.length} 行を ${blocks.length} ブロックに束ねます`;
}
$("impText").addEventListener("input", previewImport);
$("impGap").addEventListener("input", previewImport);
$("impDo").addEventListener("click", () => {
  const cues = C.parseCues($("impText").value);
  if (!cues.length) return toast("SRT / VTT を貼ってください");
  const lane = +$("impLane").value, kind = $("impKind").value;
  const gap = parseFloat($("impGap").value);
  const blocks = C.cuesToBlocks(cues, { gap, lane, kind });
  if ($("impReplace").checked) S.proj.blocks = S.proj.blocks.filter(b => b.lane !== lane);
  S.proj.blocks.push(...blocks);
  S.proj.demo = false;
  C.sortBlocks(S.proj);
  render(); toast(`${blocks.length} ブロックを取り込みました`);
});

/* ============================================================
   読み辞書
   ============================================================ */
function drawDict(){
  const d = S.proj.dict, ks = Object.keys(d);
  $("dictList").innerHTML = ks.length
    ? ks.sort((a, b) => b.length - a.length).map(k =>
        `<li><span>${k}</span><span>${d[k]}</span>` +
        `<span style="font-family:var(--mono);color:var(--ctext2)">${C.moraFromKana(d[k])}</span>` +
        `<button data-dk="${encodeURIComponent(k)}" aria-label="削除">×</button></li>`).join("")
    : `<li style="color:var(--ctext2);border:0">まだありません</li>`;
}
$("dictAdd").addEventListener("click", () => {
  const w = $("dictWord").value.trim(), k = $("dictKana").value.trim();
  if (!w || !k) return toast("語とよみの両方が要ります");
  S.proj.dict[w] = k;
  $("dictWord").value = $("dictKana").value = "";
  drawDict(); render();
});
$("dictList").addEventListener("click", e => {
  const b = e.target.closest("[data-dk]"); if (!b) return;
  delete S.proj.dict[decodeURIComponent(b.dataset.dk)];
  drawDict(); render();
});

/* ============================================================
   ブロック編集
   ============================================================ */
let editing = null;
function openBlock(id){
  const b = S.proj.blocks.find(x => x.id === id); if (!b) return;
  editing = id;
  drawBlock();
  $("dlgBlock").showModal();
}
function drawBlock(){
  const b = S.proj.blocks.find(x => x.id === editing); if (!b) return;
  const laneOpts = S.proj.lanes.map((n, i) =>
    `<option value="${i}" ${i === b.lane ? "selected" : ""}>${n}</option>`).join("");
  const kindOpts = Object.entries(C.KINDS).map(([k, v]) =>
    `<option value="${k}" ${k === b.kind ? "selected" : ""}>${v}</option>`).join("");
  let h = `<div class="row">
      <label>レーン</label><select id="bkLane">${laneOpts}</select>
      <label style="min-width:0">種別</label><select id="bkKind">${kindOpts}</select>
      <label style="min-width:0">開始</label>
      <input type="number" id="bkT" step="0.1" min="0" value="${b.t}" style="width:88px"> 秒
    </div>`;
  if (b.kind === "SILENT") {
    h += `<div class="row"><label>長さ</label>
      <input type="number" id="bkDur" step="0.1" min="0" value="${C.blockDur(b)}" style="width:88px"> 秒
      <span class="hint">クリップ区間は触れない空白。跨げない</span></div>`;
  } else {
    h += `<h3>セル（息継ぎで割った最小単位）</h3>
      <p class="note">口合わせは原音の息継ぎごとに割れる。セルごとに秒数が決まっている。</p>`;
    h += b.cells.map((c, i) =>
      `<div class="row" data-ci="${i}">
        <span style="font-family:var(--mono);color:var(--ctext2);min-width:18px">${i + 1}</span>
        <input type="number" class="bkCd" step="0.1" min="0.1" value="${c.dur}" style="width:76px"> 秒
        <input type="text" class="bkCe" value="${(c.en || "").replace(/"/g, "&quot;")}" placeholder="原文" style="flex:1;min-width:120px">
        <button class="tg" data-splitc="${i}" title="このセルを2つに割る">割る</button>
        <button class="tg" data-delc="${i}" ${b.cells.length < 2 ? "disabled" : ""}>×</button>
      </div>`).join("");
    h += `<div class="row"><button class="tg" id="bkAddCell">セルを足す</button>
      <span class="hint">合計 ${C.blockDur(b).toFixed(1)} 秒</span></div>`;
  }
  $("blockBody").innerHTML = h;
}
$("blockBody").addEventListener("change", e => {
  const b = S.proj.blocks.find(x => x.id === editing); if (!b) return;
  const id = e.target.id;
  if (id === "bkLane") b.lane = +e.target.value;
  if (id === "bkKind") { b.kind = e.target.value; if (b.kind === "SILENT") b.dur = C.blockDur(b) || 4; drawBlock() }
  if (id === "bkT") { b.t = +e.target.value; C.sortBlocks(S.proj) }
  if (id === "bkDur") b.dur = +e.target.value;
  if (e.target.classList.contains("bkCd")) b.cells[+e.target.closest("[data-ci]").dataset.ci].dur = +e.target.value;
  if (e.target.classList.contains("bkCe")) b.cells[+e.target.closest("[data-ci]").dataset.ci].en = e.target.value;
  render();
});
$("blockBody").addEventListener("click", e => {
  const b = S.proj.blocks.find(x => x.id === editing); if (!b) return;
  const del = e.target.closest("[data-delc]"), sp = e.target.closest("[data-splitc]");
  if (del) { b.cells.splice(+del.dataset.delc, 1); drawBlock(); render(); return }
  if (sp) {
    const i = +sp.dataset.splitc, c = b.cells[i], half = +(c.dur / 2).toFixed(2);
    c.dur = half;
    b.cells.splice(i + 1, 0, C.newCell({ dur: +(C.blockDur(b) >= 0 ? half : half).toFixed(2) }));
    drawBlock(); render(); return;
  }
  if (e.target.id === "bkAddCell") { b.cells.push(C.newCell({ dur: 3 })); drawBlock(); render() }
});
$("blkDel").addEventListener("click", () => {
  S.proj.blocks = S.proj.blocks.filter(x => x.id !== editing);
  if (S.sel === editing) S.sel = null;
  $("dlgBlock").close(); render(); toast("削除しました");
});

/* ============================================================
   ファイルと設定
   ============================================================ */
/* 書き出し先フォルダ（File System Access API）。選んだフォルダの handle は IndexedDB に残す */
const DIR = { handle: null, name: "", lastWrite: 0, timer: 0 };
const dirDB = () => new Promise((res, rej) => {
  const r = indexedDB.open("dub.palette.dir", 1);
  r.onupgradeneeded = () => r.result.createObjectStore("kv");
  r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
});
async function dirGet(){ try { const db = await dirDB(); return await new Promise((res, rej) => { const q = db.transaction("kv").objectStore("kv").get("dir"); q.onsuccess = () => res(q.result || null); q.onerror = () => rej(q.error) }) } catch { return null } }
async function dirPut(h){ try { const db = await dirDB(); await new Promise((res, rej) => { const tx = db.transaction("kv", "readwrite"); if (h) tx.objectStore("kv").put(h, "dir"); else tx.objectStore("kv").delete("dir"); tx.oncomplete = res; tx.onerror = () => rej(tx.error) }) } catch {} }
const projFileName = () => (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_") + ".dubproj.json";
function syncDirUI(){
  $("fDirName").textContent = DIR.handle ? `${DIR.name}／${projFileName()}` : "未設定（ブラウザのダウンロード先に落ちる）";
  $("fDirClear").hidden = !DIR.handle;
  if (!("showDirectoryPicker" in window)) { $("fDir").disabled = true; $("fDir").title = "このブラウザでは使えない（Chrome / Edge）"; }
}
async function dirPermitted(ask){
  if (!DIR.handle) return false;
  try {
    const opt = { mode: "readwrite" };
    if (await DIR.handle.queryPermission(opt) === "granted") return true;
    return ask ? await DIR.handle.requestPermission(opt) === "granted" : false;
  } catch { return false }
}
async function writeToDir(ask){
  if (!await dirPermitted(ask)) return false;
  const fh = await DIR.handle.getFileHandle(projFileName(), { create: true });
  const w = await fh.createWritable();
  await w.write(JSON.stringify(S.proj, null, 2)); await w.close();
  DIR.lastWrite = Date.now();
  return true;
}
// 自動保存のたびに Dropbox を叩かないよう、フォルダへの書き込みは 3 秒に 1 回にまとめる
function scheduleDirWrite(){
  if (!DIR.handle) return;
  clearTimeout(DIR.timer);
  DIR.timer = setTimeout(() => writeToDir(false).then(ok => { if (ok) $("fSaved").textContent = `自動保存 → ${DIR.name} ${new Date().toLocaleTimeString("ja-JP")}` }).catch(() => {}), Math.max(0, 3000 - (Date.now() - DIR.lastWrite)));
}
dirGet().then(async h => {
  if (h && h.kind === "directory") { DIR.handle = h; DIR.name = h.name; }
  syncDirUI();
  const n = await loadTakesFromDir(false); if (n) toast(`フォルダから録音を ${n} 本読んだ`);
  syncRecUI();
});
$("fDir").addEventListener("click", async () => {
  try {
    const h = await window.showDirectoryPicker({ mode: "readwrite", id: "dub-json" });
    DIR.handle = h; DIR.name = h.name; await dirPut(h); syncDirUI();
    if (await writeToDir(true)) toast(`${DIR.name} に書き出しました`);
    const n = await loadTakesFromDir(true); if (n) toast(`フォルダから録音を ${n} 本読んだ`);
    syncRecUI();
  } catch (e) { if (e && e.name !== "AbortError") toast("フォルダを開けませんでした") }
});
$("fDirClear").addEventListener("click", async () => { DIR.handle = null; DIR.name = ""; await dirPut(null); syncDirUI(); });
$("fSave").addEventListener("click", async () => {
  try { if (await writeToDir(true)) { toast(`${DIR.name}／${projFileName()} に書き出しました`); return } }
  catch { toast("フォルダに書けなかったのでダウンロードに切り替えます") }
  C.download(projFileName(), JSON.stringify(S.proj, null, 2));
  toast("書き出しました");
});
$("fLoad").addEventListener("change", async e => {
  const f = e.target.files[0]; if (!f) return;
  try {
    const p = C.newProject(JSON.parse(await f.text()));
    S.proj = p; S.show = p.lanes.map(() => true); S.sel = null; S.frames = Object.create(null);
    buildLaneButtons(); syncRate(); rebuildAll(); $("dlgFile").close();
    toast("読み込みました");
  } catch { toast("読めませんでした") }
  e.target.value = "";
});
$("fSrt").addEventListener("click", () => {
  const name = (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_");
  C.download(name + ".ja.srt", C.toSRT(S.proj), "text/plain");
  toast("SRT を書き出しました");
});
$("fSrtHl").addEventListener("click", () => {
  const name = (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_");
  const srt = C.toSRT(S.proj, { field: "hl" });
  if (!srt.trim()) { toast("ハイライトがまだ無い。訳文を選んで「ハイライト」"); return }
  C.download(name + ".highlights.srt", srt, "text/plain");
  toast("ハイライトを SRT で書き出した");
});
$("fImport").addEventListener("click", () => { $("dlgFile").close(); openImport() });
$("fLabels").addEventListener("click", () => {
  const name = (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_");
  C.download(name + ".labels.txt", AU.toAudacityLabels(S.proj, C.tc), "text/plain"); toast("Audacity のラベルを書き出しました");
});
$("fReaper").addEventListener("click", () => {
  const name = (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_");
  C.download(name + ".reaper-markers.csv", AU.toReaperCSV(S.proj), "text/csv"); toast("REAPER のマーカー CSV を書き出しました");
});
function downloadBlob(name, blob){
  const a = document.createElement("a"), url = URL.createObjectURL(blob);
  a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
/** 書き出し先フォルダがあればそこへ、無ければダウンロード（クリックの流れの中で同期に呼ぶ） */
async function saveBlob(name, blob){
  if (!DIR.handle) { downloadBlob(name, blob); return "" }
  try {
    if (await dirPermitted(true)) {
      const fh = await DIR.handle.getFileHandle(name, { create: true });
      const w = await fh.createWritable(); await w.write(blob); await w.close();
      return DIR.name + "／" + name;
    }
  } catch {}
  downloadBlob(name, blob); return "";
}
async function exportTrack(){
  const live = livePieces();
  if (!live.length) { toast("読み込まれたテイクがない"); return }
  const sr = Math.max(...live.map(x => x.p.wav.sampleRate));
  const mix = AU.renderMix(live.map(x => ({ wav: x.p.wav, offset: x.p.at })), END(), sr);
  const blob = new Blob([AU.encodeWavFloat32([mix], sr)], { type: "audio/wav" });
  const name = projFileName().replace(/\.dubproj\.json$/, "") + ".ja.wav";
  const where = await saveBlob(name, blob);
  toast(`日本語トラックを書き出した${where ? "（" + where + "）" : ""}：${C.tc(END())}、${sr}Hz、${live.length} 片`);
}
$("fTrack").addEventListener("click", exportTrack);
$("recTrack").addEventListener("click", exportTrack);

$("fDict").addEventListener("click", () => { $("dlgFile").close(); drawDict(); $("dlgDict").showModal() });
$("fTitle").addEventListener("input", e => { S.proj.title = e.target.value; queueSave() });
$("fNew").addEventListener("click", () => {
  if (!confirm("いまのプロジェクトを閉じて、新規にしますか。")) return;
  S.proj = C.newProject({ title: "無題" });
  S.show = S.proj.lanes.map(() => true); S.sel = null; S.frames = Object.create(null);
  buildLaneButtons(); syncRate(); render(); $("dlgFile").close();
});
$("fSample").addEventListener("click", () => {
  S.proj = C.newProject(SAMPLE);
  S.show = S.proj.lanes.map(() => true); S.sel = null; S.frames = Object.create(null);
  buildLaneButtons(); syncRate(); render(); $("dlgFile").close();
});
$("fClearDo").addEventListener("click", () => {
  const li = +$("fClearLane").value, name = S.proj.lanes[li];
  const n = S.proj.blocks.filter(b => b.lane === li).length;
  if (!n) return toast(`${name} にブロックはありません`);
  if (!confirm(`${name} の ${n} ブロックを消します。戻せません。`)) return;
  S.proj.blocks = S.proj.blocks.filter(b => b.lane !== li);
  if (S.sel && !S.proj.blocks.some(b => b.id === S.sel)) S.sel = null;
  render(); $("dlgFile").close(); toast(`${name} を空にしました`);
});
$("fPinsClear").addEventListener("click", () => {
  const n = (S.proj.pins || []).length;
  if (!n) return toast("ピンはありません");
  if (!confirm(`ピン ${n} 本を全部外します。`)) return;
  S.proj.pins = []; render(); $("dlgFile").close(); toast("ピンを全部外しました");
});
$("fAddBlock").addEventListener("click", () => {
  const b = C.newBlock({ t: Math.round(S.t * 10) / 10, lane: S.show.findIndex(Boolean), kind: "NARR" });
  S.proj.blocks.push(b); C.sortBlocks(S.proj); S.sel = b.id;
  render(); $("dlgFile").close(); openBlock(b.id);
});

/* 読み方 */
function applyReadPrefs(){
  const p = JSON.parse(localStorage.getItem("dub.read") || "{}");
  document.body.dataset.serif = p.serif || "0";
  document.documentElement.style.setProperty("--ja-size", (p.size || 17) + "px");
  document.documentElement.style.setProperty("--ja-weight", p.weight || 500);
  $("fSize").value = p.size || 17;  $("fSizeVal").textContent = (p.size || 17) + "px";
  $("fWeight").value = p.weight || 500; $("fWeightVal").textContent = String(p.weight || 500);
  $$("[data-serif]").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.serif === (p.serif || "0"))));
}
function saveReadPrefs(){
  localStorage.setItem("dub.read", JSON.stringify({
    serif: document.body.dataset.serif,
    size: +$("fSize").value, weight: +$("fWeight").value,
  }));
}
$("dlgFile").addEventListener("click", e => {
  const b = e.target.closest("[data-serif]"); if (!b) return;
  document.body.dataset.serif = b.dataset.serif;
  $$("[data-serif]").forEach(x => x.setAttribute("aria-pressed", String(x === b)));
  saveReadPrefs();
});
$("fSize").addEventListener("input", e => {
  document.documentElement.style.setProperty("--ja-size", e.target.value + "px");
  $("fSizeVal").textContent = e.target.value + "px"; saveReadPrefs();
});
$("fWeight").addEventListener("input", e => {
  document.documentElement.style.setProperty("--ja-weight", e.target.value);
  $("fWeightVal").textContent = e.target.value; saveReadPrefs();
});

/* 上部バーの高さをシートの sticky に伝える */
function topH(){
  document.documentElement.style.setProperty("--topH", $("top").offsetHeight + "px");
}
addEventListener("resize", () => { topH(); renderMini(S); drawMiniWave() });
new ResizeObserver(topH).observe($("top"));

boot();
topH();

// ここまで来れば起動は成功。以降のエラーは起動失敗の帯には出さない
window.__bootOK = true;
