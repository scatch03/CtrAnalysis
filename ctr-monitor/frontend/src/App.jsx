import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import UploadDialog from "./components/UploadDialog";
import EvidenceTally from "./components/EvidenceTally";
import { api } from "./api";
import { go, href, useInterval, useRoute, useStored } from "./hooks";
import { ago, fixed, int, localTime, pval, runDuration, signed, stars } from "./format";
import { Hyp, HYP_INFO, Icon, RunStatus, Seg } from "./components/ui";
import Overview, { UploadPanel } from "./pages/Overview";
import Services from "./pages/Services";
import Graphs from "./pages/Graphs";
import Analysis from "./pages/Analysis";
import Campaigns from "./pages/Campaigns";
import PlainSummary from "./components/PlainSummary";
import QuartileCards from "./components/QuartileCards";
import Summary from "./pages/Summary";
import Files from "./pages/Files";
import Runs from "./pages/Runs";

const Ctx = createContext(null);
export const useApp = () => useContext(Ctx);

const PAGES = {
  overview: { title: "Tactical Overview", C: Overview, strip: true, top: UploadPanel },
  services: { title: "Estimates by Hypothesis", C: Services, strip: true },
  campaigns: { title: "Campaigns", C: Campaigns },
  graphs: { title: "Traffic Graphs", C: Graphs },
  analysis: { title: "Analysis", C: Analysis },
  summary: { title: "Results Summary", C: Summary },
  files: { title: "Figures & Tables", C: Files },
  runs: { title: "Runs", C: Runs },
};

function useTheme() {
  const [theme, setTheme] = useStored("ctr.theme", "auto");
  useEffect(() => {
    const el = document.documentElement;
    if (theme === "auto") el.removeAttribute("data-theme");
    else el.setAttribute("data-theme", theme);
  }, [theme]);
  return [theme, setTheme];
}

export default function App() {
  const route = useRoute();
  const [theme, setTheme] = useTheme();
  const [info, setInfo] = useState(null);
  const [runs, setRuns] = useState(null);
  const [runsErr, setRunsErr] = useState(null);
  const [selected, setSelected] = useStored("ctr.run", null);
  const [result, setResult] = useState({ id: null, data: null, error: null });
  const [menu, setMenu] = useState(false);
  const [uploadOpen, setUploadOpen] = useState(false);
  const openUpload = useCallback(() => setUploadOpen(true), []);

  const refresh = useCallback(() => api.runs().then((r) => { setRuns(r); setRunsErr(null); }, setRunsErr), []);
  useEffect(() => { refresh(); api.info().then(setInfo, () => {}); }, [refresh]);
  const active = (runs || []).filter((r) => r.status === "queued" || r.status === "running");
  useInterval(refresh, active.length ? 2000 : 15000);
  useInterval(() => api.info().then(setInfo, () => {}), 30000);

  const done = (runs || []).filter((r) => r.status === "ok");
  const run = (runs || []).find((r) => r.id === selected && r.status === "ok") || done[0] || null;

  // load the selected run's result
  useEffect(() => {
    if (!run || run.id === result.id) return;
    setResult({ id: run.id, data: null, error: null });
    api.result(run.id).then((data) => setResult({ id: run.id, data, error: null }),
      (error) => setResult({ id: run.id, data: null, error }));
  }, [run?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // a freshly finished run becomes the selection
  const [prevActive, setPrevActive] = useState([]);
  useEffect(() => {
    const ids = active.map((r) => r.id);
    const finished = prevActive.filter((id) => !ids.includes(id));
    const ok = finished.map((id) => (runs || []).find((r) => r.id === id)).find((r) => r?.status === "ok");
    if (ok) setSelected(ok.id);
    if (ids.join() !== prevActive.join()) setPrevActive(ids);
  }, [runs]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { setMenu(false); window.scrollTo(0, 0); }, [route.page]);

  const page = PAGES[route.page] || PAGES.overview;
  const res = result.id === run?.id ? result.data : null;
  const ctx = useMemo(() => ({ info, runs, run, res, resErr: result.error, route, refresh, select: setSelected, openUpload }),
    [info, runs, run, res, result.error, route, refresh, setSelected, openUpload]);
  const C = page.C;

  return (
    <Ctx.Provider value={ctx}>
      <div className="app">
        <Sidebar page={route.page} open={menu} info={info} primary={res?.checks?.primary} active={active} nCampaigns={res?.dataset?.n_campaigns} />
        <div className="main">
          <header className="topbar">
            <button className="btn ghost menu-btn" onClick={() => setMenu((m) => !m)} aria-label="Menu">☰</button>
            <div className="crumb">{page.title}{run && page !== PAGES.runs && <span className="muted"> · {run.label}</span>}</div>
            <div className="spacer" />
            {done.length > 0 && (
              <label className="run-select">
                <span className="muted" style={{ fontSize: 11.5 }}>Run</span>
                <select value={run?.id || ""} onChange={(e) => setSelected(e.target.value)}>
                  {done.map((r) => <option key={r.id} value={r.id}>{r.label} — {localTime(r.finished || r.created)}</option>)}
                </select>
              </label>
            )}
            <Seg value={theme} onChange={setTheme} label="Theme"
                 options={[{ value: "auto", label: "Auto" }, { value: "light", label: "☀" }, { value: "dark", label: "☾" }]} />
            <button type="button" className="btn primary" onClick={openUpload}>⇪ Upload data</button>
          </header>
          {active.map((r) => <RunBar key={r.id} r={r} />)}
          <main className="content">
            {runsErr && <div className="alert err">Backend unreachable: {String(runsErr.message || runsErr)}</div>}
            {page.top && run && <page.top />}
            {/* plain-language summary on every page, compact (headline only) until the viewer clicks Show;
                a run's detail page shows that run's instead */}
            {run && res?.mode === "structured" && !(route.page === "runs" && route.parts[0]) && (
              <PlainSummary runId={run.id} runLabel={run.label} onSummaryPage={route.page === "summary"} collapsible />
            )}
            {/* hypothesis tally on every page, compact (one line) until the viewer clicks Show;
                a run's own detail page shows that run's tally instead (see RunDetail) */}
            {run && res?.checks && !(route.page === "runs" && route.parts[0]) && (
              <div className="tally-row"><EvidenceTally checks={res.checks} showPrimary runLabel={run.label} collapsible /></div>
            )}
            {/* Overview and Estimates: run details + primary specification */}
            {page.strip && run && res?.checks && <StatusStrip run={run} res={res} />}
            {/* size-quartile cards on every page, compact (chips) until the viewer clicks Show; on Campaigns
                they filter the table, elsewhere they link to it */}
            {run && res?.size_quartiles?.length > 0 && !(route.page === "runs" && route.parts[0]) && (
              <QuartileCards quartiles={res.size_quartiles} filters={route.page === "campaigns"} collapsible
                             selected={route.page === "campaigns" ? route.query.get("q") : null}
                             onSelect={(q) => go(q ? `campaigns?q=${q}` : "campaigns")} />
            )}
            <C />
          </main>
        </div>
      </div>
      <UploadDialog open={uploadOpen} onClose={() => setUploadOpen(false)} info={info}
                    onCreated={(r) => { setUploadOpen(false); refresh(); go(`runs/${r.id}`); }} />
    </Ctx.Provider>
  );
}

function Sidebar({ page, open, info, primary, active, nCampaigns }) {
  const link = (key, label, icon, extra) => (
    <a href={href(key)} className={page === key ? "active" : ""}>{icon}{label}{extra}</a>
  );
  const s = info?.script;
  return (
    <aside className={`sidebar${open ? " open" : ""}`}>
      <div className="brand">
        <div className="brand-mark">
          <svg width="20" height="20" viewBox="0 0 32 32" aria-hidden="true">
            <path d="M3 24 L10 16 L15 20 L21 9 L29 13" fill="none" stroke="#3987e5" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
            <circle cx="29" cy="13" r="3" fill="#0ca30c" />
          </svg>
        </div>
        <div>
          <div className="brand-name">ctr<b>·</b>monitor</div>
          <div className="brand-sub">CTR vs impression volume</div>
        </div>
      </div>
      <nav className="nav">
        <div className="nav-h">General</div>
        {link("overview", "Tactical Overview", Icon.overview)}
        <div className="nav-h">Results</div>
        {link("services", "Estimates", Icon.services, primary ? (
          <span className="count" style={{ background: `var(--h${primary[1]})`, color: "#0b0b0b" }} title={`primary result supports ${primary}`}>{primary}</span>) : null)}
        {link("campaigns", "Campaigns", Icon.hosts, nCampaigns ? <span className="count" style={{ background: "#2b2b29" }}>{nCampaigns}</span> : null)}
        {link("graphs", "Traffic Graphs", Icon.graphs)}
        <div className="nav-h">Reports</div>
        {link("analysis", "Analysis", Icon.analysis)}
        {link("summary", "Results Summary", Icon.summary)}
        {link("files", "Figures & Tables", Icon.files)}
        <div className="nav-h">Runs</div>
        {link("runs", "Schedule / History", Icon.runs, active.length ? (
          <span className="count" style={{ background: "#3987e5", color: "#fff" }}>{active.length}</span>) : null)}
      </nav>
      <div className="side-foot">
        {s?.present ? (
          <>
            <div style={{ color: "#c3c2b7" }}>{s.version}</div>
            <div>sha {s.sha256?.slice(0, 12)} · {s.structured ? "structured" : "legacy mode"}</div>
          </>
        ) : s ? <div style={{ color: "#e66767" }}>analysis script missing: {s.path}</div> : "…"}
      </div>
    </aside>
  );
}

function RunBar({ r }) {
  const pr = r.progress;
  const n = pr?.stages?.length || 0;
  const idx = pr?.index ?? 0;
  const cur = pr?.stages?.find((s) => s.key === pr.current);
  return (
    <div className="runbar">
      <RunStatus status={r.status} sm />
      <b>{r.label}</b>
      <span className="muted">{r.status === "queued" ? "waiting for a worker slot" : cur ? `${cur.label} (${idx + 1}/${n})` : "starting…"}</span>
      {n > 0 && <div className="stages">{pr.stages.map((s, i) => <div key={s.key} className={i < idx ? "done" : i === idx && r.status === "running" ? "cur" : ""} />)}</div>}
      <span className="muted">{runDuration(r)}{pr?.peak_gb != null ? ` · peak ${pr.peak_gb.toFixed(1)} GB` : ""}</span>
      <a href={href("runs", r.id)} style={{ marginLeft: "auto" }}>event log →</a>
    </div>
  );
}

function StatusStrip({ run, res }) {
  const { primary } = res.checks;
  const w = res.regression?.within;
  return (
    <div className="strip">
      <div className="panel infobox">
        <div className="title">Current Analysis Status</div>
        <dl className="kv">
          <dt>Last updated</dt><dd>{localTime(run.finished)} <span className="muted">({ago(run.finished)})</span></dd>
          <dt>Run</dt><dd className="mono">{run.id}</dd>
          <dt>Input</dt><dd>{run.inputs?.events?.name} <span className="muted">+ {run.inputs?.mapping?.name}</span></dd>
          <dt>Params</dt><dd className="mono">min-impr={run.params?.min_impr} dpi={run.params?.dpi}</dd>
          <dt>Data</dt><dd>{res.dataset?.date_range} · {int(res.dataset?.n_final)} campaign-hours</dd>
        </dl>
      </div>
      <div className="panel infobox">
        <div className="title">Primary specification {primary && <Hyp h={primary} sm />}</div>
        {w ? (
          <dl className="kv">
            <dt>Model</dt><dd>Binomial GLM, campaign + time FE</dd>
            <dt>β₁ (ln V)</dt><dd className="mono">{signed(w.b)} [{signed(w.lo, 3)}, {signed(w.hi, 3)}]</dd>
            <dt>p</dt><dd className="mono">{pval(w.p)} {stars(w.p)}</dd>
            <dt>Supports</dt><dd>{primary ? `${primary} — ${HYP_INFO[primary].long}` : w.supports}</dd>
            <dt>OR / doubling</dt><dd className="mono">{fixed(w.or_doubling?.[0], 4)} <span className="muted">· pseudo-R² {fixed(w.pseudo_r2, 4)}</span></dd>
          </dl>
        ) : <span className="muted">legacy run — no structured results</span>}
      </div>
    </div>
  );
}
