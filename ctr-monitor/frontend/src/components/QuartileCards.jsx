import { compact, int, pval, signed, stars } from "../format";
import { useStored } from "../hooks";
import { Hyp, Panel, TallyDots, Weight } from "./ui";

/**
 * Campaign size quartiles (§4.6a): one card per quartile with the hypothesis its GLM slope supports.
 * `onSelect(short|null)` is called on click — the Campaigns page filters its table, other pages
 * navigate there. `collapsible` adds a Hide/Show toggle; it starts as a row of chips and the choice is
 * remembered per viewer under `storageKey` — one shared setting for every page by default.
 */
export default function QuartileCards({ quartiles, selected, onSelect, collapsible = false, filters = false, runLabel,
                                        storageKey = "ctr.quart.open.compact", defaultOpen = false }) {
  const [openPref, setOpen] = useStored(storageKey, defaultOpen);
  const open = !collapsible || openPref;
  const tally = {};
  for (const q of quartiles) if (q.hyp) tally[q.hyp] = (tally[q.hyp] || 0) + 1;
  const perGroup = Math.round(quartiles.reduce((n, q) => n + q.n_campaigns, 0) / Math.max(1, quartiles.length));

  return (
    <Panel title="By campaign size quartile" flush className={open ? "" : "collapsed"}
           sub={open
             ? <>§4.6a — within-campaign GLM slope per size group{runLabel ? ` · “${runLabel}”` : ""} · quartiles: <TallyDots tally={tally} /></>
             : <span className="q-inline">
                 {quartiles.map((q) => (
                   <button key={q.short} type="button" className={`q-chip${selected === q.short ? " on" : ""}`}
                           onClick={() => onSelect?.(filters && selected === q.short ? null : q.short)}
                           aria-pressed={filters ? selected === q.short : undefined}
                           title={filters ? (selected === q.short ? "show all campaigns" : `show only ${q.label} campaigns (${q.n_campaigns})`)
                             : `${q.label}: ${q.n_campaigns} campaigns — open in Campaigns`}>
                     <span className="mono">{q.short}</span>{q.tested ? <Hyp h={q.hyp} sm /> : <span className="muted">—</span>}
                   </button>
                 ))}
               </span>}
           tools={<>
             {open && <Weight w="few clusters" />}
             {collapsible && (
               <button type="button" className="btn sm ghost" onClick={() => setOpen(!openPref)} aria-expanded={open}>
                 {open ? "Hide ▴" : "Show ▾"}
               </button>
             )}
           </>}>
      <div className="qcards">
        {quartiles.map((q) => (
          <button key={q.short} type="button" className={`qcard${selected === q.short ? " on" : ""}`}
                  onClick={() => onSelect?.(filters && selected === q.short ? null : q.short)}
                  aria-pressed={filters ? selected === q.short : undefined}
                  title={filters ? (selected === q.short ? "show all campaigns" : `show only ${q.label} campaigns`)
                    : `open the ${q.label} campaigns`}>
            <div className="qcard-h">
              <b>{q.label}</b>
              <span className="muted">{q.n_campaigns} campaigns</span>
            </div>
            {q.tested ? (
              <>
                <Hyp h={q.hyp} />
                <div className="mono qcard-num">β₁ {signed(q.glm.b, 3)} · p {pval(q.glm.p)} {stars(q.glm.p)}</div>
                <div className="qcard-sub">median {compact(q.median_impr)} impr/h · {int(q.n_obs)} hours</div>
                <div className="qcard-sub">naive OLS: <Hyp h={q.ols_hyp} sm /></div>
              </>
            ) : <div className="muted" style={{ fontSize: 12 }}>not estimated — fewer than 30 campaign-hours</div>}
          </button>
        ))}
      </div>
      <div className="chart-note" style={{ padding: "0 14px 12px", margin: 0 }}>
        Quartiles split campaigns by their median impressions per hour (same rule as the script). Each card is one GLM fit on
        that group's campaign-hours; with ~{perGroup} campaigns per group the script flags these p-values as approximate.{" "}
        {filters ? "Click a card to filter the table." : "Click a card to see its campaigns."}
      </div>
    </Panel>
  );
}
