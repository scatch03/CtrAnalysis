import Plot, { TipRow } from "./Plot";
import { areaPath, linePath, nearestIndex, niceDomain } from "./scale";
import { compact, dataTime, pct } from "../format";

const BIN_MS = { "1h": 36e5, "2h": 72e5, "6h": 216e5, "1D": 864e5 };

function stepPts(points, idx, bin, sx, sy) {
  const out = [];
  for (const p of points) {
    const v = p[idx];
    const y = v === null || v === undefined ? null : sy(v);
    out.push([sx(p[0]), y], [sx(p[0] + bin), y]);
  }
  return out;
}

function tipFor(points, bin, metric) {
  return (px, py, { sx }) => {
    if (!points.length) return null;
    const t = sx.invert(px);
    const i = nearestIndex(points.map((p) => p[0] + bin / 2), t);
    const p = points[i];
    return {
      x: sx(p[0] + bin / 2), y: py, xLine: sx(p[0] + bin / 2),
      content: (
        <>
          <div className="t">{dataTime(p[0], "short")}{bin > 36e5 ? ` – ${dataTime(p[0] + bin, "short").slice(-5)}` : ""}</div>
          <TipRow color="var(--s3)" kind="area" label="Impressions / h" value={compact(p[1])} />
          <TipRow label="Clicks / h" value={compact(p[2])} />
          <TipRow color="var(--s1)" label="CTR" value={pct(p[3], 3)} />
          {metric === "ctr" && p[1] === 0 && <div className="muted">no impressions</div>}
        </>
      ),
    };
  };
}

/** One MRTG block: title, impressions graph (area), CTR graph (line), Max/Average/Current legend. */
export function MrtgWindow({ w, compactMode = false }) {
  const bin = BIN_MS[w.bin] || 36e5;
  const pts = w.points;
  const x = { type: "time", domain: [w.start, w.end] };
  const imax = Math.max(1, ...pts.map((p) => p[1] || 0));
  const cvals = pts.map((p) => p[3]).filter((v) => v !== null);
  const cmax = Math.max(0.01, ...cvals);
  const yi = { domain: niceDomain(0, imax * 1.05, 4) };
  const yc = { domain: niceDomain(0, cmax * 1.1, 4) };
  const h1 = compactMode ? 120 : 150, h2 = compactMode ? 96 : 118;
  const s = w.stats;

  return (
    <div className="mrtg">
      <div className="mrtg-title">
        <span>{w.title} <span className="muted">({w.avg})</span></span>
        <span className="muted" style={{ fontSize: 11 }}>{dataTime(w.start, "short")} → {dataTime(w.end, "short")}</span>
      </div>
      <Plot height={h1} x={x} y={yi} vgrid yTickFmt={(v) => compact(v)} yTitle="impr / h" watermark="CTR·MON"
            label={`${w.title}: impressions per hour`} hover={tipFor(pts, bin, "impr")} margin={{ bottom: 22 }}>
        {({ sx, sy }) => {
          const sp = stepPts(pts, 1, bin, sx, sy);
          return (
            <>
              <path d={areaPath(sp, sy(0))} style={{ fill: "var(--s3)", opacity: 0.16 }} />
              <path d={linePath(sp)} style={{ fill: "none", stroke: "var(--s3)", strokeWidth: 2, strokeLinejoin: "round" }} />
            </>
          );
        }}
      </Plot>
      <Plot height={h2} x={x} y={yc} vgrid yTickFmt={(v) => `${+v.toFixed(2)}%`} yTitle="CTR" watermark="CTR·MON"
            label={`${w.title}: click-through rate`} hover={tipFor(pts, bin, "ctr")} margin={{ bottom: 22 }}>
        {({ sx, sy }) => (
          <path d={linePath(stepPts(pts, 3, bin, sx, sy))}
                style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2, strokeLinejoin: "round" }} />
        )}
      </Plot>
      <table className="mrtg-legend">
        <thead><tr><th>&nbsp;</th><th>Max</th><th>Average</th><th>Current</th></tr></thead>
        <tbody>
          <tr><td><i className="key area" style={{ background: "var(--s3)" }} />Impressions / h</td>
            <td>{compact(s.impr.max)}</td><td>{compact(s.impr.avg)}</td><td>{compact(s.impr.cur)}</td></tr>
          <tr><td><i className="key" style={{ background: "transparent" }} />Clicks / h</td>
            <td>{compact(s.clicks.max)}</td><td>{compact(s.clicks.avg)}</td><td>{compact(s.clicks.cur)}</td></tr>
          <tr><td><i className="key" style={{ background: "var(--s1)" }} />CTR</td>
            <td>{pct(s.ctr.max, 3)}</td><td>{pct(s.ctr.avg, 3)}</td><td>{pct(s.ctr.cur, 3)}</td></tr>
        </tbody>
      </table>
    </div>
  );
}

/** Hour-of-day profile as two small multiples (never a dual axis). */
export function HourProfile({ rows, imprKey = "impr_h", ctrKey = "ctr", ctrLabel = "CTR", height = 150 }) {
  const x = { domain: [-0.5, 23.5] };
  const xt = [0, 3, 6, 9, 12, 15, 18, 21];
  const imax = Math.max(1, ...rows.map((r) => r[imprKey] || 0));
  const cvals = rows.map((r) => r[ctrKey]).filter((v) => v !== null && v !== undefined);
  const [c0, c1] = [Math.min(...cvals), Math.max(...cvals)];
  const pad = (c1 - c0) * 0.25 || c1 * 0.1 || 0.1;
  const hover = (px, py, { sx }) => {
    const h = Math.max(0, Math.min(23, Math.round(sx.invert(px))));
    const r = rows.find((d) => d.hour === h);
    if (!r) return null;
    return {
      x: sx(h), y: py, xLine: sx(h),
      content: (<><div className="t">{String(h).padStart(2, "0")}:00 – {String(h).padStart(2, "0")}:59</div>
        <TipRow color="var(--s3)" kind="area" label="Mean impressions / h" value={compact(r[imprKey])} />
        <TipRow color="var(--s1)" label={ctrLabel} value={pct(r[ctrKey], 3)} /></>),
    };
  };
  return (
    <div className="grid g2">
      <div>
        <div className="chart-note" style={{ margin: "0 0 4px" }}>Mean impressions per hour, by hour of day</div>
        <Plot height={height} x={x} y={{ domain: niceDomain(0, imax, 4) }} xTicks={xt} yTickFmt={(v) => compact(v)}
              xTickFmt={(v) => `${String(v).padStart(2, "0")}h`} hover={hover} label="Impressions by hour of day">
          {({ sx, sy }) => {
            const bw = Math.min(16, Math.max(3, sx(1) - sx(0) - 2));
            return rows.map((r) => {
              const x0 = sx(r.hour) - bw / 2, y = sy(r[imprKey] || 0), y0 = sy(0);
              const rad = Math.min(3, bw / 2, (y0 - y) / 2);
              return <path key={r.hour} style={{ fill: "var(--s3)" }}
                d={`M${x0},${y0}V${y + rad}Q${x0},${y} ${x0 + rad},${y}H${x0 + bw - rad}Q${x0 + bw},${y} ${x0 + bw},${y + rad}V${y0}Z`} />;
            });
          }}
        </Plot>
      </div>
      <div>
        <div className="chart-note" style={{ margin: "0 0 4px" }}>{ctrLabel}, by hour of day</div>
        <Plot height={height} x={x} y={{ domain: niceDomain(Math.max(0, c0 - pad), c1 + pad, 4) }} xTicks={xt}
              yTickFmt={(v) => `${+v.toFixed(2)}%`} xTickFmt={(v) => `${String(v).padStart(2, "0")}h`} hover={hover}
              label="CTR by hour of day">
          {({ sx, sy }) => (
            <>
              <path d={linePath(rows.map((r) => [sx(r.hour), r[ctrKey] == null ? null : sy(r[ctrKey])]))}
                    style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2, strokeLinejoin: "round" }} />
              {rows.map((r) => r[ctrKey] != null && (
                <circle key={r.hour} cx={sx(r.hour)} cy={sy(r[ctrKey])} r={3}
                        style={{ fill: "var(--s1)", stroke: "var(--surface)", strokeWidth: 1.5 }} />))}
            </>
          )}
        </Plot>
      </div>
    </div>
  );
}

export function Sparkline({ values, width = 96, height = 22 }) {
  const v = values.map((x) => (x === null || x === undefined ? null : x));
  const def = v.filter((x) => x !== null);
  if (def.length < 2) return <span className="muted">—</span>;
  const lo = Math.min(...def), hi = Math.max(...def);
  const sx = (i) => 1 + (i / (v.length - 1)) * (width - 2);
  const sy = (x) => height - 3 - ((x - lo) / (hi - lo || 1)) * (height - 6);
  const last = v.length - 1 - [...v].reverse().findIndex((x) => x !== null);
  return (
    <svg width={width} height={height} aria-hidden="true" style={{ display: "block" }}>
      <path d={linePath(v.map((x, i) => [sx(i), x === null ? null : sy(x)]))}
            style={{ fill: "none", stroke: "var(--muted)", strokeWidth: 1.5, strokeLinejoin: "round" }} />
      <circle cx={sx(last)} cy={sy(v[last])} r={2.5} style={{ fill: "var(--s1)" }} />
    </svg>
  );
}
