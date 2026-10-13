import { href, useStored } from "../hooks";
import { Hyp, HYP_INFO } from "./ui";

/**
 * How many estimates support each hypothesis, plus how many disagree with the primary result.
 * Cells link to the matching Estimates filter. `collapsible` adds a Hide/Show toggle; the short form
 * is a one-line bar of the same counts and is the default; the choice is remembered per viewer under
 * `storageKey` — one shared setting for every page by default.
 */
export default function EvidenceTally({ checks, showPrimary = false, runLabel, collapsible = false,
                                        storageKey = "ctr.tally.open.compact", defaultOpen = false }) {
  const [openPref, setOpen] = useStored(storageKey, defaultOpen);
  const open = !collapsible || openPref;
  const { tally, primary } = checks;
  const disagree = checks.services.filter((x) => x.kind === "hypothesis" && x.supported && x.hyp && x.hyp !== primary).length;
  const link = { color: "inherit", textDecoration: "none", display: "block" };
  const toggle = collapsible && (
    <button type="button" className="btn sm ghost" onClick={() => setOpen(!openPref)} aria-expanded={open} style={{ marginLeft: "auto" }}>
      {open ? "Hide ▴" : "Show ▾"}
    </button>
  );

  if (!open) {
    return (
      <div className="panel tally-compact">
        <b>Evidence by hypothesis</b>
        {["H1", "H2", "H3", "H4"].map((h) => (
          <a key={h} href={`${href("services")}?filter=${h}`} title={`${HYP_INFO[h].long}: ${HYP_INFO[h].desc}`}
             className={`tc h${h[1]}${tally[h] ? "" : " zero"}${h === primary ? " lead" : ""}`}>
            <i /><span className="mono">{h}</span><b>{tally[h]}</b>
          </a>
        ))}
        <a href={`${href("services")}?filter=disagree`} className={`tc${disagree ? "" : " zero"}`}
           title="estimates that support a different hypothesis than the primary specification">
          <b>{disagree}</b> disagree with {primary || "primary"}
        </a>
        {toggle}
      </div>
    );
  }

  const cell = (h) => (
    <div key={h} className={`${tally[h] ? `on-h${h[1]}` : ""} ${h === primary ? "lead" : ""}`}>
      <a href={`${href("services")}?filter=${h}`} style={link} title={`${HYP_INFO[h].long}: ${HYP_INFO[h].desc}`}>
        <div className="lbl">{h}</div>
        <div className={`val ${tally[h] ? "" : "zero"}`}>{tally[h]}</div>
        <div className="nm">{HYP_INFO[h].short}</div>
      </a>
    </div>
  );
  return (
    <div className="panel infobox">
      <div className="title">
        Evidence by hypothesis
        {runLabel && <span className="muted" style={{ fontWeight: 400, fontSize: 12 }}>· {runLabel}</span>}
        {showPrimary && primary && <><span className="muted" style={{ fontWeight: 400, fontSize: 12 }}>· primary result</span> <Hyp h={primary} sm /></>}
        {toggle}
      </div>
      <div className="totals">
        {["H1", "H2", "H3", "H4"].map(cell)}
        <div>
          <a href={`${href("services")}?filter=disagree`} style={link} title="estimates that support a different hypothesis than the primary specification">
            <div className="lbl">Disagree</div>
            <div className={`val ${disagree ? "" : "zero"}`}>{disagree}</div>
            <div className="nm">with {primary || "primary"}</div>
          </a>
        </div>
      </div>
      <div className="muted" style={{ marginTop: 8, fontSize: 11 }}>
        number of estimates supporting each hypothesis · {checks.n_hypothesis} estimates, {tally.info} info rows
      </div>
    </div>
  );
}
