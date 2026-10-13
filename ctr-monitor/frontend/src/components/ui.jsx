import { useMemo, useState } from "react";

const RUN_LABEL = { queued: "PENDING", running: "RUNNING", ok: "DONE", failed: "FAILED", cancelled: "CANCELLED" };

// The paper's four hypotheses (§3.3). Colours are categorical identity, shared with the curve-fit chart.
export const HYP_INFO = {
  H1: { short: "fatigue", long: "Exponential decay (fatigue)", desc: "CTR falls as volume rises" },
  H2: { short: "inverted-U", long: "Inverted-U (novelty → fatigue)", desc: "CTR rises, then falls" },
  H3: { short: "growth", long: "Saturating growth", desc: "CTR rises with volume" },
  H4: { short: "null", long: "Null (constant)", desc: "no detectable volume effect" },
};
export const HYP_ORDER = { H1: 0, H2: 1, H3: 2, H4: 3 };

/** Which hypothesis an estimate supports — e.g. "● H1 fatigue". `supported=false` → "H2 not supported". */
export function Hyp({ h, supported = true, sm, title }) {
  if (!h) return <span className={`hyp-badge none${sm ? " sm" : ""}`}>—</span>;
  const i = HYP_INFO[h];
  return (
    <span className={`hyp-badge h${h[1]}${supported ? "" : " rejected"}${sm ? " sm" : ""}`}
          title={title || (supported ? `${h} — ${i.long}: ${i.desc}` : `${h} (${i.long}) not supported`)}>
      <i aria-hidden="true" /><b>{h}</b>{supported ? i.short : "not supported"}
    </span>
  );
}

/** How much weight the script gives an estimate (primary, naive, descriptive, …), or "info" for non-tests. */
export function Weight({ w }) {
  if (!w) return null;
  return <span className={`wtag${w === "primary" ? " primary" : w === "info" ? " info" : ""}`}>{w}</span>;
}

/** Compact "H1×2 H3×1" counts with hypothesis-coloured dots. */
export function TallyDots({ tally }) {
  return (
    <span className="tally-dots">
      {["H1", "H2", "H3", "H4"].filter((h) => tally?.[h]).map((h) => (
        <span key={h} title={`${tally[h]} estimate(s) support ${h} (${HYP_INFO[h].short})`}>
          <i style={{ background: `var(--h${h[1]})` }} />{h}×{tally[h]}
        </span>
      ))}
    </span>
  );
}

/** Badge for one check row: hypothesis it supports, or a neutral info tag. */
export function CheckLabel({ s, sm }) {
  return s.kind === "info" ? <Weight w="info" /> : <Hyp h={s.hyp} supported={s.supported} sm={sm} />;
}

export function RunStatus({ status, sm }) {
  const s = status === "ok" ? "ok" : status;
  return (
    <span className={`st ${s}${sm ? " sm" : ""}`}>
      {status === "running" && <span className="spin" style={{ width: 9, height: 9, borderWidth: 1.5 }} />}
      {RUN_LABEL[status] || status}
    </span>
  );
}

export function Panel({ title, sub, tools, children, flush, id, className = "" }) {
  return (
    <section className={`panel ${className}`} id={id}>
      {(title || tools) && (
        <div className="panel-h">
          {title && <h2>{title}</h2>}
          {sub && <span className="sub">{sub}</span>}
          {tools && <div className="tools">{tools}</div>}
        </div>
      )}
      <div className={`panel-b${flush ? " flush" : ""}`}>{children}</div>
    </section>
  );
}

export function Seg({ value, options, onChange, label }) {
  return (
    <div className="seg" role="group" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" className={value === o.value ? "on" : ""} aria-pressed={value === o.value}
                onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

/** Chart with a table-view twin (every value reachable without hover). */
export function ChartCard({ title, sub, chart, table, tools, id }) {
  const [view, setView] = useState("chart");
  return (
    <Panel id={id} title={title} sub={sub} tools={<>{tools}
      {table && <Seg value={view} onChange={setView} label="View" options={[{ value: "chart", label: "Chart" }, { value: "table", label: "Table" }]} />}</>}
      flush={view === "table"}>
      {view === "chart" ? chart : table}
    </Panel>
  );
}

/**
 * Sortable table. columns: [{key, label, num, fmt(v,row), render(row), sort:false, sortKey(row), title}]
 */
export function DataTable({ columns, rows, initialSort, onRowClick, rowClass, maxHeight, empty = "no rows", dense }) {
  const [sort, setSort] = useState(initialSort || null);
  const sorted = useMemo(() => {
    if (!sort) return rows;
    const col = columns.find((c) => c.key === sort.key);
    if (!col) return rows;
    const get = col.sortKey || ((r) => r[col.key]);
    const dir = sort.dir === "asc" ? 1 : -1;
    return [...rows].sort((a, b) => {
      const x = get(a), y = get(b);
      if (x === y) return 0;
      if (x === null || x === undefined) return 1;
      if (y === null || y === undefined) return -1;
      return (x > y ? 1 : -1) * dir;
    });
  }, [rows, sort, columns]);
  const click = (c) => {
    if (c.sort === false) return;
    setSort((s) => (s?.key === c.key ? { key: c.key, dir: s.dir === "asc" ? "desc" : "asc" } : { key: c.key, dir: c.num ? "desc" : "asc" }));
  };
  return (
    <div className="tbl-wrap" style={maxHeight ? { maxHeight, overflowY: "auto" } : undefined}>
      <table className="tbl" style={dense ? { fontSize: 12 } : undefined}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={`${c.sort === false ? "" : "sortable"} ${c.num ? "num" : ""}`} title={c.title}
                  onClick={() => click(c)} aria-sort={sort?.key === c.key ? (sort.dir === "asc" ? "ascending" : "descending") : undefined}>
                {c.label}{sort?.key === c.key && <span className="arrow">{sort.dir === "asc" ? "▲" : "▼"}</span>}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.length === 0 && <tr><td colSpan={columns.length} className="muted" style={{ textAlign: "center", padding: 18 }}>{empty}</td></tr>}
          {sorted.map((r, i) => (
            <tr key={r.__key ?? i} className={`${onRowClick ? "clickable" : ""} ${rowClass?.(r) || ""}`}
                onClick={onRowClick ? () => onRowClick(r) : undefined}>
              {columns.map((c) => (
                <td key={c.key} className={c.num ? "num" : c.className}>
                  {c.render ? c.render(r) : c.fmt ? c.fmt(r[c.key], r) : r[c.key] ?? "—"}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Generic table for a CSV/records payload: {columns, rows: [[...]]} or records. */
export function RecordsTable({ columns, rows, maxHeight }) {
  const recs = rows.map((r, i) => ({ __key: i, ...(Array.isArray(r) ? Object.fromEntries(columns.map((c, j) => [c, r[j]])) : r) }));
  const isNum = (c) => recs.some((r) => typeof r[c] === "number") && recs.every((r) => r[c] === null || typeof r[c] === "number");
  const fmt = (v) => (typeof v === "number" ? (Number.isInteger(v) ? v.toLocaleString("en-US") : +v.toPrecision(6) + "") : v === null ? "—" : String(v));
  return (
    <DataTable maxHeight={maxHeight} dense rows={recs}
               columns={columns.map((c) => ({ key: c, label: c, num: isNum(c), fmt }))} />
  );
}

export function Empty({ title, children }) {
  return <div className="empty"><h3>{title}</h3>{children}</div>;
}

export function Tile({ label, value, foot, title }) {
  return (
    <div className="tile" title={title}>
      <div className="lbl">{label}</div>
      <div className="val">{value}</div>
      {foot && <div className="foot">{foot}</div>}
    </div>
  );
}

export const Icon = {
  overview: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="1.5" y="1.5" width="5" height="5" rx="1" /><rect x="9.5" y="1.5" width="5" height="5" rx="1" /><rect x="1.5" y="9.5" width="5" height="5" rx="1" /><rect x="9.5" y="9.5" width="5" height="5" rx="1" /></svg>,
  services: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M2 4h12M2 8h12M2 12h12" /><circle cx="4" cy="4" r="0.6" fill="currentColor" /></svg>,
  hosts: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="2" y="2" width="12" height="4.5" rx="1" /><rect x="2" y="9.5" width="12" height="4.5" rx="1" /><circle cx="4.5" cy="4.25" r="0.7" fill="currentColor" /><circle cx="4.5" cy="11.75" r="0.7" fill="currentColor" /></svg>,
  graphs: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M1.5 14.5h13" /><path d="M2 11l3.5-4 3 2.5L14 3" strokeLinejoin="round" /></svg>,
  analysis: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="4" cy="11" r="1.5" /><circle cx="8" cy="6" r="1.5" /><circle cx="12.5" cy="9" r="1.5" /><path d="M1.5 14.5h13" /></svg>,
  summary: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="2.5" y="1.5" width="11" height="13" rx="1.5" /><path d="M5 5h6M5 8h6M5 11h4" /></svg>,
  files: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M2 4.5V13a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H8L6.5 3H3a1 1 0 0 0-1 1.5z" /></svg>,
  runs: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="8" cy="8" r="6.5" /><path d="M6.5 5.5l4 2.5-4 2.5z" fill="currentColor" /></svg>,
  log: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5" /><path d="M4 6l2 2-2 2M8 10h4" /></svg>,
};
