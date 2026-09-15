/* ============================================================
   app.js — 状態と配線
   ============================================================ */
import * as C from "./core.js";
import { renderSheet, renderMini, renderPlane, blockInfo, metaHTML } from "./view.js";
import { SAMPLE } from "./sample.js";

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
};

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
  if (S.plane) renderPlane(S); else renderSheet(S);
  renderMini(S);
  syncToolbar();
  observeFilms();
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
}
// 閉じる・隠れるときは待たずに書く。数百ミリ秒の取りこぼしで原稿を失わせない
addEventListener("pagehide", flushSave);
addEventListener("beforeunload", flushSave);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushSave();
});

function syncToolbar(){
  const n = C.countReds(S.proj, S.rate);
  const t = $("tally");
  t.textContent = "赤 " + n;
  t.classList.toggle("zero", n === 0);
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
  frame();
}
function setPlay(v){
  S.playing = v;
  $("play").textContent = v ? "❚❚" : "▶";
  $("play").setAttribute("aria-label", v ? "停止" : "再生");
  if (S.hasMedia) { v ? media.play().catch(() => {}) : media.pause(); }
  if (v) { rafLast = performance.now(); requestAnimationFrame(tick); }
}
let rafLast = 0;
function tick(now){
  if (!S.playing) return;
  const dt = (now - rafLast) / 1000; rafLast = now;
  if (S.hasMedia) S.t = media.currentTime;
  else S.t += dt * S.speed;

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
  const out = [];
  for (const { c, t, b } of C.eachCell(S.proj))
    if (C.judgeCell(c, S.proj.dict, S.rate).over) out.push({ t, b });
  return out;
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
  S.speed = parseFloat(e.target.value); media.playbackRate = S.speed;
});
$("mediafile").addEventListener("change", e => {
  const f = e.target.files[0]; if (!f) return;
  const url = URL.createObjectURL(f);
  media.src = url; grabber.src = url;
  S.hasMedia = true; S.frames = Object.create(null);
  media.playbackRate = S.speed; media.volume = S.orig ? 1 : 0;
  $("mediahint").textContent = f.name;
  media.addEventListener("loadedmetadata", () => {
    if (isFinite(media.duration)) S.proj.duration = media.duration;
    render(); frame(); toast("メディアを接続しました（コマは見えたところから取り込みます）");
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

/* --- シート --- */
const sheet = $("sheet");
sheet.addEventListener("input", e => {
  const ja = e.target.closest(".ja"), ka = e.target.closest(".kana");
  const el = ja || ka; if (!el) return;
  const bid = ja ? el.dataset.b : el.dataset.kb;
  const ci  = +(ja ? el.dataset.c : el.dataset.kc);
  const b = S.proj.blocks.find(x => x.id === bid); if (!b) return;
  if (ja) b.cells[ci].ja = el.innerText.replace(/\n$/, "");
  else    b.cells[ci].kana = el.innerText.replace(/\n$/, "");
  repaintCell(bid, ci);
  queueSave();
});
sheet.addEventListener("click", e => {
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
function repaintCell(bid, ci){
  const b = S.proj.blocks.find(x => x.id === bid); if (!b) return;
  const info = blockInfo(S, b), j = info.cells[ci];
  const card = document.querySelector(`.card[data-b="${bid}"]`);
  if (card) {
    card.classList.toggle("over", info.over);
    const cell = card.querySelector(`[data-cell="${ci}"]`);
    cell?.classList.toggle("bad", j.over);
    const meta = cell?.querySelector(".meta");
    if (meta) meta.innerHTML = metaHTML(j) + `<button class="kanabtn" data-kana="${bid}:${ci}">よみ</button>`;
  }
  syncToolbar(); renderMini(S);
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
  else if (k === "f") $("viewmode").click();
  else if (k === "r" && S.sel) {
    const b = selBlock(); b.rec = (b.rec + 1) % 3;
    const el = document.querySelector(`[data-rec="${b.id}"]`);
    if (el) { el.dataset.state = b.rec; el.textContent = C.REC[b.rec] }
    queueSave();
  }
  else if (k === "e" && S.sel) openBlock(S.sel);
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
  $("takeInfo").textContent = cell
    ? `選択中：${C.tc(cell.t)}　${C.cellMora(cell.c, S.proj.dict).mora} モーラ`
    : "セルが選ばれていません";
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
$("fSave").addEventListener("click", () => {
  const name = (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_");
  C.download(name + ".dubproj.json", JSON.stringify(S.proj, null, 2));
  toast("書き出しました");
});
$("fLoad").addEventListener("change", async e => {
  const f = e.target.files[0]; if (!f) return;
  try {
    const p = C.newProject(JSON.parse(await f.text()));
    S.proj = p; S.show = p.lanes.map(() => true); S.sel = null; S.frames = Object.create(null);
    buildLaneButtons(); syncRate(); render(); $("dlgFile").close();
    toast("読み込みました");
  } catch { toast("読めませんでした") }
  e.target.value = "";
});
$("fSrt").addEventListener("click", () => {
  const name = (S.proj.title || "dub").replace(/[^\w　-鿿-]+/g, "_");
  C.download(name + ".ja.srt", C.toSRT(S.proj), "text/plain");
  toast("SRT を書き出しました");
});
$("fImport").addEventListener("click", () => { $("dlgFile").close(); openImport() });
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
addEventListener("resize", () => { topH(); renderMini(S) });
new ResizeObserver(topH).observe($("top"));

boot();
topH();
