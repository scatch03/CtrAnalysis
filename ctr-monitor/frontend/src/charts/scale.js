export function linear([d0, d1], [r0, r1]) {
  const k = (r1 - r0) / (d1 - d0 || 1);
  const f = (v) => r0 + (v - d0) * k;
  f.invert = (p) => d0 + (p - r0) / k;
  return f;
}

export function logScale([d0, d1], [r0, r1]) {
  const l0 = Math.log10(d0), l1 = Math.log10(d1);
  const k = (r1 - r0) / (l1 - l0 || 1);
  const f = (v) => r0 + (Math.log10(v) - l0) * k;
  f.invert = (p) => 10 ** (l0 + (p - r0) / k);
  return f;
}

function step(span, count) {
  const raw = span / Math.max(1, count);
  const mag = 10 ** Math.floor(Math.log10(raw));
  const n = raw / mag;
  return (n >= 7.5 ? 10 : n >= 3.5 ? 5 : n >= 1.5 ? 2 : 1) * mag;
}

export function niceDomain(lo, hi, count = 5, { zero = false } = {}) {
  if (zero) { lo = Math.min(0, lo); hi = Math.max(0, hi); }
  if (!(hi > lo)) { const pad = Math.abs(lo) * 0.1 || 1; lo -= pad; hi += pad; }
  const s = step(hi - lo, count);
  return [Math.floor(lo / s + 1e-9) * s, Math.ceil(hi / s - 1e-9) * s];
}

export function ticks(lo, hi, count = 5) {
  const s = step(hi - lo, count);
  const out = [];
  for (let v = Math.ceil(lo / s - 1e-9) * s; v <= hi + s * 1e-9; v += s) out.push(+v.toPrecision(12));
  return out;
}

const H = 3600e3;
const TIME_STEPS = [H, 2 * H, 3 * H, 6 * H, 12 * H, 24 * H, 48 * H, 7 * 24 * H, 14 * 24 * H];
export function timeTicks(t0, t1, count = 6) {
  const span = t1 - t0;
  const st = TIME_STEPS.find((s) => span / s <= count) || TIME_STEPS[TIME_STEPS.length - 1];
  const out = [];
  for (let t = Math.ceil(t0 / st) * st; t <= t1; t += st) out.push(t);
  return { ticks: out, step: st };
}

export function extent(values, pad = 0) {
  let lo = Infinity, hi = -Infinity;
  for (const v of values) if (v !== null && v !== undefined && Number.isFinite(v)) { if (v < lo) lo = v; if (v > hi) hi = v; }
  if (lo === Infinity) return [0, 1];
  const p = (hi - lo) * pad;
  return [lo - p, hi + p];
}

// SVG path through [x,y] px points; null y breaks the line
export function linePath(pts) {
  let d = "", pen = false;
  for (const [x, y] of pts) {
    if (y === null || y === undefined || !Number.isFinite(y)) { pen = false; continue; }
    d += `${pen ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`;
    pen = true;
  }
  return d;
}

export function areaPath(pts, y0) {
  // split into runs of defined points, close each run to the baseline
  let d = "", run = [];
  const flush = () => {
    if (run.length) {
      d += `M${run[0][0].toFixed(1)},${y0.toFixed(1)}` + run.map(([x, y]) => `L${x.toFixed(1)},${y.toFixed(1)}`).join("")
        + `L${run[run.length - 1][0].toFixed(1)},${y0.toFixed(1)}Z`;
    }
    run = [];
  };
  for (const p of pts) (p[1] === null || p[1] === undefined || !Number.isFinite(p[1])) ? flush() : run.push(p);
  flush();
  return d;
}

export function bandPath(xs, lo, hi) {
  if (!xs.length) return "";
  const top = xs.map((x, i) => `${i ? "L" : "M"}${x.toFixed(1)},${hi[i].toFixed(1)}`).join("");
  const bot = xs.slice().reverse().map((x, i) => `L${x.toFixed(1)},${lo[xs.length - 1 - i].toFixed(1)}`).join("");
  return `${top}${bot}Z`;
}

export function nearestIndex(sorted, v) {
  let lo = 0, hi = sorted.length - 1;
  if (hi < 0) return -1;
  while (hi - lo > 1) { const m = (lo + hi) >> 1; if (sorted[m] < v) lo = m; else hi = m; }
  return Math.abs(sorted[lo] - v) <= Math.abs(sorted[hi] - v) ? lo : hi;
}
