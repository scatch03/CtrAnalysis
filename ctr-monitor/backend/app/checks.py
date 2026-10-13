"""Every estimate in a run, labelled by the hypothesis it supports (paper §3.3).

  H1  fatigue      CTR falls with volume        (β < 0, p < .05)
  H2  inverted-U   rise then fall               (quadratic: β₁ > 0, β₂ < 0, p₂ < .05)
  H3  growth       CTR rises with volume        (β > 0, p < .05)
  H4  null         no detectable effect         (p ≥ .05)

This mirrors the script's own conclusion() / *_supports labels. Each estimate also
carries a `weight` tag saying how much the script trusts it (primary, pooled, naive,
descriptive, low power, few clusters, SE only, illustrative, …). Rows that are not a
hypothesis test (data, pipeline, dispersion, decomposition) are `info`.
"""
import re

from .jsonsafe import fnum

ALPHA = 0.05
HYPS = ("H1", "H2", "H3", "H4")

GROUPS = {
    "glm":              ("Binomial GLM", "§4.4 primary specification"),
    "decomposition":    ("Total vs within", "§4.7 composition"),
    "trend":            ("Trend tests", "§4.3 bucket-level, pooled"),
    "naive":            ("Naive OLS", "§4.4b OLS on logit(CTR)"),
    "curves":           ("Curve fitting", "§4.5 five bucket means"),
    "robust-size":      ("Robust · size", "§4.6a campaign size quartiles"),
    "robust-time":      ("Robust · time", "§4.6c temporal halves"),
    "robust-threshold": ("Robust · threshold", "§4.6d min-impression threshold"),
    "robust-spec":      ("Robust · spec", "§4.6b specification variants"),
    "dataset":          ("Dataset", "§4.1 ingest & exclusions"),
    "pipeline":         ("Pipeline", "run integrity, figures"),
}


def fp(p):
    if p is None:
        return "—"
    if p == 0:
        return "<1e-300"
    return f"{p:.2e}" if p < 1e-4 else f"{p:.4f}"


def stars(p):
    if p is None:
        return "—"
    return "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "n.s."


def hyp_of(b, p):
    """Same rule as the script's conclusion(): n.s. → H4, negative → H1, positive → H3."""
    if b is None or p is None:
        return None
    if p >= ALPHA:
        return "H4"
    return "H3" if b > 0 else "H1"


def first_hyp(text):
    m = re.match(r"\s*(H[1-4])\b", str(text or ""))
    return m.group(1) if m else None


def fmt_beta(b, lo=None, hi=None, p=None, sym="β₁"):
    if b is None:
        return f"{sym} not computable"
    s = f"{sym}={b:+.4f}"
    if lo is not None and hi is not None:
        s += f" CI[{lo:+.4f}, {hi:+.4f}]"
    if p is not None:
        s += f" p={fp(p)} {stars(p)}"
    return s


def perf(**kv):
    return " ".join(f"{k}={v:.6g}" for k, v in kv.items() if v is not None)


class _Builder:
    def __init__(self, stage_times):
        self.rows, self.stage_times = [], stage_times or {}

    def add(self, group, service, output, *, hyp=None, supported=True, weight=None, info=False, stage=None,
            perfdata="", detail=None, view=None, note=None, primary=False):
        self.rows.append({
            "id": f"{group}/{service}", "host": group, "service": service,
            "kind": "info" if info else "hypothesis", "hyp": hyp, "supported": supported,
            "weight": weight, "primary": primary, "output": output, "perf": perfdata,
            "detail": detail or [], "note": note, "stage": stage, "duration": self.stage_times.get(stage), "view": view,
        })

    def effect(self, group, service, est, *, weight=None, note=None, stage, view=None, label=None, extra=None, primary=False):
        b, lo, hi, p = (fnum(est.get(k)) for k in ("b", "lo", "hi", "p"))
        out = f"{label + ' · ' if label else ''}{fmt_beta(b, lo, hi, p)}"
        if extra:
            out += f" · {extra}"
        self.add(group, service, out, hyp=hyp_of(b, p), weight=weight, note=note, stage=stage, view=view,
                 primary=primary, perfdata=perf(beta=b, ci_lo=lo, ci_hi=hi, p=p))


def build_checks(res, stage_times=None, figure_errors=None):
    c = _Builder(stage_times)
    ds, reg = res["dataset"], res["regression"]
    w = reg["within"]

    # ── GLM (primary) ───────────────────────────────────────────────────────
    c.effect("glm", "within_slope", w, stage="regression", view="analysis/marginal", weight="primary", primary=True,
             label="campaign + time FE, clustered SE",
             extra=f"OR per doubling {w['or_doubling'][0]:.4f}" if w.get("or_doubling") and w["or_doubling"][0] else None)
    q = reg["quadratic"]
    b2, p2 = fnum(q["b2"].get("b")), fnum(q["b2"].get("p"))
    h2 = str(q.get("supports", "")).startswith("H2")
    c.add("glm", "quadratic_h2",
          f"{fmt_beta(b2, q['b2'].get('lo'), q['b2'].get('hi'), p2, 'β₂')} · ΔQAIC(M2−M1)={q['dqaic']:+.1f} · {q.get('supports')}"
          if b2 is not None and q.get("dqaic") is not None else str(q.get("supports") or "not computable"),
          hyp="H2" if b2 is not None else None, supported=h2, weight="primary", stage="regression",
          view="analysis/curves", perfdata=perf(beta2=b2, p=p2, dqaic=fnum(q.get("dqaic"))))
    c.effect("glm", "total_slope", reg["total"], stage="regression", view="analysis/between", weight="pooled",
             label="time FE only, no campaign FE")
    phi = fnum(reg.get("phi"))
    c.add("glm", "overdispersion",
          f"φ = Pearson χ²/df = {phi:.2f} (φ ≫ 1 → raw AIC/BIC unreliable; QAIC used for model comparison)"
          if phi is not None else "φ not computable", info=True, stage="regression", perfdata=perf(phi=phi))

    # ── decomposition (§4.7) ───────────────────────────────────────────────
    d = reg["decomposition"]
    c.add("decomposition", "total_vs_within",
          (f"β_total={d['b_total']:+.4f} {stars(d.get('p_total'))} − β_within={d['b_within']:+.4f} "
           f"{stars(d.get('p_within'))} = {d['diff']:+.4f} composition · {d['message']}")
          if d.get("b_total") is not None and d.get("b_within") is not None else d.get("message", "not computable"),
          info=True, stage="regression", view="analysis/between",
          perfdata=perf(b_total=fnum(d.get("b_total")), b_within=fnum(d.get("b_within")), diff=fnum(d.get("diff"))))
    bc = res["between"]["stats"]
    rho, p = fnum(bc.get("spearman_rho")), fnum(bc.get("spearman_p"))
    c.add("decomposition", "campaign_rank_corr",
          f"n={bc.get('n_campaigns')} campaigns · Spearman ρ={rho:+.3f} (p={fp(p)}) · Kendall τ="
          f"{fnum(bc.get('kendall_tau')):+.3f} (p={fp(fnum(bc.get('kendall_p')))}) — association across campaigns, not within"
          if rho is not None else "not computable", info=True, stage="between", view="analysis/between",
          perfdata=perf(rho=rho, p=p))

    # ── trend tests ─────────────────────────────────────────────────────────
    t = res["trend"]
    ca_, sp = t["cochran_armitage"], t["spearman"]
    z, p = fnum(ca_.get("Z_CA")), fnum(ca_.get("p"))
    c.add("trend", "cochran_armitage",
          f"Z_CA={z:+.3f} p={fp(p)} {stars(p)} · {ca_.get('direction')} · {ca_.get('supports')}"
          if z is not None and p is not None else "not computable",
          hyp=first_hyp(ca_.get("supports")), weight="descriptive", note=ca_.get("note"),
          stage="trend", view="analysis/buckets", perfdata=perf(z=z, p=p))
    rho, p = fnum(sp.get("rho")), fnum(sp.get("p"))
    c.add("trend", "spearman_buckets",
          f"ρ={rho:+.3f} p={fp(p)} {stars(p)} · {sp.get('supports')}" if rho is not None and p is not None
          else "not computable", hyp=first_hyp(sp.get("supports")), weight="low power", note=sp.get("note"),
          stage="trend", view="analysis/buckets", perfdata=perf(rho=rho, p=p))

    # ── naive OLS ───────────────────────────────────────────────────────────
    o = reg["ols"]["m1"]
    agree = hyp_of(fnum(o.get("b")), fnum(o.get("p"))) == hyp_of(fnum(w.get("b")), fnum(w.get("p")))
    c.effect("naive", "ols_logit_within", o, weight="naive", stage="regression", view="analysis/marginal",
             note="zero-click hours clipped to logit(1e-6), all hours weighted equally",
             extra="agrees with the GLM" if agree else "disagrees with the GLM")

    # ── curve fitting ───────────────────────────────────────────────────────
    cv = res["curves"]["models"]
    best = next((m for m in cv if m.get("best")), None)
    failed = [m["model"] for m in cv if m.get("failed")]
    out = (f"best AIC: {best['model']} (R²={best['r2']:.3f})" if best and best.get("r2") is not None
           else f"best AIC: {best['model']}" if best else "no valid fit")
    if failed:
        out += f" · no valid solution: {', '.join(failed)}"
    c.add("curves", "best_fit", out, hyp=best.get("key") if best else None, weight="illustrative",
          stage="curves", view="analysis/curves", note="5 bucket means — illustrative only",
          detail=[[m["model"], "failed" if m.get("failed") else f"AIC={m.get('aic')}  R²={m.get('r2')}"] for m in cv])

    # ── robustness ──────────────────────────────────────────────────────────
    rb = res["robustness"]
    for r in rb["size"]:
        c.effect("robust-size", _slug(r["Quartile"]), _glm(r), stage="robustness", view="analysis/forest",
                 weight="few clusters", note=f"{r.get('N campaigns')} clusters — cluster-robust p approximate",
                 extra=f"{r.get('N campaigns')} campaigns, {r.get('N obs'):,} obs")
    for r in rb["temporal"]:
        c.effect("robust-time", _slug(r["Period"]), _glm(r), stage="robustness", view="analysis/forest",
                 extra=r.get("Date range"))
    for r in rb["threshold"]:
        c.effect("robust-threshold", _slug(r["Filter"]), _glm(r), stage="robustness", view="analysis/threshold",
                 extra=f"zero-click {r['Zero-click share (all)'] * 100:.1f}% · OLS β₁={r.get('OLS-logit β₁'):+.4f}"
                 if r.get("Zero-click share (all)") is not None and r.get("OLS-logit β₁") is not None else None)
    for r in rb["spec"]:
        c.effect("robust-spec", _spec_name(r["Specification"]), {"b": r.get("β₁"), "lo": r.get("ci_lo"),
                 "hi": r.get("ci_hi"), "p": r.get("p")}, stage="robustness", view="analysis/forest",
                 weight=_spec_weight(r.get("Role")), label=r.get("Role"), extra=r.get("Specification"))

    # ── dataset ─────────────────────────────────────────────────────────────
    notes = []
    if ds.get("n_unmatched_banners"):
        notes.append(f"{ds['n_unmatched_banners']:,} event rows without campaign mapping dropped")
    if ds.get("dead_campaigns"):
        notes.append(f"{ds['dead_campaigns']} campaign(s) with 0 clicks over whole period excluded "
                     "(click tracking failure / non-clickable placement)")
    kept = ds["n_final"] / ds["n_after_agg"] * 100 if ds.get("n_after_agg") else None
    c.add("dataset", "ingest",
          f"{ds['n_raw']:,} raw rows → {ds['n_final']:,} campaign-hours"
          f"{f' ({kept:.1f}% of aggregated)' if kept is not None else ''} · {ds['n_campaigns']} campaigns · {ds['date_range']}",
          info=True, note="; ".join(notes) or None, stage="load", view="overview",
          perfdata=perf(rows_raw=ds["n_raw"], rows_final=ds["n_final"], campaigns=ds["n_campaigns"]),
          detail=[[e["label"], f"{e['n']:,}"] for e in ds.get("exclusions", [])])
    zc = fnum(ds.get("zero_click_share"))
    c.add("dataset", "zero_click_hours",
          f"zero-click share {zc * 100:.1f}% of campaign-hours · drives the naive-OLS bias (see §4.6d)"
          if zc is not None else "zero-click share not computable",
          info=True, stage="load", view="graphs", perfdata=perf(zero_click_share=zc))
    if ds.get("n_ctr_outliers") is not None:
        c.add("dataset", "ctr_outliers", f"{ds['n_ctr_outliers']:,} campaign-hours with CTR > 20% — flagged, not removed",
              info=True, stage="load", view="campaigns", perfdata=perf(flagged=ds["n_ctr_outliers"]))

    # ── pipeline ────────────────────────────────────────────────────────────
    n_fig = len(res.get("figures") or [])
    c.add("pipeline", "figures",
          f"{n_fig} publication figure(s) rendered (PDF + PNG preview)"
          + (f", {len(figure_errors)} failed: " + ", ".join(f"{k} ({v})" for k, v in figure_errors.items())
             if figure_errors else ""),
          info=True, note="some figures failed" if figure_errors else None, stage="figures", view="files",
          perfdata=perf(figures=n_fig))
    total = sum(v for v in (stage_times or {}).values() if v)
    c.add("pipeline", "runtime", f"pipeline completed in {total:.1f}s across {len(stage_times or {})} stages",
          info=True, perfdata=perf(seconds=total), detail=[[k, f"{v:.2f}s"] for k, v in (stage_times or {}).items()])

    rows = c.rows
    tally = {h: sum(1 for r in rows if r["hyp"] == h and r["supported"]) for h in HYPS}
    tally["info"] = sum(1 for r in rows if r["kind"] == "info")
    primary = next((r["hyp"] for r in rows if r["id"] == "glm/within_slope"), None)
    if h2:
        primary = "H2"
    groups = []
    for g, (name, desc) in GROUPS.items():
        gr = [r for r in rows if r["host"] == g]
        if gr:
            groups.append({"id": g, "name": name, "desc": desc,
                           "tally": {h: sum(1 for r in gr if r["hyp"] == h and r["supported"]) for h in HYPS}})
    return {"services": rows, "tally": tally, "primary": primary, "groups": groups,
            "n_hypothesis": sum(1 for r in rows if r["kind"] == "hypothesis")}


def _glm(r):
    return {"b": r.get("GLM β₁"), "lo": r.get("glm_ci_lo"), "hi": r.get("glm_ci_hi"), "p": r.get("GLM p")}


def _spec_weight(role):
    role = str(role or "")
    if role.startswith("PRIMARY"):
        return "primary"
    if role.startswith("TOTAL"):
        return "pooled"
    if "naive" in role.lower():
        return "naive"
    if "SE only" in role:
        return "SE only"
    if "weighted" in role.lower():
        return "weighted"
    return None


def _slug(s):
    s = re.sub(r"[^0-9A-Za-z>=<]+", "_", str(s)).strip("_").lower()
    return s.replace(">=", "ge").replace("<", "lt").replace(">", "gt").replace("=", "")[:60]


def _spec_name(spec):
    """'Binomial GLM (logit), campaign FE + time FE, clustered SE' → 'glm_campFE+timeFE_cluster'."""
    s = str(spec)
    est = "wls" if s.startswith("WLS") else "glm" if "GLM" in s else "ols" if "OLS" in s else "model"
    fe = ("campFE+timeFE" if "campaign FE + time FE" in s else "timeFE" if "time FE only" in s
          else "campFE" if "campaign FE only" in s else "fe")
    se = "hc3" if "HC3" in s else "cluster" if "clustered" in s else "se"
    return f"{est}_{fe}_{se}"


SIZE_LABELS = ["Q1 (smallest)", "Q2", "Q3", "Q4 (largest)"]


def size_quartiles(res):
    """Campaign → size quartile, by the same rule as the script's assign_size_quartiles()
    (qcut of each campaign's median hourly impressions), joined to that quartile's §4.6a
    estimates. Adds `size_q` to every campaign row; returns one summary per quartile."""
    import pandas as pd

    camps = (res.get("between") or {}).get("campaigns") or []
    if not camps:
        return None
    med = pd.Series([c.get("median_impr") for c in camps], index=[c["campaign"] for c in camps], dtype=float)
    try:
        q = pd.qcut(med, q=4, labels=SIZE_LABELS, duplicates="drop")
    except ValueError:  # too many tied medians for four bins — the script would fail here too
        return None
    for c in camps:
        lab = q.get(c["campaign"])
        c["size_q"] = lab.split(" ")[0] if isinstance(lab, str) else None
    est = {r.get("Quartile"): r for r in (res.get("robustness") or {}).get("size", [])}
    out = []
    for lab in SIZE_LABELS:
        r = est.get(lab)
        glm = {"b": fnum(r.get("GLM β₁")), "lo": fnum(r.get("glm_ci_lo")), "hi": fnum(r.get("glm_ci_hi")),
               "p": fnum(r.get("GLM p"))} if r else None
        ols = {"b": fnum(r.get("OLS-logit β₁")), "p": fnum(r.get("OLS p"))} if r else None
        out.append({
            "label": lab, "short": lab.split(" ")[0], "n_campaigns": int((q == lab).sum()),
            "tested": r is not None,  # the script skips quartiles with < 30 campaign-hours
            "hyp": hyp_of(glm["b"], glm["p"]) if glm else None, "glm": glm,
            "ols_hyp": hyp_of(ols["b"], ols["p"]) if ols else None, "ols": ols,
            "n_obs": r.get("N obs") if r else None, "median_impr": fnum(r.get("Median impr/hr")) if r else None,
            "zero_click_share": fnum(r.get("Zero-click share")) if r else None,
        })
    return out
