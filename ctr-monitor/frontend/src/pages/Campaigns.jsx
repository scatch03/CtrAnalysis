import { useState } from "react";
import { useApp } from "../App";
import { go } from "../hooks";
import { compact, fixed, int, share } from "../format";
import { DataTable, Hyp, Panel } from "../components/ui";
import { Sparkline } from "../charts/Mrtg";
import { useResult } from "./common";

const Q_ORDER = { Q1: 1, Q2: 2, Q3: 3, Q4: 4 };

export default function Campaigns() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const [q, setQ] = useState("");
  const quart = ctx.route.query.get("q");   // size-quartile filter lives in the URL (cards are rendered by App)
  if (block) return block;
  const quartiles = res.size_quartiles || [];
  const byQ = Object.fromEntries(quartiles.map((x) => [x.short, x]));
  const n = q.trim().toLowerCase();
  const rows = (res.between?.campaigns || [])
    .filter((c) => (!n || c.campaign.toLowerCase().includes(n)) && (!quart || c.size_q === quart))
    .map((c) => ({ ...c, __key: c.campaign }));
  return (
    <>
      <Panel title="Campaigns" flush
             sub={`${rows.length} campaigns${quart ? ` in ${byQ[quart]?.label}` : " in the analysis dataset"} — click a row for its traffic graphs`}
             tools={<>
               {quart && <button type="button" className="btn sm" onClick={() => go("campaigns")}>{quart} only ✕</button>}
               <input type="search" placeholder="Filter campaign id…" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 180 }} />
             </>}>
        <DataTable rows={rows} initialSort={{ key: "impr", dir: "desc" }} onRowClick={(r) => go(`graphs/${encodeURIComponent(r.campaign)}`)}
          columns={[
            { key: "campaign", label: "Campaign", render: (r) => <span className="mono" style={{ fontWeight: 600 }}>{r.campaign}</span> },
            ...(quartiles.length ? [{
              key: "size_q", label: "Size quartile", sortKey: (r) => Q_ORDER[r.size_q] ?? 9,
              title: "campaign's size group and the hypothesis that group's GLM slope supports (§4.6a)",
              render: (r) => r.size_q ? (
                <span style={{ display: "inline-flex", gap: 6, alignItems: "center", whiteSpace: "nowrap" }}>
                  <span className="mono" style={{ fontSize: 11.5 }}>{r.size_q}</span>
                  {byQ[r.size_q]?.tested && <Hyp h={byQ[r.size_q].hyp} sm />}
                </span>) : <span className="muted">—</span>,
            }] : []),
            { key: "flags", label: "Flags", sortKey: (r) => r.outlier_hours, render: (r) => r.outlier_hours
                ? <span className="wtag" title="hours with CTR > 20% — flagged by the script, not removed">{r.outlier_hours}h CTR&gt;20%</span>
                : <span className="muted">—</span> },
            { key: "n_obs", label: "Hours", num: true, fmt: int },
            { key: "impr", label: "Impressions", num: true, fmt: (v) => compact(v) },
            { key: "clicks", label: "Clicks", num: true, fmt: (v) => compact(v) },
            { key: "ctr", label: "CTR %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "median_impr", label: "Median impr/h", num: true, fmt: (v) => compact(v) },
            { key: "mean_logv", label: "mean ln V", num: true, fmt: (v) => fixed(v, 2) },
            { key: "zero_click_share", label: "Zero-click", num: true, fmt: (v) => share(v) },
            { key: "first", label: "Active", sortKey: (r) => r.first, render: (r) => <span className="mono muted nowrap" style={{ fontSize: 11 }}>{r.first?.slice(5, 16).replace("T", " ")} → {r.last?.slice(5, 16).replace("T", " ")}</span> },
            { key: "spark", label: "Daily CTR", sort: false, render: (r) => <Sparkline values={r.spark} /> },
          ]} />
      </Panel>
    </>
  );
}
