import { useApp } from "../App";
import { api } from "../api";
import { go, href, useAsync, useStored } from "../hooks";
import { compact, conclusion, fixed, int, pct, pval, share, signed, stars } from "../format";
import { CheckLabel, Empty, Hyp, HYP_ORDER, Panel, Tile, Weight } from "../components/ui";
import UploadForm from "../components/UploadForm";
import { MrtgWindow } from "../charts/Mrtg";
import { HYP } from "../charts/Analysis";
import { NoRun } from "./common";

const EQ = {
  H1: "CTR = a·exp(−b·V) + g", H2: "CTR = a·V^b·exp(−g·V)", H3: "CTR = g − a·exp(−b·V)", H4: "CTR = μ",
};

function evidence(res) {
  const r = res.regression, t = res.trend;
  const first = (s) => (String(s || "").match(/^H\d/) || [null])[0];
  const best = res.curves.models.find((m) => m.best);
  return [
    { h: conclusion(r.within.b, r.within.p), label: "GLM within", kind: "primary", view: "analysis/marginal" },
    { h: r.quadratic.supports?.startsWith("H2") ? "H2" : null, label: "GLM quadratic", kind: "primary", view: "analysis/curves" },
    { h: conclusion(r.total.b, r.total.p), label: "GLM total (pooled)", kind: "pooled", view: "analysis/between" },
    { h: conclusion(r.ols.m1.b, r.ols.m1.p), label: "OLS logit", kind: "naive", view: "analysis/marginal" },
    { h: first(t.cochran_armitage.supports), label: "Cochran–Armitage", kind: "descriptive", view: "analysis/buckets" },
    { h: first(t.spearman.supports), label: "Spearman (5 means)", kind: "low power", view: "analysis/buckets" },
    { h: best?.key, label: "Curve fit (best AIC)", kind: "illustrative", view: "analysis/curves" },
  ].filter((e) => e.h);
}

export function UploadPanel() {
  const { info, refresh } = useApp();
  const [open, setOpen] = useStored("ctr.upload.open", true);
  return (
    <Panel title="Upload data & run analysis" sub={open ? "mapping + hourly events → new run" : "collapsed"}
           tools={<button type="button" className="btn sm ghost" onClick={() => setOpen(!open)} aria-expanded={open}>{open ? "Hide ▴" : "Show ▾"}</button>}
           className={open ? "" : "collapsed"}>
      {open && <UploadForm info={info} compact onCreated={(r) => { refresh(); go(`runs/${r.id}`); }} />}
    </Panel>
  );
}

export default function Overview() {
  const { run, res, resErr, runs } = useApp();
  if (!run) return <NoRun runs={runs} />;
  return <OverviewBody run={run} res={res} resErr={resErr} />;
}

function OverviewBody({ res, resErr }) {
  if (resErr) return <div className="alert err">Could not load results: {resErr.message}</div>;
  if (!res) return <Empty title="Loading results…" />;
  if (res.mode === "legacy") {
    return (
      <Panel title="Legacy run">
        <p>The analysis script in this run did not expose the functions the structured view needs, so only its own
          outputs are available — see <a href={href("summary")}>Results Summary</a> and <a href={href("files")}>Figures &amp; Tables</a>.</p>
      </Panel>
    );
  }

  const ds = res.dataset, reg = res.regression, w = reg.within, dec = reg.decomposition;
  const svc = res.checks.services;
  const primary = res.checks.primary;
  const nHyp = res.checks.n_hypothesis;
  const dissent = svc.filter((s) => s.kind === "hypothesis" && s.supported && s.hyp && s.hyp !== primary)
    .sort((a, b) => HYP_ORDER[a.hyp] - HYP_ORDER[b.hyp]);
  const ev = evidence(res);
  const lead = conclusion(w.b, w.p);
  const pooled = ds.totals ? ds.totals.clicks / ds.totals.impr * 100 : null;

  return (
    <>
      <div className="grid g-side">
        <Panel title="Within-campaign effect of impression volume on CTR" sub="primary specification · §4.4"
               tools={primary && <Hyp h={primary} />}>
          <div className="hero">
            <div>
              <div className="muted" style={{ fontSize: 11.5, marginBottom: 4 }}>β₁ on ln(V), binomial GLM</div>
              <div className="big">{signed(w.b, 3)}<small>{stars(w.p)}</small></div>
              <div className="mono muted" style={{ marginTop: 6 }}>95% CI [{signed(w.lo, 3)}, {signed(w.hi, 3)}] · p = {pval(w.p)}</div>
            </div>
            <dl className="kv" style={{ fontSize: 12.5, marginTop: 4 }}>
              <dt>Verdict</dt><dd><b>{w.supports}</b></dd>
              <dt>Odds ratio per 2× volume</dt><dd className="mono">{fixed(w.or_doubling[0], 4)} [{fixed(w.or_doubling[1], 4)}, {fixed(w.or_doubling[2], 4)}]</dd>
              <dt>Pooled slope (no campaign FE)</dt><dd className="mono">{signed(reg.total.b, 4)} {stars(reg.total.p)}</dd>
              <dt>Naive OLS slope</dt><dd className="mono">{signed(reg.ols.m1.b, 4)} {stars(reg.ols.m1.p)}</dd>
              <dt>H2 (quadratic)</dt><dd>{reg.quadratic.supports}</dd>
              <dt>Fit</dt><dd className="mono">pseudo-R² {fixed(w.pseudo_r2, 4)} · QAIC {fixed(w.qaic, 1)} · N {int(w.nobs)}</dd>
            </dl>
          </div>
          <div className={`verdict ${dec.expected ? "ok" : "warn"}`} style={{ marginTop: 14 }}>
            <b>Total vs within (§4.7):</b> β_total {signed(dec.b_total, 4)} {stars(dec.p_total)} − β_within {signed(dec.b_within, 4)} {stars(dec.p_within)} = {signed(dec.diff, 4)} composition. {dec.message}
          </div>
        </Panel>
        <Panel title="Estimates that disagree" sub={`${dissent.length} of ${nHyp} point away from ${primary || "the primary result"}`} flush
               tools={<a className="btn sm" href={`${href("services")}?filter=disagree`}>details</a>}>
          {dissent.length === 0 ? <Empty title={`All estimates agree on ${primary}`} /> : (
            <div style={{ maxHeight: 330, overflowY: "auto" }}>
              {dissent.map((s) => (
                <a key={s.id} href={`${href("services")}?focus=${encodeURIComponent(s.id)}`}
                   style={{ display: "grid", gridTemplateColumns: "118px minmax(0,1fr)", gap: 10, padding: "8px 14px", borderBottom: "1px solid var(--border)", color: "inherit", textDecoration: "none" }}>
                  <span style={{ display: "flex", flexDirection: "column", gap: 3, alignItems: "flex-start" }}>
                    <CheckLabel s={s} sm /><Weight w={s.weight} />
                  </span>
                  <span style={{ minWidth: 0 }}>
                    <div style={{ fontWeight: 600, fontSize: 12 }}>{s.host} <span className="muted">/</span> {s.service}</div>
                    <div className="mono muted" style={{ fontSize: 11, overflowWrap: "anywhere" }}>{s.output}</div>
                  </span>
                </a>
              ))}
            </div>
          )}
        </Panel>
      </div>

      <div className="tiles">
        <Tile label="Campaign-hours analysed" value={int(ds.n_final)} foot={`${int(ds.n_raw)} raw event rows`} />
        <Tile label="Campaigns" value={int(ds.n_campaigns)} foot={`${int(ds.n_banners)} banners`} />
        <Tile label="Date range" value={<span style={{ fontSize: 14 }}>{ds.date_range}</span>} />
        <Tile label="Impressions" value={compact(ds.totals?.impr)} foot={`${compact(ds.totals?.clicks)} clicks`} />
        <Tile label="Pooled CTR" value={pct(pooled, 3)} />
        <Tile label="Zero-click hours" value={share(ds.zero_click_share)} />
        <Tile label="Overdispersion φ" value={fixed(reg.phi, 2)} foot="Pearson χ²/df" />
        <Tile label="Min impressions / h" value={int(ds.min_impr)} foot="inclusion threshold" />
      </div>

      <Panel title="Hypothesis board" sub="which estimate points where — the primary specification is outlined">
        <div className="hyp">
          {["H1", "H2", "H3", "H4"].map((h) => {
            const items = ev.filter((e) => e.h === h);
            return (
              <div key={h} className={`card${h === lead ? " lead" : ""}`}>
                <h4><span className="k">{h}</span>{HYP[h].name}</h4>
                <div className="eq">{EQ[h]}</div>
                <div className="ev">
                  {items.length === 0 && <span className="muted" style={{ fontSize: 11.5 }}>no support</span>}
                  {items.map((e) => (
                    <a key={e.label} href={href(...e.view.split("/"))} className={`tag ${e.kind === "primary" ? "primary" : ""}`}
                       title={e.kind}>{e.label}{e.kind !== "primary" && <span style={{ opacity: 0.65 }}> · {e.kind}</span>}</a>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </Panel>

      <OverviewTraffic />
    </>
  );
}

function OverviewTraffic() {
  const { run } = useApp();
  const m = useAsync(() => api.mrtg(run.id), [run.id]);
  const w = m.data?.windows?.find((x) => x.key === "weekly");
  return (
    <Panel title="All campaigns — traffic" sub="MRTG view of the hourly panel" tools={<a className="btn sm" href={href("graphs")}>all graphs</a>}>
      {m.error ? <div className="alert err">{m.error.message}</div> : !w ? <Empty title="Loading…" /> : <MrtgWindow w={w} compactMode />}
    </Panel>
  );
}
