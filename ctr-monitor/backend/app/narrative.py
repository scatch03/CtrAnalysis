"""Plain-language 3–5 sentence reading of a structured result.

Fixed rules over the run's numbers — no model, nothing invented. Every claim maps to a
number in result.json; sentences whose inputs are missing are dropped. Kept deliberately
light on statistics: the exact estimates sit right below it in results_summary.txt.
"""
import math
import re
from datetime import date

ALPHA = 0.05
MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()


def _num(*xs):
    return all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in xs)


def _sig(b, p):
    if not _num(b, p):
        return None
    return "null" if p >= ALPHA else ("neg" if b < 0 else "pos")


def _big(n):
    if n >= 1e9:
        return f"{n / 1e9:.1f} billion"
    if n >= 1e6:
        return f"{n / 1e6:.0f} million" if n >= 1e7 else f"{n / 1e6:.1f} million"
    return f"{n:,.0f}"


def _round_volume(v):
    mag = 10 ** max(0, int(math.floor(math.log10(v))) - 1)
    return f"{round(v / mag) * mag:,.0f}"


def _dates(ds):
    try:
        a, b = (date.fromisoformat(str(ds[k])[:10]) for k in ("date_min", "date_max"))
    except (KeyError, TypeError, ValueError):
        return ds.get("date_range", "")
    if a.year == b.year:
        return f"{a.day} {MONTHS[a.month - 1]} – {b.day} {MONTHS[b.month - 1]} {b.year}"
    return f"{a.day} {MONTHS[a.month - 1]} {a.year} – {b.day} {MONTHS[b.month - 1]} {b.year}"


def _ctr_change(beta, base):
    """Relative CTR change for a doubling of hourly impressions implied by a logit slope, at baseline CTR `base`."""
    odds = math.exp(beta * math.log(2))
    return (odds / (1 - base + base * odds) - 1) * 100


def narrate(res):
    if not res or res.get("mode") != "structured":
        return None
    ds, reg = res["dataset"], res["regression"]
    w, tot, ols, q = reg["within"], reg["total"], reg["ols"]["m1"], reg["quadratic"]
    tz = ds.get("totals") or {}
    base = tz["clicks"] / tz["impr"] if tz.get("impr") else None
    s = []

    # 1 — what was analysed
    if _num(ds.get("n_final"), base):
        s.append(f"We looked at {ds['n_final']:,} campaign-hours from {ds['n_campaigns']} campaigns ({_dates(ds)}), "
                 f"with {_big(tz['impr'])} impressions and an average CTR of {base * 100:.2f}%.")

    # 2 — the main answer: does more volume change a campaign's own CTR?
    kind = _sig(w.get("b"), w.get("p"))
    headline, hyp = "Result not computable", None
    if kind and base is not None:
        r = abs(_ctr_change(w["b"], base))
        if kind == "null":
            t = ("The main finding: when a campaign serves more impressions in an hour, its CTR does not measurably "
                 f"change — doubling hourly volume moves CTR by only about {r:.0f}%, well within the range of chance")
            headline, hyp = "No sign that more volume lowers a campaign's CTR", "H4"
        elif kind == "neg":
            t = ("The main finding: when a campaign serves more impressions in an hour, its CTR goes down — doubling "
                 f"hourly volume lowers CTR by about {r:.0f}%, a statistically reliable drop consistent with ad fatigue")
            headline, hyp = "CTR falls as a campaign's hourly volume rises", "H1"
        else:
            t = ("The main finding: when a campaign serves more impressions in an hour, its CTR goes up — doubling "
                 f"hourly volume raises CTR by about {r:.0f}%, a statistically reliable increase")
            headline, hyp = "CTR rises with a campaign's hourly volume", "H3"
        b1, b2 = q["b1"].get("b"), q["b2"].get("b")
        if str(q.get("supports", "")).startswith("H2") and _num(b1, b2) and b2 < 0:
            t += (f"; looked at more closely, the curve is an inverted U, with CTR peaking around "
                  f"{_round_volume(math.exp(-b1 / (2 * b2)))} impressions per hour")
            headline, hyp = "CTR peaks at moderate hourly volume (inverted U)", "H2"
        s.append(t + ".")

    # 3 — between campaigns vs within (composition)
    bc = res.get("between", {}).get("stats", {})
    rho, prho = bc.get("spearman_rho"), bc.get("spearman_p")
    if reg.get("decomposition", {}).get("expected"):
        s.append("The overall drop in CTR you see when all campaigns are pooled comes from the campaign mix — "
                 "high-volume campaigns simply have lower CTR — not from volume hurting any single campaign.")
    elif _num(rho, prho) and prho < ALPHA:
        t = f"Campaigns that run at higher volume do tend to have {'lower' if rho < 0 else 'higher'} CTR than smaller ones"
        s.append(t + (", but that reflects differences between the campaigns themselves, not an effect of volume."
                      if kind == "null" else "."))
    elif _num(rho, prho):
        s.append("Across campaigns, size and CTR are not clearly related.")

    # 4 — the naive model, only when it points somewhere the GLM does not
    ok_ = _sig(ols.get("b"), ols.get("p"))
    if ok_ in ("neg", "pos") and kind and ok_ != kind:
        t = f"A simpler, unweighted model would suggest CTR {'falls' if ok_ == 'neg' else 'rises'} with volume"
        thr = [x for x in res["robustness"].get("threshold", []) if re.fullmatch(r"impr >= \d+", str(x.get("Filter")))]
        last = max(thr, key=lambda x: int(re.search(r"\d+", x["Filter"]).group())) if thr else None
        if last and _sig(last.get("OLS-logit β₁"), last.get("OLS p")) != ok_:
            t += ", but that signal disappears once hours with very few impressions are left out, so it shouldn't be trusted."
        else:
            t += ", but the more appropriate impression-weighted model doesn't confirm it."
        s.append(t)

    # 5 — robustness across segments (GLM re-estimates on subsets)
    rows = (res["robustness"].get("size", []) + res["robustness"].get("temporal", [])
            + res["robustness"].get("threshold", []))
    cls = [k for k in (_sig(x.get("GLM β₁"), x.get("GLM p")) for x in rows) if k]
    if cls and kind:
        n, neg, pos = len(cls), cls.count("neg"), cls.count("pos")
        if kind == "null" and not neg and not pos:
            s.append("The main finding holds across campaign-size groups, both halves of the period and stricter volume cut-offs.")
        elif kind == "null":
            if neg and pos:
                s.append(f"Splitting the data by campaign size, time period or volume cut-off gives mixed results "
                         f"({neg} of {n} slices show a decline, {pos} an increase), so there's no consistent pattern.")
            else:
                s.append(f"A few slices of the data ({neg or pos} of {n}, by campaign size, time period or volume cut-off) "
                         f"do show {'a decline' if neg else 'an increase'}, so it can't be ruled out for some campaigns.")
        elif cls.count(kind) == n:
            s.append("The main finding holds across campaign-size groups, both halves of the period and stricter volume cut-offs.")
        elif cls.count(kind) >= 0.75 * n:
            s.append(f"The main finding holds in most slices of the data ({cls.count(kind)} of {n}, by campaign size, "
                     "time period or volume cut-off).")
        else:
            s.append(f"The main finding is not uniform, though: only {cls.count(kind)} of {n} slices of the data "
                     "(by campaign size, time period or volume cut-off) show it clearly.")

    return {"headline": headline, "hyp": hyp, "sentences": s, "text": " ".join(s),
            "note": "Generated by fixed rules from this run's numbers, not by ctr_analysis.py. CTR changes are "
                    "relative (e.g. 2.0% → 2.1% is +5%), evaluated at the average CTR."}
