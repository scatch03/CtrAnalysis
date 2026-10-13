import { useEffect, useRef, useState } from "react";
import { useApp } from "../App";
import { api } from "../api";
import { go, href, useAsync, useInterval } from "../hooks";
import { bytes, duration, localTime, runDuration } from "../format";
import { DataTable, Empty, Hyp, Panel, RunStatus, TallyDots } from "../components/ui";
import EvidenceTally from "../components/EvidenceTally";
import QuartileCards from "../components/QuartileCards";
import UploadForm from "../components/UploadForm";
import PlainSummary from "../components/PlainSummary";

export default function Runs() {
  const { route } = useApp();
  return route.parts[0] ? <RunDetail id={route.parts[0]} /> : <RunsHome />;
}

function RunsHome() {
  const { runs, info, refresh, select } = useApp();
  const [fromRun, setFromRun] = useState(null);
  const formRef = useRef(null);
  const rerun = (r) => { setFromRun(r); formRef.current?.scrollIntoView({ behavior: "smooth" }); };
  const act = async (fn) => { try { await fn(); } catch (e) { alert(e.message); } refresh(); };

  return (
    <>
      <div ref={formRef}>
        <Panel title="Upload data & run analysis" sub={info?.script?.version || ""}>
          <UploadForm info={info} fromRun={fromRun} clearFrom={() => setFromRun(null)} onCreated={(r) => { refresh(); go(`runs/${r.id}`); }} />
        </Panel>
      </div>
      <Panel title="Run history" sub={runs ? `${runs.length} runs` : ""} flush>
        <DataTable rows={(runs || []).map((r) => ({ ...r, __key: r.id }))} initialSort={{ key: "created", dir: "desc" }} empty="no runs yet"
          onRowClick={(r) => go(`runs/${r.id}`)}
          columns={[
            { key: "status", label: "Status", render: (r) => <RunStatus status={r.status} sm /> },
            { key: "label", label: "Label", render: (r) => <b style={{ display: "inline-block", minWidth: 110 }}>{r.label}</b> },
            { key: "finding", label: "Finding", sort: false, render: (r) => <Finding id={r.id} status={r.status} /> },
            { key: "created", label: "Created", render: (r) => <span className="nowrap">{localTime(r.created)}</span> },
            { key: "dur", label: "Duration", num: true, sort: false, render: (r) => runDuration(r) },
            { key: "params", label: "Params", sort: false, render: (r) => <span className="mono muted nowrap">min={r.params?.min_impr} dpi={r.params?.dpi}</span> },
            { key: "checks", label: "Evidence", sort: false, render: (r) => r.tally ? <TallyDots tally={r.tally} /> : r.error ? <span className="mono" style={{ color: "var(--crit-text)", fontSize: 11 }}>{String(r.error).slice(0, 80)}</span> : "—" },
            { key: "act", label: "", sort: false, render: (r) => (
              <span style={{ display: "inline-flex", gap: 4 }} onClick={(e) => e.stopPropagation()}>
                {r.status === "ok" && <button className="btn sm" onClick={() => { select(r.id); go("overview"); }}>Results</button>}
                {(r.status === "queued" || r.status === "running") && <button className="btn sm" onClick={() => act(() => api.cancel(r.id))}>Cancel</button>}
                {r.inputs && <button className="btn sm" onClick={() => rerun(r)}>Re-run…</button>}
                <button className="btn sm ghost danger" title="Delete run and its files"
                        onClick={() => window.confirm(`Delete run ${r.id} and all its files?`) && act(() => api.remove(r.id))}>✕</button>
              </span>) },
          ]} />
      </Panel>
    </>
  );
}


/** One-line headline of the run's plain-language summary; hover for the full text. */
function Finding({ id, status }) {
  const n = useAsync(() => (status === "ok" ? api.narrative(id) : null), [id, status]);
  if (status !== "ok" || n.error) return <span className="muted">—</span>;
  if (!n.data) return <span className="muted">…</span>;
  return (
    <span className="finding" title={n.data.text}>
      {n.data.hyp && <Hyp h={n.data.hyp} sm />}<span>{n.data.headline}</span>
    </span>
  );
}

function colorize(text) {
  return text.split("\n").map((ln, i) => {
    const cls = /\[WARN\]|⚠/.test(ln) ? "w" : /✓|✅/.test(ln) ? "ok" : /^── /.test(ln) ? "h" : /Traceback|Error|Exception/.test(ln) ? "e" : null;
    return <span key={i} className={cls || undefined}>{ln}{"\n"}</span>;
  });
}

function RunDetail({ id }) {
  const { refresh, select, runs } = useApp();
  const [run, setRun] = useState(null);
  const [err, setErr] = useState(null);
  const [log, setLog] = useState({ text: "", offset: 0 });
  const box = useRef(null);
  const stick = useRef(true);
  const activeNow = run && (run.status === "queued" || run.status === "running");
  const runRes = useAsync(() => (run?.status === "ok" ? api.result(run.id) : null), [run?.id, run?.status]);

  const off = useRef(0);
  const inflight = useRef(false);
  const load = () => api.run(id).then(setRun, setErr);
  const pull = () => {
    if (inflight.current) return;
    inflight.current = true;
    const at = off.current;
    api.log(id, at).then((r) => {
      if (off.current !== at) return;          // run switched meanwhile
      off.current = r.offset;
      if (r.text) setLog((l) => ({ text: (l.text + r.text).slice(-400_000), offset: r.offset }));
    }, () => {}).finally(() => { inflight.current = false; });
  };
  useEffect(() => { setRun(null); setLog({ text: "", offset: 0 }); off.current = 0; load(); }, [id]); // eslint-disable-line
  useEffect(() => { if (run) pull(); }, [run?.id, run?.status]); // eslint-disable-line
  useInterval(() => { load(); pull(); }, 1500, !!activeNow);
  useEffect(() => { if (stick.current && box.current) box.current.scrollTop = box.current.scrollHeight; }, [log.text]);
  useEffect(() => { refresh(); }, [run?.status]); // eslint-disable-line

  if (err) return <div className="alert err">{err.message} — <a href={href("runs")}>back to runs</a></div>;
  if (!run) return <Empty title="Loading…" />;
  const pr = run.progress;
  const known = (runs || []).some((r) => r.id === id);
  return (
    <>
      <div className="filters"><a className="btn sm" href={href("runs")}>← All runs</a></div>
      {run.status === "ok" && <PlainSummary runId={run.id} runLabel={run.label} collapsible onFull={() => { select(run.id); go("summary"); }} />}
      {runRes.data?.checks && <div className="tally-row"><EvidenceTally checks={runRes.data.checks} showPrimary runLabel={run.label} collapsible /></div>}
      {runRes.data?.size_quartiles?.length > 0 && (
        <QuartileCards quartiles={runRes.data.size_quartiles} collapsible runLabel={run.label}
                       onSelect={(q) => { select(run.id); go(`campaigns?q=${q}`); }} />
      )}
      <div className="grid g-side">
        <Panel title="Event log" sub="worker stdout — the script's own console output" flush
               tools={activeNow && <span className="muted" style={{ fontSize: 11.5 }}><span className="dot running pulse" /> live</span>}>
          <pre className="console" ref={box} onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollTop + el.clientHeight >= el.scrollHeight - 30; }}>
            {log.text ? colorize(log.text) : <span className="muted">{run.status === "queued" ? "waiting for a worker slot…" : "no output yet"}</span>}
          </pre>
        </Panel>
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <Panel title={run.label} tools={<RunStatus status={run.status} />}>
            <dl className="kv">
              <dt>Run id</dt><dd className="mono">{run.id}</dd>
              <dt>Created</dt><dd>{localTime(run.created)}</dd>
              <dt>Started</dt><dd>{localTime(run.started)}</dd>
              <dt>Finished</dt><dd>{localTime(run.finished)}</dd>
              <dt>Duration</dt><dd>{runDuration(run)}</dd>
              <dt>Params</dt><dd className="mono">min-impr={run.params?.min_impr} dpi={run.params?.dpi}</dd>
              <dt>Mapping</dt><dd>{run.inputs?.mapping?.name} <span className="muted">({bytes(run.inputs?.mapping?.size)})</span></dd>
              <dt>Events</dt><dd>{run.inputs?.events?.name} <span className="muted">({bytes(run.inputs?.events?.size)})</span></dd>
              <dt>Script</dt><dd>{run.script?.version} <span className="mono muted">{run.script?.sha256?.slice(0, 10)}</span></dd>
            </dl>
            <div style={{ display: "flex", gap: 6, marginTop: 12, flexWrap: "wrap" }}>
              {run.status === "ok" && <button className="btn primary sm" onClick={() => { select(run.id); go("overview"); }}>Open results</button>}
              {activeNow && <button className="btn sm" onClick={() => api.cancel(run.id).then(load, (e) => alert(e.message))}>Cancel run</button>}
              {!known && <span className="muted">deleted</span>}
            </div>
          </Panel>
          {pr?.stages && (
            <Panel title="Stages" flush sub={pr.peak_gb != null ? `peak memory ${pr.peak_gb.toFixed(1)} GB` : undefined}>
              <table className="tbl"><tbody>
                {pr.stages.map((s, i) => {
                  const t = pr.times?.[s.key];
                  const cur = pr.current === s.key && run.status === "running";
                  return (
                    <tr key={s.key}>
                      <td style={{ width: 22 }}><i className={`dot ${t !== undefined ? "ok" : cur ? "running pulse" : run.status === "failed" && i === pr.index ? "critical" : "pending"}`} /></td>
                      <td>{s.label}</td>
                      <td className="num">{t !== undefined ? duration(t) : cur ? "…" : ""}</td>
                      <td className="num muted" title="worker's peak memory by the end of this stage">
                        {pr.mem?.[s.key] != null ? `${pr.mem[s.key].toFixed(1)} GB` : cur && pr.peak_gb != null ? `${pr.peak_gb.toFixed(1)} GB…` : ""}
                      </td>
                    </tr>
                  );
                })}
              </tbody></table>
            </Panel>
          )}
          {run.status === "failed" && (
            <Panel title="Failure">
              <div className="alert err">{run.error}</div>
              {run.traceback && <pre className="console" style={{ marginTop: 10, borderRadius: 6, maxHeight: 280 }}>{run.traceback}</pre>}
            </Panel>
          )}
        </div>
      </div>
    </>
  );
}
