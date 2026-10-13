import { useApp } from "../App";
import { go } from "../hooks";
import { compact, fixed, int, pct, pval, share, signed, stars } from "../format";
import { ChartCard, CheckLabel, DataTable, HYP_INFO, Panel, RecordsTable, Seg, Tile, Weight } from "../components/ui";
import { BetweenChart, BoxChart, CurvesChart, ForestChart, MarginalChart, MeanCiChart, ThresholdChart } from "../charts/Analysis";
import { HourProfile } from "../charts/Mrtg";
import { useResult } from "./common";

const TABS = [
  { value: "buckets", label: "Buckets & trend" },
  { value: "marginal", label: "Regression" },
  { value: "curves", label: "Curve fits" },
  { value: "between", label: "Total vs within" },
  { value: "threshold", label: "Threshold" },
  { value: "forest", label: "Robustness" },
];

export default function Analysis() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  if (block) return block;
  if (res.mode === "legacy") return <div className="alert info">Legacy run — open Figures &amp; Tables for the script's own outputs.</div>;
  const tab = TABS.some((t) => t.value === ctx.route.parts[0]) ? ctx.route.parts[0] : "buckets";
  const View = { buckets: Buckets, marginal: Regression, curves: Curves, between: Between, threshold: Threshold, forest: Forest }[tab];
  return (
    <>
      <div className="filters">
        <Seg value={tab} onChange={(v) => go(`analysis/${v}`)} options={TABS} label="Analysis section" />
      </div>
      <View res={res} />
    </>
  );
}

const check = (res, id) => res.checks?.services.find((s) => s.id === id);
const Label = ({ res, id }) => { const c = check(res, id); return c ? <><CheckLabel s={c} sm /> <Weight w={c.weight} /></> : null; };

function Buckets({ res }) {
  const ch = res.charts, t = res.trend;
  const ca = t.cochran_armitage, sp = t.spearman;
  return (
    <>
      <div className="grid g2">
        <ChartCard title="Hourly CTR by impression-volume bucket" sub="fig. 1 · distribution"
          chart={<BoxChart box={ch.box} />}
          table={<DataTable rows={ch.box.buckets} columns={[
            { key: "bucket", label: "Bucket" },
            { key: "range", label: "impr / h", render: (r) => r.range ? `${compact(r.range[0])} – ${r.range[1] === null ? "∞" : compact(r.range[1])}` : "—", sort: false },
            { key: "n", label: "N", num: true, fmt: int },
            { key: "q1", label: "Q1 %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "median", label: "Median %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "q3", label: "Q3 %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "mean", label: "Mean %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "zero_click_share", label: "Zero-click", num: true, fmt: (v) => share(v) },
          ]} />} />
        <ChartCard title="Mean hourly CTR with 95% CI" sub="fig. 2 · ±1.96·SEM"
          chart={<MeanCiChart rows={ch.mean_ci} />}
          table={<DataTable rows={ch.mean_ci} columns={[
            { key: "bucket", label: "Bucket" }, { key: "n", label: "N", num: true, fmt: int },
            { key: "mean", label: "Mean %", num: true, fmt: (v) => fixed(v, 4) },
            { key: "lo", label: "CI lo %", num: true, fmt: (v) => fixed(v, 4) },
            { key: "hi", label: "CI hi %", num: true, fmt: (v) => fixed(v, 4) },
          ]} />} />
      </div>
      <div className="grid g2">
        <Panel title="Trend tests" sub="§4.3 · pooled across campaigns">
          <div className="tiles" style={{ gridTemplateColumns: "repeat(2, minmax(0,1fr))" }}>
            <Tile label="Cochran–Armitage Z" value={<>{fixed(ca.Z_CA, 3)} <Label res={res} id="trend/cochran_armitage" /></>}
                  foot={<>p = {pval(ca.p)} {stars(ca.p)} · {ca.direction} → {ca.supports}<div className="caveat">⚠ {ca.note}</div></>} />
            <Tile label="Spearman ρ (bucket means)" value={<>{fixed(sp.rho, 3)} <Label res={res} id="trend/spearman_buckets" /></>}
                  foot={<>p = {pval(sp.p)} {stars(sp.p)} → {sp.supports}<div className="caveat">⚠ {sp.note}</div></>} />
          </div>
        </Panel>
        <ChartCard title="Descriptive statistics" sub="table 2 · CTR % per bucket" chart={
          <RecordsTable columns={Object.keys(res.descriptive[0] || {})} rows={res.descriptive} />} />
      </div>
      <Panel title="Hour-of-day pattern" sub="fig. 3 · split into two charts (one y-axis each)">
        <HourProfile rows={ch.hourly.map((r) => ({ hour: r.hour, impr_h: r.mean_impr, ctr: r.mean_ctr }))} ctrLabel="Mean hourly CTR" />
      </Panel>
    </>
  );
}

function coefRows(reg) {
  const row = (model, role, e, extra = {}) => ({ model, role, b: e.b, lo: e.lo, hi: e.hi, p: e.p, ...extra });
  return [
    row("M1 linear — within", "primary", reg.within, { qaic: reg.within.qaic, r2: reg.within.pseudo_r2, supports: reg.within.supports }),
    row("M2 quadratic — β₁", "primary", reg.quadratic.b1, { qaic: reg.quadratic.qaic, r2: reg.quadratic.pseudo_r2 }),
    row("M2 quadratic — β₂ (ln V²)", "primary", reg.quadratic.b2, { supports: reg.quadratic.supports }),
    row("MT total — no campaign FE", "pooled", reg.total, { r2: reg.total.pseudo_r2 }),
    row("OLS logit(CTR) — M1", "naive", reg.ols.m1, { r2: reg.ols.m1.r2, supports: reg.ols.m1.supports }),
    row("OLS logit(CTR) — M2 β₂", "naive", reg.ols.m2.b2),
  ];
}

function Regression({ res }) {
  const reg = res.regression;
  const cols = [
    { key: "model", label: "Model" }, { key: "role", label: "Role", render: (r) => <span className="tag">{r.role}</span> },
    { key: "b", label: "β", num: true, fmt: (v) => signed(v) },
    { key: "ci", label: "95% CI", num: true, sort: false, render: (r) => `[${signed(r.lo)}, ${signed(r.hi)}]` },
    { key: "p", label: "p", num: true, fmt: pval }, { key: "sig", label: "", sort: false, render: (r) => stars(r.p) },
    { key: "qaic", label: "QAIC", num: true, fmt: (v) => fixed(v, 1) },
    { key: "r2", label: "(pseudo-)R²", num: true, fmt: (v) => fixed(v, 4) },
    { key: "supports", label: "→", render: (r) => r.supports || "" },
  ];
  return (
    <>
      <ChartCard title="Marginal effect of volume on CTR" sub="fig. 4 · binomial GLM vs naive OLS"
        chart={<MarginalChart m={res.charts.marginal} />}
        table={<DataTable rows={res.charts.marginal.lv.map((lv, i) => ({ lv, glm: res.charts.marginal.glm.p[i], lo: res.charts.marginal.glm.lo[i], hi: res.charts.marginal.glm.hi[i], ols: res.charts.marginal.ols.p[i] })).filter((_, i) => i % 6 === 0)}
          columns={[{ key: "lv", label: "ln V", num: true, fmt: (v) => fixed(v, 2) }, { key: "glm", label: "GLM %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "lo", label: "band lo", num: true, fmt: (v) => fixed(v, 3) }, { key: "hi", label: "band hi", num: true, fmt: (v) => fixed(v, 3) },
            { key: "ols", label: "OLS %", num: true, fmt: (v) => fixed(v, 3) }]} />} />
      <Panel title="Coefficients on ln(V)" sub="§4.4 · clustered SE by campaign" flush>
        <DataTable rows={coefRows(reg)} columns={cols} />
        <div className="chart-note" style={{ padding: "8px 14px 12px" }}>
          Overdispersion φ = {fixed(reg.phi, 2)} — raw AIC is not comparable; ΔQAIC(M2−M1) = {fixed(reg.quadratic.dqaic, 1)}
          {" "}(raw ΔAIC {fixed(reg.quadratic.daic, 1)}). Odds ratio per doubling of impressions (within): {fixed(reg.within.or_doubling[0], 4)}.
        </div>
      </Panel>
    </>
  );
}

function Curves({ res }) {
  const models = res.curves.models;
  return (
    <ChartCard title="Hypothesis curves fitted to the five bucket means" sub="fig. 5 · §4.5"
      chart={<><CurvesChart curves={res.curves} />
        <div style={{ marginTop: 12 }}><DataTable rows={models} columns={[
          { key: "model", label: "Model" }, { key: "params", label: "Params", className: "mono" },
          { key: "k", label: "k", num: true }, { key: "r2", label: "R²", num: true, fmt: (v) => fixed(v, 4) },
          { key: "rmse", label: "RMSE", num: true, fmt: (v) => fixed(v, 5) }, { key: "aic", label: "AIC", num: true, fmt: (v) => fixed(v, 2) },
          { key: "bic", label: "BIC", num: true, fmt: (v) => fixed(v, 2) },
          { key: "best", label: "Best", render: (r) => r.failed ? <span className="tag">failed</span> : r.best ? <span className="tag outline">best AIC</span> : "" },
        ]} /></div></>}
      table={<DataTable rows={res.curves.buckets} columns={[{ key: "bucket", label: "Bucket", fmt: (v) => `B${v}` },
        { key: "mean_logv", label: "mean ln V", num: true, fmt: (v) => fixed(v, 4) }, { key: "mean_ctr", label: "mean CTR %", num: true, fmt: (v) => fixed(v, 4) }]} />} />
  );
}

function Between({ res }) {
  const dec = res.regression.decomposition, bc = res.between.stats;
  return (
    <div className="grid g-side">
      <ChartCard title="Campaign CTR vs mean volume" sub="fig. 6 · click a campaign for its traffic graphs"
        chart={<BetweenChart campaigns={res.between.campaigns} lines={res.charts.between} onPick={(c) => go(`graphs/${encodeURIComponent(c)}`)} />}
        table={<DataTable rows={res.between.campaigns} maxHeight={420} initialSort={{ key: "impr", dir: "desc" }} columns={[
          { key: "campaign", label: "Campaign", className: "mono" }, { key: "n_obs", label: "Hours", num: true, fmt: int },
          { key: "impr", label: "Impr", num: true, fmt: (v) => compact(v) }, { key: "ctr", label: "CTR %", num: true, fmt: (v) => fixed(v, 3) },
          { key: "mean_logv", label: "mean ln V", num: true, fmt: (v) => fixed(v, 3) }]} />} />
      <Panel title="Decomposition" sub="§4.7 — not a hypothesis test; compares pooled and within slopes">
        <dl className="kv" style={{ fontSize: 12.5 }}>
          <dt>β_total</dt><dd className="mono">{signed(dec.b_total)} {stars(dec.p_total)} <span className="muted">p={pval(dec.p_total)}</span></dd>
          <dt>β_within</dt><dd className="mono">{signed(dec.b_within)} {stars(dec.p_within)} <span className="muted">p={pval(dec.p_within)}</span></dd>
          <dt>composition</dt><dd className="mono">{signed(dec.diff)}</dd>
          <dt>Spearman ρ</dt><dd className="mono">{signed(bc.spearman_rho, 3)} <span className="muted">p={pval(bc.spearman_p)}</span></dd>
          <dt>Kendall τ</dt><dd className="mono">{signed(bc.kendall_tau, 3)} <span className="muted">p={pval(bc.kendall_p)}</span></dd>
          <dt>Campaigns</dt><dd className="mono">{int(bc.n_campaigns)}</dd>
        </dl>
        <div className={`verdict ${dec.expected ? "ok" : "warn"}`} style={{ marginTop: 12 }}>{dec.message}</div>
        <div className="chart-note">β_total − β_within is the between-campaign (composition) component, in logit-per-ln(V) units.</div>
      </Panel>
    </div>
  );
}

function Threshold({ res }) {
  const rows = res.robustness.threshold;
  return (
    <ChartCard title="Sensitivity to the minimum-impression threshold" sub="fig. 7 · §4.6d — GLM should stay put, naive OLS should move"
      chart={<ThresholdChart rows={rows} />}
      table={<RecordsTable columns={Object.keys(rows[0] || {}).filter((c) => !c.includes("ci_"))} rows={rows} />} />
  );
}

function Forest({ res }) {
  const rb = res.robustness;
  const both = (r, name) => [
    { label: `${name} · GLM`, est: "GLM", b: r["GLM β₁"], lo: r.glm_ci_lo, hi: r.glm_ci_hi, p: r["GLM p"] },
    { label: `${name} · OLS`, est: "OLS", b: r["OLS-logit β₁"], lo: r.ols_ci_lo, hi: r.ols_ci_hi, p: r["OLS p"] },
  ];
  const groups = [
    { title: "Specification (§4.6b)", rows: rb.spec.map((r) => ({
      label: r.Role, full: r.Specification, est: r.Specification.startsWith("WLS") ? "WLS" : r.Specification.includes("GLM") ? "GLM" : "OLS",
      b: r["β₁"], lo: r.ci_lo, hi: r.ci_hi, p: r.p })) },
    { title: "Campaign size quartiles (§4.6a)", caveat: true, rows: rb.size.flatMap((r) => both(r, r.Quartile)) },
    { title: "Temporal halves (§4.6c)", rows: rb.temporal.flatMap((r) => both(r, r.Period)) },
    { title: "Min-impression threshold (§4.6d)", rows: rb.threshold.flatMap((r) => both(r, r.Filter)) },
  ];
  const hypOf = (r) => (r.b === null || r.p === null ? null : r.p >= 0.05 ? "H4" : r.b > 0 ? "H3" : "H1");
  return (
    <>
      <Panel title="Every β₁ on ln(V) in the robustness battery" sub="point = estimate, line = 95% CI, colour = hypothesis it supports">
        <ForestChart groups={groups} hypOf={hypOf} />
        <div className="legend" style={{ marginTop: 8 }}>
          <span>Colour = hypothesis supported:</span>
          {["H1", "H3", "H4"].map((h) => <span key={h}><i className="key dot" style={{ background: `var(--h${h[1]})` }} />{h} {HYP_INFO[h].short}</span>)}
          <span className="muted">· marker = model: ● GLM, ○ OLS (naive), ■ WLS</span>
        </div>
      </Panel>
      <div className="grid g2">
        <ChartCard title="Campaign size quartiles" sub="table 6" chart={<RecordsTable columns={Object.keys(rb.size[0] || {}).filter((c) => !c.includes("ci_"))} rows={rb.size} />} />
        <ChartCard title="Temporal halves" sub="table 8" chart={<RecordsTable columns={Object.keys(rb.temporal[0] || {}).filter((c) => !c.includes("ci_"))} rows={rb.temporal} />} />
      </div>
      <ChartCard title="Specification variants" sub="table 7" chart={<RecordsTable columns={Object.keys(rb.spec[0] || {}).filter((c) => !c.includes("ci_"))} rows={rb.spec} />} />
    </>
  );
}
