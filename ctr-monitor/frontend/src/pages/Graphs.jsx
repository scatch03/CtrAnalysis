import { useMemo, useState } from "react";
import { useApp } from "../App";
import { api } from "../api";
import { href, useAsync } from "../hooks";
import { compact, dataTime, int, pct } from "../format";
import { Empty, Hyp, Panel } from "../components/ui";
import { HourProfile, MrtgWindow, Sparkline } from "../charts/Mrtg";
import { useResult } from "./common";

export default function Graphs() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const campaign = ctx.route.parts[0] || null;
  const [q, setQ] = useState("");
  const m = useAsync(() => (ctx.run ? api.mrtg(ctx.run.id, campaign) : null), [ctx.run?.id, campaign]);
  const list = useMemo(() => {
    const n = q.trim().toLowerCase();
    return (res?.between?.campaigns || []).filter((c) => !n || c.campaign.toLowerCase().includes(n));
  }, [res, q]);
  if (block) return block;
  const info = (res.between?.campaigns || []).find((c) => c.campaign === campaign);
  const d = m.data;

  const quart = info?.size_q && (res.size_quartiles || []).find((x) => x.short === info.size_q);
  return (
    <>
    <div className="g-pick">
      <Panel title="Campaigns" sub={`${list.length}`} flush
             tools={<input type="search" placeholder="Filter…" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 110 }} />}>
        <div className="picker">
          <a href={href("graphs")} className={!campaign ? "active" : ""}>
            <span><b>All campaigns</b><div className="sub">aggregate traffic</div></span>
          </a>
          {list.map((c) => (
            <a key={c.campaign} href={href("graphs", c.campaign)} className={campaign === c.campaign ? "active" : ""}>
              <span style={{ minWidth: 0 }}>
                <span className="mono">{c.campaign}</span>
                <div className="sub">{compact(c.impr)} impr · {pct(c.ctr, 2)}</div>
              </span>
              <Sparkline values={c.spark} width={70} height={20} />
            </a>
          ))}
        </div>
      </Panel>

      <div style={{ display: "flex", flexDirection: "column", gap: 16, minWidth: 0 }}>
        <Panel title={<>Traffic Analysis for <span className="mono">{campaign ? `campaign ${campaign}` : "all campaigns"}</span></>}
               sub="hourly panel after data-quality exclusions, before the min-impression filter"
               tools={campaign && <a className="btn sm" href={href("campaigns")}>campaign table</a>}>
          {m.error ? <div className="alert err">{m.error.message}</div> : !d ? <Empty title="Loading…" /> : (
            <>
              <div className="mrtg-head" style={{ marginBottom: 18 }}>
                <div><span>Run</span><span>{ctx.run.label}</span></div>
                <div><span>Data window</span><span className="mono">{dataTime(d.range[0], "date")} → {dataTime(d.range[1] - 1, "date")}</span></div>
                <div><span>Active hours</span><span className="mono">{int(d.totals.active_hours)} / {int(d.totals.hours)}</span></div>
                <div><span>First active</span><span className="mono">{d.totals.first?.replace("T", " ").slice(0, 16) || "—"}</span></div>
                <div><span>Last active</span><span className="mono">{d.totals.last?.replace("T", " ").slice(0, 16) || "—"}</span></div>
                <div><span>Impressions</span><span className="mono">{int(d.totals.impr)}</span></div>
                <div><span>Clicks</span><span className="mono">{int(d.totals.clicks)}</span></div>
                <div><span>Pooled CTR</span><span className="mono">{pct(d.totals.impr ? d.totals.clicks / d.totals.impr * 100 : null, 3)}</span></div>
                {info && <div><span>Campaign-hours (analysis)</span><span className="mono">{int(info.n_obs)}</span></div>}
                {info && <div><span>Hours with CTR &gt; 20%</span><span className="mono">{int(info.outlier_hours)}</span></div>}
                {quart && (
                  <div title="this campaign's size group and the hypothesis that group's GLM slope supports (§4.6a); not a test of this campaign alone">
                    <span>Size quartile</span>
                    <span style={{ display: "inline-flex", gap: 6, alignItems: "center" }}><span className="mono">{quart.label}</span>{quart.tested && <Hyp h={quart.hyp} sm />}</span>
                  </div>
                )}
              </div>
              <div className="mrtg-grid">
                {d.windows.map((w) => <MrtgWindow key={w.key} w={w} />)}
              </div>
              <div className="chart-note" style={{ marginTop: 12 }}>
                Times are on the data's own clock (no time zone in the source). Hours without an event row count as zero traffic; CTR is undefined where a bin has no impressions.
              </div>
            </>
          )}
        </Panel>
        {d && (
          <Panel title="Hour-of-day profile" sub="pooled over the whole data window">
            <HourProfile rows={d.profile} ctrLabel="Pooled CTR" />
          </Panel>
        )}
      </div>
    </div>
    </>
  );
}
