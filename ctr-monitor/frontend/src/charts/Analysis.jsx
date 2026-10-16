import { useState } from "react";
import Plot, { Legend, TipRow } from "./Plot";
import { bandPath, extent, linePath, nearestIndex, niceDomain } from "./scale";
import { useMeasure } from "../hooks";
import { compact, fixed, int, pct, pval, share, signed, stars } from "../format";

export const EST_COLOR = { GLM: "var(--s1)", OLS: "var(--s2)", WLS: "var(--s3)" };
export const HYP = {
  H1: { color: "var(--s1)", dash: null, name: "Exponential decay (fatigue)" },
  H2: { color: "var(--s2)", dash: "7 4", name: "Inverted-U (novelty → fatigue)" },
  H3: { color: "var(--s3)", dash: "3 3", name: "Saturating growth" },
  H4: { color: "var(--muted)", dash: "1 4", name: "Null (constant)" },
};
const BUCKETS = ["B1", "B2", "B3", "B4", "B5"];
const ring = { stroke: "var(--surface)", strokeWidth: 2 };
const bucketRange = (r) =>
  !r ? "" : r[1] === null ? `≥ ${compact(r[0])}` : `${compact(r[0])} – ${compact(r[1])}`;

/* ── fig1 — distribution of hourly CTR per volume bucket ─────────────────── */
export function BoxChart({ box, height = 260 }) {
  const rows = box.buckets;
  const y = { domain: [0, niceDomain(0, box.cap * 1.05, 5)[1]] };
  const hover = (px, py, { sx }) => {
    const i = Math.max(0, Math.min(4, Math.round(sx.invert(px))));
    const b = rows[i];
    if (!b?.n) return null;
    return {
      x: sx(i), y: py,
      content: (<><div className="t">{b.bucket} · {bucketRange(b.range)} impr/h</div>
        <TipRow label="Campaign-hours" value={int(b.n)} />
        <TipRow label="Median CTR" value={pct(b.median, 3)} />
        <TipRow label="IQR" value={`${pct(b.q1, 2)} – ${pct(b.q3, 2)}`} />
        <TipRow color="var(--s1)" kind="dot" label="Mean CTR" value={pct(b.mean, 3)} />
        <TipRow label="Zero-click hours" value={share(b.zero_click_share)} /></>),
    };
  };
  return (
    <>
      <Plot height={height} x={{ domain: [-0.5, 4.5] }} y={y} xTicks={[0, 1, 2, 3, 4]} xTickFmt={(i) => BUCKETS[i]}
            yTickFmt={(v) => `${v}%`} yTitle="Hourly CTR, %" xTitle="Impression-volume bucket" hover={hover}
            label="Box plots of hourly CTR by volume bucket">
        {({ sx, sy }) => rows.map((b, i) => {
          if (!b.n) return null;
          const cx = sx(i), bw = 24;
          return (
            <g key={b.bucket}>
              <line x1={cx} x2={cx} y1={sy(b.whisker_lo)} y2={sy(b.q1)} style={{ stroke: "var(--ink-2)", strokeWidth: 1 }} />
              <line x1={cx} x2={cx} y1={sy(b.q3)} y2={sy(b.whisker_hi)} style={{ stroke: "var(--ink-2)", strokeWidth: 1 }} />
              {[b.whisker_lo, b.whisker_hi].map((v, k) => (
                <line key={k} x1={cx - 6} x2={cx + 6} y1={sy(v)} y2={sy(v)} style={{ stroke: "var(--ink-2)", strokeWidth: 1 }} />))}
              <rect x={cx - bw / 2} y={sy(b.q3)} width={bw} height={Math.max(1, sy(b.q1) - sy(b.q3))} rx={3}
                    style={{ fill: "var(--s1)", fillOpacity: 0.16, stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <line x1={cx - bw / 2} x2={cx + bw / 2} y1={sy(b.median)} y2={sy(b.median)} style={{ stroke: "var(--ink)", strokeWidth: 2 }} />
              <circle cx={cx} cy={sy(Math.min(b.mean, box.cap))} r={4} style={{ fill: "var(--s1)", ...ring }} />
            </g>
          );
        })}
      </Plot>
      <Legend items={[{ label: "IQR box · median line · whiskers 1.5×IQR", color: "var(--s1)", kind: "area" },
                      { label: "Mean", color: "var(--s1)", kind: "dot" }]} />
      <div className="chart-note">
        y-axis capped at the 99th percentile ({pct(box.cap, 1)}); {int(box.n_above)} observations above it are not shown — same as fig. 1.
      </div>
    </>
  );
}

/* ── fig2 — mean CTR ± 95 % CI per bucket ────────────────────────────────── */
export function MeanCiChart({ rows, height = 260 }) {
  const hi = extent(rows.flatMap((r) => [r.lo, r.hi]), 0.15)[1];
  const hover = (px, py, { sx }) => {
    const i = Math.max(0, Math.min(rows.length - 1, Math.round(sx.invert(px))));
    const r = rows[i];
    return r && {
      x: sx(i), y: py,
      content: (<><div className="t">{r.bucket}</div>
        <TipRow color="var(--s1)" kind="dot" label="Mean CTR" value={pct(r.mean, 3)} />
        <TipRow label="95% CI" value={`${pct(r.lo, 3)} – ${pct(r.hi, 3)}`} />
        <TipRow label="N" value={int(r.n)} /></>),
    };
  };
  return (
    <Plot height={height} x={{ domain: [-0.5, rows.length - 0.5] }} y={{ domain: niceDomain(0, hi, 5) }}
          xTicks={rows.map((_, i) => i)} xTickFmt={(i) => rows[i]?.bucket} yTickFmt={(v) => `${+v.toFixed(2)}%`}
          yTitle="Mean hourly CTR, %" xTitle="Impression-volume bucket" hover={hover} label="Mean CTR with 95% CI by bucket">
      {({ sx, sy }) => (
        <>
          <path d={linePath(rows.map((r, i) => [sx(i), sy(r.mean)]))} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2 }} />
          {rows.map((r, i) => (
            <g key={r.bucket}>
              <line x1={sx(i)} x2={sx(i)} y1={sy(r.lo)} y2={sy(r.hi)} style={{ stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <line x1={sx(i) - 5} x2={sx(i) + 5} y1={sy(r.lo)} y2={sy(r.lo)} style={{ stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <line x1={sx(i) - 5} x2={sx(i) + 5} y1={sy(r.hi)} y2={sy(r.hi)} style={{ stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <circle cx={sx(i)} cy={sy(r.mean)} r={4.5} style={{ fill: "var(--s1)", ...ring }} />
            </g>
          ))}
        </>
      )}
    </Plot>
  );
}

/* ── fig4 — marginal effect: GLM vs naive OLS ────────────────────────────── */
export function MarginalChart({ m, height = 320 }) {
  const ys = { domain: [0, niceDomain(0, m.ymax, 5)[1]] };
  const xs = { domain: extent(m.x_extent || m.lv, 0.02) };   // runs before v4.2 have no x_extent / range
  const rng = m.range;
  const hover = (px, py, { sx, sy }) => {
    const v = sx.invert(px);
    if (rng && (v < rng[0] - 0.05 || v > rng[1] + 0.05)) return null;
    const i = nearestIndex(m.lv, v);
    const lv = m.lv[i];
    return {
      x: sx(lv), y: py, xLine: sx(lv),
      marks: (<>
        <circle cx={sx(lv)} cy={sy(m.glm.p[i])} r={4} style={{ fill: "var(--s1)", ...ring }} />
        <circle cx={sx(lv)} cy={sy(m.ols.p[i])} r={4} style={{ fill: "var(--s2)", ...ring }} />
      </>),
      content: (<><div className="t">ln V = {fixed(lv, 2)} <span className="muted">(≈ {compact(Math.exp(lv))} impr/h)</span></div>
        <TipRow color="var(--s1)" label="Binomial GLM" value={pct(m.glm.p[i], 3)} />
        <TipRow label="  95% band" value={`${pct(m.glm.lo[i], 2)} – ${pct(m.glm.hi[i], 2)}`} />
        <TipRow color="var(--s2)" label="OLS on logit(CTR)" value={pct(m.ols.p[i], 3)} /></>),
    };
  };
  return (
    <>
      <Plot height={height} x={xs} y={ys} yTickFmt={(v) => `${v}%`} xTitle="ln(impressions per campaign-hour)"
            yTitle="Predicted CTR, %" hover={hover} label="Marginal effect of volume on CTR">
        {({ sx, sy }) => {
          const X = m.lv.map(sx);
          return (
            <>
              {rng && <rect x={sx(rng[0])} y={sy(ys.domain[1])} width={sx(rng[1]) - sx(rng[0])} height={sy(0) - sy(ys.domain[1])}
                            style={{ fill: "var(--surface-3)" }} />}
              <g style={{ fill: "var(--pts)", opacity: 0.32 }}>
                {m.points.map(([x, y], i) => y <= ys.domain[1] && <circle key={i} cx={sx(x)} cy={sy(y)} r={1.6} />)}
              </g>
              <path d={bandPath(X, m.glm.lo.map(sy), m.glm.hi.map(sy))} style={{ fill: "var(--s1)", opacity: 0.16 }} />
              <path d={linePath(X.map((x, i) => [x, sy(m.ols.p[i])]))}
                    style={{ fill: "none", stroke: "var(--s2)", strokeWidth: 2, strokeDasharray: "7 4" }} />
              <path d={linePath(X.map((x, i) => [x, sy(m.glm.p[i])]))} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2 }} />
            </>
          );
        }}
      </Plot>
      <Legend items={[
        { label: `Binomial GLM, 95% band (β₁ ${signed(m.glm.beta, 3)})`, color: "var(--s1)" },
        { label: `OLS on logit(CTR) — naive (β₁ ${signed(m.ols.beta, 3)})`, color: "var(--s2)", kind: "dash", dash: "7 4" },
        { label: `Campaign-hours (${int(m.n_shown)} of ${int(m.n_points)} shown)`, color: "var(--pts)", kind: "dot" },
        ...(rng ? [{ label: "Typical within-campaign range of ln(V)", color: "var(--surface-3)", kind: "area" }] : []),
      ]} />
      <div className="chart-note">
        Prediction at the grand means of logit(CTR) and ln(V); time covariates at their means — same construction as fig. 4.
        {rng && <> Both slopes are within-campaign, so the curves are drawn only over the typical within-campaign range,
          ln V {fixed(rng[0], 2)}–{fixed(rng[1], 2)} (mean ln V plus the 5th–95th percentiles of deviations from the campaign
          mean, ≈ {fixed(m.doublings, 1)} doublings). y-axis capped at the 99th percentile ({pct(m.cap, 1)});
          {" "}{int(m.n_above)} observations above it are not shown.</>}
      </div>
    </>
  );
}

/* ── fig5 — curve fits to the five bucket means ──────────────────────────── */
export function CurvesChart({ curves, height = 300 }) {
  const { models, buckets } = curves;
  const ok = models.filter((mm) => mm.line);
  const [x0, x1] = extent(buckets.map((b) => b.mean_logv), 0.04);
  const [y0, y1] = extent([...buckets.map((b) => b.mean_ctr), ...ok.flatMap((mm) => mm.line.map((p) => p[1]))], 0.1);
  const hover = (px, py, { sx, sy }) => {
    const xv = buckets.map((b) => b.mean_logv);
    const i = nearestIndex(xv, sx.invert(px));
    const b = buckets[i];
    if (Math.abs(sx(b.mean_logv) - px) > 28) return null;
    return {
      x: sx(b.mean_logv), y: sy(b.mean_ctr),
      content: (<><div className="t">B{b.bucket} — observed bucket mean</div>
        <TipRow label="mean ln V" value={fixed(b.mean_logv, 3)} />
        <TipRow label="mean CTR" value={pct(b.mean_ctr, 3)} /></>),
    };
  };
  return (
    <>
      <Plot height={height} x={{ domain: [x0, x1] }} y={{ domain: niceDomain(y0, y1, 5) }} yTickFmt={(v) => `${+v.toFixed(2)}%`}
            xTitle="Mean ln(V) in bucket" yTitle="Mean CTR, %" hover={hover} label="Curve fits for hypotheses H1–H4">
        {({ sx, sy }) => (
          <>
            {ok.map((mm) => (
              <path key={mm.key} d={linePath(mm.line.map(([x, y]) => [sx(x), sy(y)]))}
                    style={{ fill: "none", stroke: HYP[mm.key]?.color, strokeWidth: mm.best ? 3 : 1.75,
                             strokeDasharray: HYP[mm.key]?.dash || undefined, strokeLinecap: "round" }} />
            ))}
            {buckets.map((b) => (
              <g key={b.bucket}>
                <rect x={sx(b.mean_logv) - 5} y={sy(b.mean_ctr) - 5} width={10} height={10} transform={`rotate(45 ${sx(b.mean_logv)} ${sy(b.mean_ctr)})`}
                      style={{ fill: "var(--ink)", ...ring }} />
                <text x={sx(b.mean_logv)} y={sy(b.mean_ctr) - 11} textAnchor="middle">B{b.bucket}</text>
              </g>
            ))}
          </>
        )}
      </Plot>
      <Legend items={[
        ...models.map((mm) => ({
          label: `${mm.key} ${HYP[mm.key]?.name || ""}${mm.failed ? " (no valid fit)" : mm.best ? " — best AIC" : ""}`,
          color: HYP[mm.key]?.color, kind: HYP[mm.key]?.dash ? "dash" : "line", dash: HYP[mm.key]?.dash, off: mm.failed,
        })),
        { label: "Observed bucket means", color: "var(--ink)", kind: "dot" },
      ]} />
      <div className="chart-note">Five points, three parameters per curve — illustrative only, as the script notes.</div>
    </>
  );
}

/* ── fig6 — campaigns + total vs within slope ────────────────────────────── */
export function BetweenChart({ campaigns, lines, height = 320, onPick }) {
  const maxObs = Math.max(...campaigns.map((c) => c.n_obs));
  const short = lines.within_doublings !== undefined;   // v4.2+: within slope as a segment, not a line across the cloud
  const rOf = (c) => 3 + 8 * Math.sqrt(c.n_obs / maxObs);
  const xs = { domain: extent(campaigns.map((c) => c.mean_logv), 0.05) };
  const ys = { domain: niceDomain(0, Math.max(...campaigns.map((c) => c.ctr), ...lines.total.map((p) => p[1])) * 1.04, 5) };
  const hover = (px, py, { sx, sy }) => {
    let best = null, bd = 24 * 24;
    for (const c of campaigns) {
      const d = (sx(c.mean_logv) - px) ** 2 + (sy(c.ctr) - py) ** 2;
      if (d < Math.max(bd, rOf(c) ** 2)) { bd = d; best = c; }
    }
    if (!best) return null;
    return {
      x: sx(best.mean_logv), y: sy(best.ctr), clickable: true, campaign: best.campaign,
      marks: <circle cx={sx(best.mean_logv)} cy={sy(best.ctr)} r={rOf(best) + 2} style={{ fill: "none", stroke: "var(--ink)", strokeWidth: 1.5 }} />,
      content: (<><div className="t">Campaign {best.campaign}</div>
        <TipRow label="CTR" value={pct(best.ctr, 3)} />
        <TipRow label="mean ln V" value={fixed(best.mean_logv, 2)} />
        <TipRow label="Campaign-hours" value={int(best.n_obs)} />
        <TipRow label="Impressions" value={compact(best.impr)} />
        {onPick && <div className="muted" style={{ marginTop: 3 }}>click → traffic graphs</div>}</>),
    };
  };
  return (
    <>
      <Plot height={height} x={xs} y={ys} yTickFmt={(v) => `${v}%`} xTitle="Campaign mean ln(V)" yTitle="Campaign CTR, %"
            hover={hover} onClick={onPick ? (t) => t.campaign && onPick(t.campaign) : undefined}
            label="Campaign CTR versus mean volume with total and within-campaign slopes">
        {({ sx, sy }) => (
          <>
            {campaigns.map((c) => (
              <circle key={c.campaign} cx={sx(c.mean_logv)} cy={sy(c.ctr)} r={rOf(c)}
                      style={{ fill: "var(--pts)", fillOpacity: 0.55, stroke: "var(--surface)", strokeWidth: 1.5 }} />
            ))}
            <path d={linePath(lines.total.map(([x, y]) => [sx(x), sy(y)]))}
                  style={{ fill: "none", stroke: "var(--s2)", strokeWidth: 2, strokeDasharray: "7 4" }} />
            {short ? (() => {
              const P = lines.within.map(([x, y]) => [sx(x), sy(y)]), ends = [P[0], P[P.length - 1]];
              return (
                <g>
                  <path d={linePath(P)} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 3.5, strokeLinecap: "butt" }} />
                  {ends.map(([x, y], k) => <line key={k} x1={x} x2={x} y1={y - 7} y2={y + 7} style={{ stroke: "var(--s1)", strokeWidth: 2 }} />)}
                </g>
              );
            })() : <path d={linePath(lines.within.map(([x, y]) => [sx(x), sy(y)]))} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2 }} />}
          </>
        )}
      </Plot>
      <Legend items={[
        { label: `Total slope, no campaign FE (β ${signed(lines.b_total, 3)})`, color: "var(--s2)", kind: "dash", dash: "7 4" },
        { label: `Within-campaign slope (β₁ ${signed(lines.b_within, 3)})${short ? `, over the typical within-campaign range (≈ ${fixed(lines.within_doublings, 1)} doublings)` : ""}`, color: "var(--s1)" },
        { label: "Campaigns (area ∝ √hours)", color: "var(--pts)", kind: "dot" },
      ]} />
      {short && <div className="chart-note">The within slope describes movement inside one campaign, not across these points, so it is drawn as a short segment at the centre of the cloud — same as fig. 6.</div>}
    </>
  );
}

/* ── fig7 — threshold sensitivity (β₁ ± CI) + zero-click share, as two charts ── */
export function ThresholdChart({ rows, height = 250 }) {
  const d = rows.filter((r) => /^impr >= \d+$/.test(r.Filter)).map((r) => ({ ...r, thr: +r.Filter.match(/\d+/)[0] }));
  if (!d.length) return <div className="empty">no threshold rows</div>;
  const vals = d.flatMap((r) => [r.glm_ci_lo, r.glm_ci_hi, r.ols_ci_lo, r.ols_ci_hi, 0]);
  const ys = { domain: niceDomain(...extent(vals, 0.08), 5) };
  const xs = { domain: [-0.5, d.length - 0.5] };
  const xt = d.map((_, i) => i);
  const fx = (i) => (d[i] ? `≥ ${d[i].thr}` : "");
  const hover = (px, py, { sx }) => {
    const i = Math.max(0, Math.min(d.length - 1, Math.round(sx.invert(px))));
    const r = d[i];
    return {
      x: sx(i), y: py,
      content: (<><div className="t">impressions ≥ {r.thr} per hour</div>
        <TipRow color="var(--s1)" kind="dot" label="GLM β₁" value={`${signed(r["GLM β₁"])} ${stars(r["GLM p"])}`} />
        <TipRow color="var(--s2)" kind="dot" label="OLS β₁" value={`${signed(r["OLS-logit β₁"])} ${stars(r["OLS p"])}`} />
        <TipRow label="Zero-click hours" value={share(r["Zero-click share (all)"])} />
        <TipRow label="N obs" value={int(r["N obs"])} /></>),
    };
  };
  const series = [["GLM", "GLM β₁", "glm_ci_lo", "glm_ci_hi", -7, "var(--s1)"], ["OLS", "OLS-logit β₁", "ols_ci_lo", "ols_ci_hi", 7, "var(--s2)"]];
  return (
    <>
      <Plot height={height} x={xs} y={ys} xTicks={xt} xTickFmt={fx} yTickFmt={(v) => fixed(v, 2)} yTitle="β₁ on ln(V)"
            hover={hover} label="Slope estimates by minimum-impression threshold">
        {({ sx, sy }) => (
          <>
            <line className="zero" x1={0} x2={sx(d.length - 0.5)} y1={sy(0)} y2={sy(0)} />
            {series.map(([k, b, lo, hi, off, col]) => (
              <g key={k}>
                <path d={linePath(d.map((r, i) => [sx(i) + off, sy(r[b])]))} style={{ fill: "none", stroke: col, strokeWidth: 1.5, opacity: 0.6, strokeDasharray: k === "OLS" ? "5 3" : undefined }} />
                {d.map((r, i) => (
                  <g key={i}>
                    <line x1={sx(i) + off} x2={sx(i) + off} y1={sy(r[lo])} y2={sy(r[hi])} style={{ stroke: col, strokeWidth: 1.5 }} />
                    <circle cx={sx(i) + off} cy={sy(r[b])} r={4.5} style={{ fill: k === "OLS" ? "var(--surface)" : col, stroke: col, strokeWidth: 2 }} />
                  </g>
                ))}
              </g>
            ))}
          </>
        )}
      </Plot>
      <Legend items={[{ label: "Binomial GLM, 95% CI", color: "var(--s1)", kind: "dot" },
                      { label: "OLS on logit(CTR), 95% CI", color: "var(--s2)", kind: "dash", dash: "5 3" }]} />
      <div className="chart-note" style={{ margin: "10px 0 4px" }}>Share of zero-click hours remaining at each threshold</div>
      <Plot height={120} x={xs} y={{ domain: niceDomain(0, Math.max(...d.map((r) => r["Zero-click share (all)"] * 100)) * 1.1, 3) }}
            xTicks={xt} xTickFmt={fx} yTickFmt={(v) => `${v}%`} hover={hover} label="Zero-click share by threshold">
        {({ sx, sy }) => d.map((r, i) => {
          const v = r["Zero-click share (all)"] * 100, bw = 24, x0 = sx(i) - bw / 2, y = sy(v), y0 = sy(0);
          const rad = Math.min(4, (y0 - y) / 2);
          return <path key={i} style={{ fill: "var(--muted)", opacity: 0.7 }}
            d={`M${x0},${y0}V${y + rad}Q${x0},${y} ${x0 + rad},${y}H${x0 + bw - rad}Q${x0 + bw},${y} ${x0 + bw},${y + rad}V${y0}Z`} />;
        })}
      </Plot>
    </>
  );
}

/* ── forest plot of every robustness estimate ────────────────────────────── */
export function ForestChart({ groups, hypOf }) {
  const [ref, width] = useMeasure();
  const [hov, setHov] = useState(null);
  const rows = groups.flatMap((g) => [{ header: g.title }, ...g.rows]);
  const est = rows.filter((r) => !r.header);
  const [lo, hi] = extent(est.flatMap((r) => [r.lo, r.hi, 0]), 0.06);
  const labelW = Math.min(300, Math.max(150, width * 0.36)), valW = 128, rowH = 24;
  const plotW = Math.max(80, width - labelW - valW - 10);
  const sx = (v) => labelW + ((v - lo) / (hi - lo)) * plotW;
  const H = rows.length * rowH + 26;
  const xt = (() => { const s = (hi - lo) / 4; return [lo + s * 0.5, 0, hi - s * 0.5].filter((v, i, a) => i === 1 || Math.abs(v) > s * 0.6); })();
  return (
    <div className="chart" ref={ref} style={{ height: H }}>
      {width > 0 && (
        <svg width={width} height={H} role="img" aria-label="Forest plot of robustness estimates" onPointerLeave={() => setHov(null)}>
          <line className="zero" x1={sx(0)} x2={sx(0)} y1={0} y2={rows.length * rowH} />
          {xt.map((t) => <text key={t} x={sx(t)} y={rows.length * rowH + 16} textAnchor="middle">{fixed(t, 2)}</text>)}
          {rows.map((r, i) => {
            const y = i * rowH + rowH / 2;
            if (r.header) {
              return <text key={i} x={0} y={y + 4} style={{ fill: "var(--ink)", fontWeight: 650, fontSize: 11 }}>{r.header}</text>;
            }
            const hy = hypOf?.(r);
            const col = hy ? `var(--h${hy[1]})` : "var(--ink-2)";
            return (
              <g key={i} onPointerEnter={() => setHov(i)}>
                <rect x={0} y={i * rowH} width={width} height={rowH} style={{ fill: hov === i ? "var(--hover)" : "transparent" }} />
                <text x={4} y={y + 4} style={{ fill: "var(--ink-2)", fontSize: 11 }}>
                  {r.label.length > labelW / 6.2 ? `${r.label.slice(0, Math.floor(labelW / 6.2) - 1)}…` : r.label}
                  <title>{r.full || r.label}</title>
                </text>
                {r.lo !== null && r.hi !== null && (
                  <line x1={sx(r.lo)} x2={sx(r.hi)} y1={y} y2={y} style={{ stroke: col, strokeWidth: 2, strokeLinecap: "round" }} />
                )}
                {r.b !== null && (r.est === "WLS"
                  ? <rect x={sx(r.b) - 4.5} y={y - 4.5} width={9} height={9} rx={1.5} style={{ fill: col, stroke: "var(--surface)", strokeWidth: 1.5 }} />
                  : <circle cx={sx(r.b)} cy={y} r={4.5} style={{ fill: r.est === "OLS" ? "var(--surface)" : col, stroke: col, strokeWidth: 2 }} />)}
                <text x={width - 4} y={y + 4} textAnchor="end" style={{ fontFamily: "var(--font-mono)", fontSize: 10.5, fill: "var(--ink-2)" }}>
                  {signed(r.b, 3)} {stars(r.p)}
                </text>
              </g>
            );
          })}
        </svg>
      )}
      {hov !== null && !rows[hov]?.header && (
        <div className="tip" style={{ top: hov * rowH + 26, left: Math.min(width - 260, labelW * 0.4) }}>
          <div className="t">{rows[hov].full || rows[hov].label}</div>
          <TipRow label={`${rows[hov].est} β₁`} value={signed(rows[hov].b)} />
          <TipRow label="95% CI" value={`${signed(rows[hov].lo)} … ${signed(rows[hov].hi)}`} />
          <TipRow label="p" value={`${pval(rows[hov].p)} ${stars(rows[hov].p)}`} />
          <TipRow label="supports" value={hypOf?.(rows[hov]) || "—"} />
        </div>
      )}
    </div>
  );
}
