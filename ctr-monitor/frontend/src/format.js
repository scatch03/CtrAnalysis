const MINUS = "−";
const sign = (s) => s.replace(/^-/, MINUS);
const ok = (v) => v !== null && v !== undefined && Number.isFinite(v);

export const int = (v) => (ok(v) ? Math.round(v).toLocaleString("en-US") : "—");
export const fixed = (v, d = 2) => (ok(v) ? sign(v.toFixed(d)) : "—");
export const signed = (v, d = 4) => (ok(v) ? (v > 0 ? "+" : v < 0 ? MINUS : "") + Math.abs(v).toFixed(d) : "—");
export const pct = (v, d = 2) => (ok(v) ? `${sign(v.toFixed(d))}%` : "—");
export const share = (v, d = 1) => (ok(v) ? `${(v * 100).toFixed(d)}%` : "—");

export function compact(v, d = 1) {
  if (!ok(v)) return "—";
  const a = Math.abs(v);
  const f = (x, s) => `${sign((x).toFixed(x >= 100 || Number.isInteger(x) ? 0 : d))}${s}`;
  if (a >= 1e9) return f(v / 1e9, "B");
  if (a >= 1e6) return f(v / 1e6, "M");
  if (a >= 1e4) return f(v / 1e3, "k");
  if (a >= 100) return sign(Math.round(v).toLocaleString("en-US"));
  return sign(+v.toPrecision(3) + "");
}

export function pval(p) {
  if (!ok(p)) return "—";
  if (p === 0) return "<1e−300";
  if (p < 1e-4) return sign(p.toExponential(1)).replace("e-", "e−");
  return p.toFixed(4);
}
export const stars = (p) => (!ok(p) ? "—" : p < 0.001 ? "***" : p < 0.01 ? "**" : p < 0.05 ? "*" : "n.s.");
export function conclusion(b, p) {
  if (!ok(b) || !ok(p)) return "—";
  if (p >= 0.05) return "H4";
  return b > 0 ? "H3" : "H1";
}

const pad = (n) => String(n).padStart(2, "0");
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
// data timestamps carry no zone — they are shown on the data's own clock (UTC getters)
export function dataTime(ms, mode = "full") {
  if (!ok(ms)) return "—";
  const d = new Date(ms);
  const date = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  const hm = `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
  if (mode === "date") return date;
  if (mode === "short") return `${DOW[d.getUTCDay()]} ${pad(d.getUTCDate())} ${MON[d.getUTCMonth()]} ${hm}`;
  return `${date} ${hm}`;
}
export function tickTime(ms, stepMs) {
  const d = new Date(ms);
  if (stepMs >= 864e5) return `${pad(d.getUTCDate())} ${MON[d.getUTCMonth()]}`;
  if (d.getUTCHours() === 0 && d.getUTCMinutes() === 0) return `${DOW[d.getUTCDay()]} ${pad(d.getUTCDate())}`;
  return `${pad(d.getUTCHours())}:00`;
}

export function localTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
export function ago(iso) {
  if (!iso) return "—";
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${Math.round(s)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
export function duration(sec) {
  if (!ok(sec)) return "—";
  if (sec < 1) return `${Math.round(sec * 1000)}ms`;
  if (sec < 60) return `${sec.toFixed(1)}s`;
  const m = Math.floor(sec / 60);
  return `${m}m ${Math.round(sec - m * 60)}s`;
}
export const runDuration = (r) =>
  r?.started ? duration(((r.finished ? new Date(r.finished) : new Date()) - new Date(r.started)) / 1000) : "—";
export const bytes = (n) =>
  !ok(n) ? "—" : n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`;
