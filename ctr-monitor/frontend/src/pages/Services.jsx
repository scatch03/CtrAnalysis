import { Fragment, useEffect, useState } from "react";
import { useApp } from "../App";
import { go, href } from "../hooks";
import { duration } from "../format";
import { CheckLabel, Hyp, HYP_ORDER, Panel, Seg, TallyDots, Weight } from "../components/ui";
import { useResult } from "./common";

const FILTERS = [
  { value: "all", label: "All" }, { value: "disagree", label: "Disagrees with primary" },
  { value: "H1", label: "H1" }, { value: "H2", label: "H2" }, { value: "H3", label: "H3" }, { value: "H4", label: "H4" },
  { value: "info", label: "Info" },
];

export const disagrees = (s, primary) => s.kind === "hypothesis" && s.supported && s.hyp && s.hyp !== primary;

function matches(s, filter, primary) {
  if (filter === "all") return true;
  if (filter === "info") return s.kind === "info";
  if (filter === "disagree") return disagrees(s, primary);
  return s.kind === "hypothesis" && s.hyp === filter && s.supported;
}

export default function Services() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const q = ctx.route.query;
  const filter = q.get("filter") || "all";
  const focus = q.get("focus");
  const [search, setSearch] = useState("");
  const [order, setOrder] = useState("group");
  const [open, setOpen] = useState(() => new Set(focus ? [focus] : []));
  useEffect(() => {
    if (!focus) return;
    setOpen((o) => new Set([...o, focus]));
    setTimeout(() => document.getElementById(`svc-${focus}`)?.scrollIntoView({ block: "center" }), 50);
  }, [focus]);
  if (block) return block;
  if (!res.checks) return <div className="alert info">This run has no structured results (legacy mode).</div>;

  const { primary } = res.checks;
  const groups0 = Object.fromEntries(res.checks.groups.map((g) => [g.id, g]));
  const needle = search.trim().toLowerCase();
  let rows = res.checks.services.filter((s) => matches(s, filter, primary) &&
    (!needle || `${s.host} ${s.service} ${s.output} ${s.hyp || ""} ${s.weight || ""}`.toLowerCase().includes(needle)));
  if (order === "hyp") {
    const key = (s) => (s.kind === "info" ? 9 : (HYP_ORDER[s.hyp] ?? 8) + (s.supported ? 0 : 4));
    rows = [...rows].sort((a, b) => key(a) - key(b));
  }

  const groups = [];
  for (const s of rows) {
    const g = order === "group" ? groups.find((x) => x.host === s.host) : null;
    if (g) g.rows.push(s); else groups.push({ host: s.host, rows: [s] });
  }
  const toggle = (id) => setOpen((o) => { const n = new Set(o); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const setFilter = (v) => go(v === "all" ? "services" : `services?filter=${v}`);

  return (
    <Panel title="Estimates by hypothesis" sub={`${rows.length} rows · primary result: ${primary || "—"}`} flush
           tools={<>
             <input type="search" placeholder="Search…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 160 }} />
             <Seg value={filter} onChange={setFilter} options={FILTERS} label="Filter" />
             <Seg value={order} onChange={setOrder} label="Order" options={[{ value: "group", label: "By section" }, { value: "hyp", label: "By hypothesis" }]} />
           </>}>
      <div className="tbl-wrap">
        <table className="tbl">
          <thead>
            <tr><th>Section</th><th>Estimate</th><th>Supports</th><th>Weight</th><th className="num" title="time spent in the pipeline stage that produced this row">Stage time</th><th>Details</th></tr>
          </thead>
          <tbody>
            {groups.length === 0 && <tr><td colSpan={6} className="muted" style={{ textAlign: "center", padding: 24 }}>Nothing matches.</td></tr>}
            {groups.map((g) => {
              const span = g.rows.reduce((n, s) => n + (open.has(s.id) ? 2 : 1), 0);
              const gi = groups0[g.host];
              return g.rows.map((s, i) => (
                <Fragment key={s.id}>
                  <tr id={`svc-${s.id}`} className={`clickable ${s.primary ? "row-primary" : ""} ${i === 0 ? "grp-start" : ""} ${open.has(s.id) ? "expanded" : ""}`}
                      onClick={() => toggle(s.id)}>
                    {(i === 0 || order !== "group") && (
                      <td className="host" rowSpan={order === "group" ? span : 1} onClick={(e) => e.stopPropagation()}>
                        <div>{gi?.name || g.host}</div>
                        {order === "group" && <div className="hd">{gi?.desc}</div>}
                        {order === "group" && <div style={{ marginTop: 4 }}><TallyDots tally={gi?.tally} /></div>}
                      </td>
                    )}
                    <td className="svc">
                      <span className="muted" style={{ display: "inline-block", width: 12 }}>{open.has(s.id) ? "▾" : "▸"}</span>{s.service}
                    </td>
                    <td><CheckLabel s={s} /></td>
                    <td><Weight w={s.kind === "info" ? null : s.weight} /></td>
                    <td className="num">{duration(s.duration)}</td>
                    <td className="info">{s.output}{s.note && <div className="caveat" style={{ marginTop: 2 }}>⚠ {s.note}</div>}</td>
                  </tr>
                  {open.has(s.id) && (
                    <tr><td colSpan={order === "group" ? 5 : 6} style={{ padding: 0 }}><Detail s={s} /></td></tr>
                  )}
                </Fragment>
              ));
            })}
          </tbody>
        </table>
      </div>
      <Legend />
    </Panel>
  );
}

function Detail({ s }) {
  return (
    <div className="detail">
      <div style={{ display: "flex", gap: 16, flexWrap: "wrap", alignItems: "baseline" }}>
        <span className="mono">{s.id}</span>
        {s.view && <a href={href(...s.view.split("/"))}>open chart →</a>}
      </div>
      {s.note && <div className="caveat" style={{ marginTop: 6 }}>⚠ {s.note}</div>}
      {s.detail?.length > 0 && (
        <dl className="kv" style={{ marginTop: 8, fontSize: 12 }}>
          {s.detail.map(([k, v]) => <Fragment key={k}><dt>{k}</dt><dd className="mono">{v}</dd></Fragment>)}
        </dl>
      )}
      {s.perf && <div className="perf"><span className="muted">perfdata │ </span>{s.perf}</div>}
    </div>
  );
}

function Legend() {
  return (
    <div className="muted" style={{ padding: "10px 14px 12px", fontSize: 11.5, lineHeight: 1.9, borderTop: "1px solid var(--border)" }}>
      <div>
        <Hyp h="H1" sm /> slope β &lt; 0, p &lt; .05 &nbsp;·&nbsp; <Hyp h="H2" sm /> quadratic β₂ &lt; 0 with β₁ &gt; 0, p &lt; .05
        &nbsp;·&nbsp; <Hyp h="H3" sm /> slope β &gt; 0, p &lt; .05 &nbsp;·&nbsp; <Hyp h="H4" sm /> p ≥ .05 — the same rule as the script's <span className="mono">conclusion()</span>.
      </div>
      <div>
        Weight: <Weight w="primary" /> the paper's main specification · <Weight w="pooled" /> no campaign FE ·{" "}
        <Weight w="naive" /> unweighted OLS, kept for comparison · <Weight w="descriptive" /> / <Weight w="low power" /> /{" "}
        <Weight w="few clusters" /> / <Weight w="SE only" /> p-values the script itself flags as approximate ·{" "}
        <Weight w="illustrative" /> five-point curve fit · <Weight w="info" /> not a hypothesis test.
      </div>
    </div>
  );
}
