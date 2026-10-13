import { useState } from "react";
import { api } from "../api";
import { href, useAsync, useStored } from "../hooks";
import { Empty, Panel } from "./ui";

/**
 * "In plain words" panel — rule-based narrative for one run (see backend/app/narrative.py).
 * `collapsible` adds a Hide/Show toggle; it starts as the one-line headline and the choice is
 * remembered per viewer under `storageKey` — one shared setting for every page by default.
 */
export default function PlainSummary({ runId, runLabel, onSummaryPage = false, onFull, collapsible = false,
                                       storageKey = "ctr.plain.open.compact", defaultOpen = false }) {
  const n = useAsync(() => api.narrative(runId), [runId]);
  const [copied, setCopied] = useState(false);
  const [openPref, setOpen] = useStored(storageKey, defaultOpen);
  if (n.error) return null;  // legacy runs have no narrative — just leave it out
  const nd = n.data;
  const open = !collapsible || openPref;
  const copy = () => navigator.clipboard?.writeText(`${nd.headline}\n\n${nd.text}`).then(
    () => { setCopied(true); setTimeout(() => setCopied(false), 1500); }, () => {});
  return (
    <Panel title="In plain words" className={open ? "" : "collapsed"}
           sub={open ? `what ${runLabel ? `“${runLabel}”` : "this run"} found`
             : nd && <span className={`plain-inline hyp-${nd.hyp || "none"}`}>{nd.headline}</span>}
           tools={<>
             {nd && open && <button className="btn sm" onClick={copy}>{copied ? "Copied" : "Copy"}</button>}
             {!onSummaryPage && (onFull
               ? <button type="button" className="btn sm" onClick={onFull}>Full summary</button>
               : <a className="btn sm" href={href("summary")}>Full summary</a>)}
             {collapsible && (
               <button type="button" className="btn sm ghost" onClick={() => setOpen(!openPref)} aria-expanded={open}>
                 {open ? "Hide ▴" : "Show ▾"}
               </button>
             )}
           </>}>
      {!nd ? <Empty title="Loading…" /> : (
        <div className="plain">
          <div className={`plain-head hyp-${nd.hyp || "none"}`}>{nd.headline}</div>
          <p>{nd.text}</p>
          <div className="plain-note">
            {nd.note} {onSummaryPage ? "Exact estimates are in the full summary below." : "Exact estimates are in the full results summary."}
          </div>
        </div>
      )}
    </Panel>
  );
}
