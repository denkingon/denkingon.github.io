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
   閾値はファイルごとに決める。雑音床（静かな方の 5% の中央値）の 4 倍、下限 −50 dBFS。
   ただし声が密なファイル（1 分のテイクなど）で雑音床が声に食い込んでも拾えるよう、
   大きい方（上位 5%）の 15% を超えない。opt.thr で手動の値に置き換えられる。
   入りは 10ms、抜けは 250ms の粘り。80ms 未満は捨てる */
export function noiseStats(rms){
  const sorted = Float32Array.from(rms).sort();
  const n = sorted.length;
  const q = f => sorted[Math.min(n - 1, Math.max(0, Math.floor(n * f)))] || 0;
  const floor = q(0.025), loud = q(0.95);                // 静かな側 5% の中央値、上位 5%
  // 雑音床が声に近い（部屋鳴り）ときは上限に引っかかるので、床の 1.5 倍は下回らないようにする
  const auto = Math.max(floor * 1.5 + 0.0005, Math.min(Math.max(floor * 4, 0.003), Math.max(loud * 0.15, 0.0005)));
  return { floor, loud, auto };
}
export const dB = v => v > 0 ? 20 * Math.log10(v) : -Infinity;
export const fromDB = d => Math.pow(10, d / 20);
export function speechSegments(rms, opt = {}){
  const st = noiseStats(rms);
  const thr = opt.thr > 0 ? opt.thr : st.auto, low = thr * 0.6;
  const onN = 2, offN = opt.offN > 0 ? opt.offN : 50, minLen = 16;   // offN: 抜けの粘り（5ms 刻み）
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
  return { segs, thr, floor: st.floor, loud: st.loud, auto: st.auto, manual: !!(opt.thr > 0) };
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
  const { t0, t1, slot, take, ticks = [], red = false, offset = 0 } = opt;
  const W = canvas.width, H = canvas.height, g = canvas.getContext("2d");
  g.clearRect(0, 0, W, H);
  const span = t1 - t0, xOf = t => (t - t0) / span * W;
  // 枠
  g.fillStyle = "#f2f2ec";
  g.fillRect(xOf(slot[0]), 0, xOf(slot[1]) - xOf(slot[0]), H);
  // 包絡
  const mid = H / 2, b0 = Math.floor((t0 - offset) / BIN), b1 = Math.ceil((t1 - offset) / BIN);
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
/* ---------------- 再生：テイク複数を時間軸に置いて鳴らす ----------------
   各テイクは { buffer, offset }。offset は時間軸のどこにテイクの 0 秒が来るか。
   play(t) は t に掛かるテイクを全部同時に始める。t より先にあるテイクは待ってから鳴らす */
export class MultiPlayer {
  constructor(){ this.ctx = null; this.gain = null; this.takes = new Map(); this.srcs = [];
                 this.playing = false; this.startCtx = 0; this.startT = 0; this.rate = 1; this.on = true }
  ensure(){
    if (!this.ctx) { this.ctx = new (window.AudioContext || window.webkitAudioContext)(); this.gain = this.ctx.createGain(); this.gain.connect(this.ctx.destination); this.gain.gain.value = this.on ? 1 : 0 }
  }
  setTake(id, wav, offset){
    this.ensure();
    const buffer = this.ctx.createBuffer(wav.channels, Math.max(1, wav.frames), wav.sampleRate);
    wav.ch.forEach((c, i) => buffer.copyToChannel(c, i));
    this.takes.set(id, { buffer, offset: +offset || 0 });
    if (this.playing) this.play(this.now());
  }
  setOffset(id, offset){ const tk = this.takes.get(id); if (!tk) return; tk.offset = +offset || 0; if (this.playing) this.play(this.now()) }
  remove(id){ this.takes.delete(id); if (this.playing) this.play(this.now()) }
  get duration(){ let e = 0; for (const tk of this.takes.values()) e = Math.max(e, tk.offset + tk.buffer.duration); return e }
  play(t){
    this.stop();
    if (!this.takes.size) return;
    this.ensure(); this.ctx.resume();
    this.startCtx = this.ctx.currentTime; this.startT = t;
    for (const tk of this.takes.values()) {
      const at = t - tk.offset;
      if (at >= tk.buffer.duration - 0.01) continue;
      const src = this.ctx.createBufferSource();
      src.buffer = tk.buffer; src.playbackRate.value = this.rate; src.connect(this.gain);
      if (at < 0) src.start(this.startCtx + (-at) / this.rate, 0); else src.start(0, at);
      src.onended = () => { this.srcs = this.srcs.filter(x => x !== src); if (!this.srcs.length) this.playing = false };
      this.srcs.push(src);
    }
    this.playing = this.srcs.length > 0;
  }
  stop(){ for (const src of this.srcs) { try { src.onended = null; src.stop() } catch {} src.disconnect() } this.srcs = []; this.playing = false }
  now(){ return this.playing ? this.startT + (this.ctx.currentTime - this.startCtx) * this.rate : this.startT }
  seek(t){ const was = this.playing; this.startT = t; if (was) this.play(t) }
  setRate(r){ this.rate = r; if (this.playing) this.play(this.now()) }
  setOn(v){ this.on = v; if (this.gain) this.gain.gain.value = v ? 1 : 0 }
}

/* ---------------- 伸縮（WSOLA）----------------
   ピッチを保ったまま ratio 倍の速さにする（ratio 1.25 → 長さ 1/1.25）。
   24ms の窓・50% 重ね。前の窓の自然な続きと最も似た位置を ±8ms で探して重ねる */
export function stretch(x, sr, ratio){
  if (!(ratio > 0) || Math.abs(ratio - 1) < 1e-3) return Float32Array.from(x);
  const N = Math.max(64, Math.round(sr * 0.024) & ~1), Ss = N / 2, Sa = Ss * ratio, tol = Math.round(sr * 0.008);
  const outLen = Math.floor(x.length / ratio);
  const y = new Float32Array(outLen + N);
  const win = new Float32Array(N);
  for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / N);
  const sim = (a, b) => { let s = 0; for (let i = 0; i < Ss; i += 2) s += x[a + i] * x[b + i]; return s };
  let prev = 0;
  for (let k = 0; ; k++) {
    const outPos = k * Ss;
    if (outPos + N > y.length) break;
    const nominal = Math.round(k * Sa);
    if (nominal + N + tol >= x.length) break;
    let best = nominal;
    if (k > 0) {
      const target = prev + Ss;                      // 前の窓の自然な続き
      if (target + Ss < x.length) {
        let bestC = -Infinity;
        const lo = Math.max(0, nominal - tol), hi = Math.min(x.length - N, nominal + tol);
        for (let c = lo; c <= hi; c += 3) { const v = sim(c, target); if (v > bestC) { bestC = v; best = c } }
        for (let c = Math.max(lo, best - 2); c <= Math.min(hi, best + 2); c++) { const v = sim(c, target); if (v > bestC) { bestC = v; best = c } }
      }
    }
    for (let i = 0; i < N; i++) y[outPos + i] += x[best + i] * (k === 0 && i < Ss ? 1 : win[i]);
    prev = best;
  }
  return y.subarray(0, outLen);
}

/* ---------------- 日本語トラックの書き出し ----------------
   テイク（伸縮・切り出し済み）を時間軸に並べて 1 本にする。mono に落とす。
   サンプルレートが違うテイクは線形補間で合わせる */
export function renderMix(takes, duration, sampleRate){
  const n = Math.max(1, Math.ceil(duration * sampleRate));
  const out = new Float32Array(n);
  for (const { wav, offset } of takes) {
    const g = 1 / wav.channels, start = Math.round((+offset || 0) * sampleRate);
    const r = wav.sampleRate / sampleRate, len = Math.floor(wav.frames / r);
    for (const c of wav.ch) {
      for (let i = 0; i < len; i++) {
        const o = start + i; if (o < 0) continue; if (o >= n) break;
        if (r === 1) { out[o] += c[i] * g; continue }
        const p = i * r, a = Math.floor(p), f = p - a, v = c[a] + (c[Math.min(wav.frames - 1, a + 1)] - c[a]) * f;
        out[o] += v * g;
      }
    }
  }
  return out;
}
export function encodeWavFloat32(chs, sampleRate){
  const channels = chs.length, frames = chs[0].length, bytes = frames * channels * 4;
  const buf = new ArrayBuffer(44 + bytes), dv = new DataView(buf);
  const str = (o, t) => { for (let i = 0; i < t.length; i++) dv.setUint8(o + i, t.charCodeAt(i)) };
  str(0, "RIFF"); dv.setUint32(4, 36 + bytes, true); str(8, "WAVE");
  str(12, "fmt "); dv.setUint32(16, 16, true); dv.setUint16(20, 3, true); dv.setUint16(22, channels, true);
  dv.setUint32(24, sampleRate, true); dv.setUint32(28, sampleRate * channels * 4, true); dv.setUint16(32, channels * 4, true); dv.setUint16(34, 32, true);
  str(36, "data"); dv.setUint32(40, bytes, true);
  let o = 44;
  for (let i = 0; i < frames; i++) for (let c = 0; c < channels; c++) { dv.setFloat32(o, chs[c][i], true); o += 4 }
  return buf;
}

/** テイクの帯（ファイル画面）：生の包絡全体。入り/出の外は薄く、発声は下線、入り/出の位置に取っ手 */
export function drawTakeStrip(canvas, A, opt){
  const { duration, tin = 0, tout = null, segs = [], clips = [] } = opt;
  const W = canvas.width, H = canvas.height, g = canvas.getContext("2d");
  const end = tout == null ? duration : tout;
  g.clearRect(0, 0, W, H);
  g.fillStyle = "#f2f2ec"; g.fillRect(0, 0, W, H);
  const xOf = t => t / Math.max(0.01, duration) * W;
  g.fillStyle = "#fbfbf9"; g.fillRect(xOf(tin), 0, Math.max(0, xOf(end) - xOf(tin)), H);
  const perPx = Math.max(1, A.env.length / W), mid = H / 2;
  for (let x = 0; x < W; x++) {
    const a = Math.floor(x * perPx), b = Math.floor((x + 1) * perPx);
    let mx = 0; for (let i = a; i < b && i < A.env.length; i++) if (A.env[i] > mx) mx = A.env[i];
    const t = x / W * duration, inside = t >= tin && t <= end;
    g.fillStyle = inside ? "#6c7075" : "#c8c8c0";
    const h = Math.max(1, mx * (H - 6));
    g.fillRect(x, mid - h / 2, 1, h);
  }
  g.fillStyle = "#16181a";
  for (const [a, b] of segs) { const xs = xOf(a), xe = xOf(b); g.fillRect(xs, H - 2, Math.max(1, xe - xs), 2) }
  // 割り付け（ブロックごとの切り出し）：上辺に交互の帯と番号
  clips.forEach((c, i) => {
    const xs = xOf(c.in), xe = xOf(c.out);
    g.fillStyle = i % 2 ? "#9aa0a6" : "#4d545a"; g.fillRect(xs, 0, Math.max(1, xe - xs), 4);
    g.fillStyle = "#16181a"; g.fillRect(Math.round(xs), 0, 1, H);
    g.font = "10px sans-serif"; g.fillStyle = "#4d545a"; g.fillText(String(i + 1), xs + 3, 15);
  });
  g.fillStyle = "#16181a";
  for (const t of [tin, end]) { const x = Math.round(xOf(t)); g.fillRect(x - 1, 0, 2, H); g.fillRect(x - 4, 0, 8, 5); g.fillRect(x - 4, H - 5, 8, 5) }
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
