/* ============================================================
   audio.js — 本番の録音（WAV）を読む・見る・鳴らす
   ブラウザの <audio> は 32-bit float WAV を鳴らせない環境があるので、
   RIFF を自前で読み、Web Audio で鳴らす。
   ============================================================ */

/* ---------------- RIFF/WAVE ----------------
   対応: PCM 8/16/24/32bit（tag 1）、IEEE float 32/64bit（tag 3）、EXTENSIBLE（tag 0xFFFE）。
   bext などの余計なチャンクは読み飛ばす。RF64（4GB超）は非対応 */
export function parseWav(buf){
  const dv = new DataView(buf);
  const str = (o, n) => String.fromCharCode(...new Uint8Array(buf, o, n));
  if (str(0, 4) !== "RIFF" || str(8, 4) !== "WAVE") throw new Error("WAV ではありません");
  let p = 12, fmt = null, data = null;
  while (p + 8 <= buf.byteLength) {
    const id = str(p, 4), size = dv.getUint32(p + 4, true), body = p + 8;
    if (id === "fmt ") {
      let tag = dv.getUint16(body, true);
      const channels = dv.getUint16(body + 2, true), sampleRate = dv.getUint32(body + 4, true);
      const bits = dv.getUint16(body + 14, true);
      if (tag === 0xFFFE && size >= 26) tag = dv.getUint16(body + 24, true);   // SubFormat GUID の先頭2バイト
      fmt = { tag, channels, sampleRate, bits };
    } else if (id === "data") {
      data = { off: body, size: Math.min(size, buf.byteLength - body) };
    }
    p = body + size + (size & 1);
    if (fmt && data) break;
  }
  if (!fmt || !data) throw new Error("fmt / data チャンクが見つかりません");
  const { tag, channels, sampleRate, bits } = fmt;
  const bytes = bits / 8, frames = Math.floor(data.size / (bytes * channels));
  const ch = Array.from({ length: channels }, () => new Float32Array(frames));
  const rd = (() => {
    if (tag === 3 && bits === 32) return o => dv.getFloat32(o, true);
    if (tag === 3 && bits === 64) return o => dv.getFloat64(o, true);
    if (tag === 1 && bits === 16) return o => dv.getInt16(o, true) / 32768;
    if (tag === 1 && bits === 24) return o => { const v = dv.getUint8(o) | (dv.getUint8(o + 1) << 8) | (dv.getInt8(o + 2) << 16); return v / 8388608 };
    if (tag === 1 && bits === 32) return o => dv.getInt32(o, true) / 2147483648;
    if (tag === 1 && bits === 8)  return o => (dv.getUint8(o) - 128) / 128;
    throw new Error(`この形式は読めません（tag ${tag}, ${bits}bit）`);
  })();
  let o = data.off;
  for (let i = 0; i < frames; i++)
    for (let c = 0; c < channels; c++) { ch[c][i] = rd(o); o += bytes }
  return { sampleRate, channels, frames, duration: frames / sampleRate, ch,
           format: (tag === 3 ? "float" : "pcm") + bits };
}

/* ---------------- 包絡（5ms 刻み） ----------------
   env … 区間内の |x| の最大（波形を描く用）
   rms … 区間内の実効値（声の有無を判定する用） */
export const BIN = 0.005;
export function envelope(wav){
  const n = Math.ceil(wav.duration / BIN), per = Math.round(wav.sampleRate * BIN);
  const env = new Float32Array(n), rms = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const a = i * per, b = Math.min(wav.frames, a + per);
    let mx = 0, sq = 0, cnt = 0;
    for (const c of wav.ch) for (let k = a; k < b; k++) { const v = c[k], av = v < 0 ? -v : v; if (av > mx) mx = av; sq += v * v; cnt++ }
    env[i] = mx; rms[i] = cnt ? Math.sqrt(sq / cnt) : 0;
  }
  return { env, rms, n };
}

/* ---------------- 発声区間 ----------------
   閾値はファイルごとに決める（雑音床の 4 倍、下限 −40 dBFS）。
   入りは 10ms、抜けは 250ms の粘り。80ms 未満は捨てる */
export function speechSegments(rms){
  const sorted = Float32Array.from(rms).sort();
  const floor = sorted[Math.floor(sorted.length * 0.2)] || 0;
  const thr = Math.max(0.01, floor * 4), low = thr * 0.6;
  const onN = 2, offN = 50, minLen = 16;
  const segs = [];
  let on = false, start = 0, above = 0, below = 0;
  for (let i = 0; i < rms.length; i++) {
    const v = rms[i];
    if (!on) {
      above = v > thr ? above + 1 : 0;
      if (above >= onN) { on = true; start = i - onN + 1; below = 0 }
    } else {
      below = v < low ? below + 1 : 0;
      if (below >= offN) { const end = i - offN + 1; if (end - start >= minLen) segs.push([start * BIN, end * BIN]); on = false; above = 0 }
    }
  }
  if (on && rms.length - start >= minLen) segs.push([start * BIN, rms.length * BIN]);
  return { segs, thr };
}

/** 枠 [t0,t1] に掛かる発声の広がり。無ければ null */
export function takeFor(segs, t0, t1){
  const hit = segs.filter(([a, b]) => b > t0 && a < t1);
  if (!hit.length) return null;
  const start = Math.min(...hit.map(s => s[0])), end = Math.max(...hit.map(s => s[1]));
  return { start, end, dur: end - start, lead: t0 - start, tail: end - t1 };   // lead/tail > 0 ＝ はみ出し
}

/* ---------------- 描画 ----------------
   [t0,t1] の包絡を canvas に描く。枠の外（余白）は薄く、はみ出した発声は赤 */
export function drawWave(canvas, A, opt){
  const { t0, t1, slot, take, ticks = [], red = false } = opt;
  const W = canvas.width, H = canvas.height, g = canvas.getContext("2d");
  g.clearRect(0, 0, W, H);
  const span = t1 - t0, xOf = t => (t - t0) / span * W;
  // 枠
  g.fillStyle = "#f2f2ec";
  g.fillRect(xOf(slot[0]), 0, xOf(slot[1]) - xOf(slot[0]), H);
  // 包絡
  const mid = H / 2, b0 = Math.floor(t0 / BIN), b1 = Math.ceil(t1 / BIN);
  const perPx = Math.max(1, (b1 - b0) / W);
  for (let x = 0; x < W; x++) {
    const a = b0 + Math.floor(x * perPx), b = b0 + Math.floor((x + 1) * perPx);
    let mx = 0;
    for (let i = a; i < b && i < A.env.length; i++) if (i >= 0 && A.env[i] > mx) mx = A.env[i];
    const h = Math.max(1, mx * (H - 4));
    const t = t0 + x / W * span;
    const inSlot = t >= slot[0] && t <= slot[1];
    const spill = take && red && ((t < slot[0] && t >= take.start) || (t > slot[1] && t <= take.end));
    g.fillStyle = spill ? "#c03a2b" : inSlot ? "#6c7075" : "#c8c8c0";
    g.fillRect(x, mid - h / 2, 1, h);
  }
  // セルの境目
  g.fillStyle = "#a6a69c";
  for (const t of ticks) { const x = Math.round(xOf(t)); g.fillRect(x, 0, 1, H) }
  // 発声の広がり
  if (take) {
    g.fillStyle = red ? "#c03a2b" : "#16181a";
    const xs = Math.max(0, xOf(take.start)), xe = Math.min(W, xOf(take.end));
    g.fillRect(xs, H - 2, Math.max(1, xe - xs), 2);
  }
}

/* ---------------- 再生 ----------------
   映像があれば映像が時計。無ければ AudioContext が時計 */
export class WavPlayer {
  constructor(){ this.ctx = null; this.buffer = null; this.gain = null; this.src = null;
                 this.playing = false; this.startCtx = 0; this.startT = 0; this.rate = 1; this.on = true }
  load(wav){
    if (!this.ctx) { this.ctx = new (window.AudioContext || window.webkitAudioContext)(); this.gain = this.ctx.createGain(); this.gain.connect(this.ctx.destination) }
    this.stop();
    this.buffer = this.ctx.createBuffer(wav.channels, wav.frames, wav.sampleRate);
    wav.ch.forEach((c, i) => this.buffer.copyToChannel(c, i));
    this.gain.gain.value = this.on ? 1 : 0;
  }
  play(t){
    if (!this.buffer) return;
    this.stop();
    this.ctx.resume();
    const src = this.ctx.createBufferSource();
    src.buffer = this.buffer; src.playbackRate.value = this.rate; src.connect(this.gain);
    const at = Math.max(0, Math.min(this.buffer.duration - 0.01, t));
    src.start(0, at);
    this.src = src; this.startCtx = this.ctx.currentTime; this.startT = at; this.playing = true;
    src.onended = () => { if (this.src === src) { this.playing = false; this.src = null } };
  }
  stop(){ if (this.src) { try { this.src.onended = null; this.src.stop() } catch {} this.src.disconnect(); this.src = null } this.playing = false }
  now(){ return this.playing ? this.startT + (this.ctx.currentTime - this.startCtx) * this.rate : this.startT }
  seek(t){ const was = this.playing; this.startT = t; if (was) this.play(t) }
  setRate(r){ this.rate = r; if (this.playing) this.play(this.now()) }
  setOn(v){ this.on = v; if (this.gain) this.gain.gain.value = v ? 1 : 0 }
}

/* ---------------- 書き出し：DAW への橋 ---------------- */
/** Audacity のラベルトラック（start \\t end \\t label） */
export function toAudacityLabels(proj, tc){
  const lines = [];
  for (const t of proj.pins || []) lines.push(`${t.toFixed(3)}\t${t.toFixed(3)}\tPIN ${tc(t)}`);
  for (const b of proj.blocks) {
    const dur = b.kind === "SILENT" ? (b.dur || 0) : b.cells.reduce((s, c) => s + (+c.dur || 0), 0);
    const head = (b.cells?.[0]?.ja || b.cells?.[0]?.en || "").slice(0, 24).replace(/\s+/g, " ");
    lines.push(`${b.t.toFixed(3)}\t${(b.t + dur).toFixed(3)}\t${proj.lanes[b.lane]}${head ? " " + head : ""}`);
  }
  return lines.join("\n") + "\n";
}
/** REAPER の「マーカー/リージョンを読み込み」用 CSV */
export function toReaperCSV(proj){
  const rows = ["#,Name,Start,End,Length"];
  let m = 1, r = 1;
  for (const t of proj.pins || []) rows.push(`M${m++},PIN,${t.toFixed(3)},,`);
  for (const b of proj.blocks) {
    const dur = b.kind === "SILENT" ? (b.dur || 0) : b.cells.reduce((s, c) => s + (+c.dur || 0), 0);
    const name = (proj.lanes[b.lane] + " " + (b.cells?.[0]?.ja || "").slice(0, 24)).replace(/[",\n]/g, " ");
    rows.push(`R${r++},${name},${b.t.toFixed(3)},${(b.t + dur).toFixed(3)},${dur.toFixed(3)}`);
  }
  return rows.join("\n") + "\n";
}
