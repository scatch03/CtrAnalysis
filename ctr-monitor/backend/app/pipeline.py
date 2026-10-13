"""Structured wrapper around the drop-in ctr_analysis.py.

Mirrors the script's main() step for step — same function calls, same output
files in out/ — but keeps the in-memory results so the web UI can render them
natively. The script itself is never modified; its `save` and `_caption` hooks
are wrapped to also emit PNG previews and record figure captions.
"""
import importlib.util
import re
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import numpy as np
import pandas as pd

from . import config
from .checks import build_checks
from .jsonsafe import clean, fnum
from .memfix import peak_rss_gb
from .store import write_json

STAGES = [
    ("load", "Loading & cleaning"),
    ("descriptive", "Descriptive statistics"),
    ("trend", "Trend tests"),
    ("regression", "Regression (GLM primary + total + naive OLS)"),
    ("curves", "Curve fitting"),
    ("robustness", "Robustness checks"),
    ("between", "Between-campaign analysis"),
    ("figures", "Generating figures"),
    ("summary", "Writing results summary"),
    ("webdata", "Preparing web views"),
]
LEGACY_STAGES = [("legacy", "Running script main() (legacy mode)"), ("webdata", "Collecting outputs")]


def load_script(path):
    spec = importlib.util.spec_from_file_location("ctr_analysis", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ctr_analysis"] = mod
    spec.loader.exec_module(mod)
    return mod


class Progress:
    def __init__(self, run_dir, stages):
        self.path, self.stages, self.times, self.current = Path(run_dir) / "progress.json", stages, {}, None
        self.mem = {}   # peak resident memory (GB) of the worker after each stage
        self._lock = threading.Lock()
        self._written_peak = None
        self._write()
        # keep peak memory current during long stages (and right up to an out-of-memory kill)
        threading.Thread(target=self._watch_memory, name="progress-mem", daemon=True).start()

    def _watch_memory(self):
        while True:
            time.sleep(3)
            if self._written_peak is None or peak_rss_gb() - self._written_peak >= 0.1:
                self._write()

    def _write(self):
        keys = [k for k, _ in self.stages]
        with self._lock:
            self._written_peak = peak_rss_gb()
            write_json(self.path, {"stages": [{"key": k, "label": l} for k, l in self.stages],
                                   "current": self.current,
                                   "index": keys.index(self.current) if self.current in keys else len(self.times),
                                   "times": dict(self.times), "mem": dict(self.mem), "peak_gb": self._written_peak})

    @contextmanager
    def stage(self, key):
        label = dict(self.stages)[key]
        print(f"\n── {label} " + "─" * max(3, 58 - len(label)), flush=True)
        self.current = key
        self._write()
        t0 = time.perf_counter()
        yield
        self.times[key] = round(time.perf_counter() - t0, 3)
        self.mem[key] = peak_rss_gb()
        self.current = None
        self._write()


# ═════════════════════════════════════════════════════════════════════════════
# helpers
# ═════════════════════════════════════════════════════════════════════════════

def camp_key(x):
    """Campaign ids come back as float after the left merge (1234.0) — show them as ints."""
    if isinstance(x, (float, np.floating)) and np.isfinite(x) and float(x).is_integer():
        return str(int(x))
    return str(x)


def parse_ci(s):
    nums = re.findall(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|nan", str(s))
    if len(nums) < 2:
        return None, None
    return fnum(nums[0]), fnum(nums[1])


def coef(ca, m, name="log_v"):
    b, lo, hi, p = ca.coef_summary(m, name)
    return {"b": fnum(b), "lo": fnum(lo), "hi": fnum(hi), "p": fnum(p)}


def dbl(b):
    return fnum(np.exp(b * np.log(2))) if fnum(b) is not None else None


def table_records(df):
    return clean(df.to_dict("records"))


# ═════════════════════════════════════════════════════════════════════════════
# structured run
# ═════════════════════════════════════════════════════════════════════════════

def run_structured(ca, run_dir, mapping, events, min_impr, dpi):
    run_dir = Path(run_dir)
    out = run_dir / "out"
    out.mkdir(parents=True, exist_ok=True)
    pg = Progress(run_dir, STAGES)

    ca.MIN_IMPRESSIONS = int(min_impr)          # main() does the same via `global`
    figures, fig_errors = [], {}
    _save, _caption = ca.save, getattr(ca, "_caption", lambda note: print(f"     ↳ {note}"))

    def save(fig, path, dpi_):
        path = Path(path)
        png = path.with_suffix(".png")
        try:
            fig.savefig(png, dpi=config.WEB_DPI, bbox_inches="tight")
        except Exception as e:  # preview only — never fail the run over it
            print(f"  [WARN] PNG preview failed for {path.name}: {e}")
        _save(fig, path, dpi_)
        figures.append({"name": path.stem, "file": path.name,
                        "png": png.name if png.exists() else None, "caption": None})

    def caption(note):
        if figures:
            figures[-1]["caption"] = note
        _caption(note)

    ca.save, ca._caption = save, caption

    with pg.stage("load"):
        df, df_pre, log = ca.load_and_clean(str(mapping), str(events))
        print(f"  {log['n_final']:,} records | {log['n_campaigns']:,} campaigns | {log['date_range']}")
        if log["n_final"] == 0:
            raise RuntimeError("no rows left after cleaning — check the input files and --min-impr")

    with pg.stage("descriptive"):
        desc = ca.descriptive_stats(df)
        desc.to_csv(out / "table2_descriptive.csv", index=False)

    with pg.stage("trend"):
        ca_t, sp = ca.cochran_armitage(df), ca.spearman_test(df)
        pd.DataFrame([{**{f"CA_{k}": v for k, v in ca_t.items()}, **{f"Sp_{k}": v for k, v in sp.items()}}]
                     ).to_csv(out / "table3_trend_tests.csv", index=False)

    with pg.stage("regression"):
        reg = ca.run_regression(df)
        for tag, m in (("table4_glm_within_linear.csv", reg["m1"]), ("table4b_glm_within_quadratic.csv", reg["m2"]),
                       ("table4t_glm_total_linear.csv", reg["m_total"]),
                       ("table4c_ols_logit_linear.csv", reg["ols_m1"]), ("table4d_ols_logit_quadratic.csv", reg["ols_m2"])):
            pd.DataFrame({"predictor": m.params.index, "coef": m.params.values, "ci_lo": m.conf_int()[0].values,
                          "ci_hi": m.conf_int()[1].values, "p": m.pvalues.values}).to_csv(out / tag, index=False)

    with pg.stage("curves"):
        curve_tbl, bkt_df = ca.fit_curves(df)
        curve_tbl.to_csv(out / "table5_curve_fitting.csv", index=False)

    with pg.stage("robustness"):
        rb_size = ca.robustness_by_size(df)
        rb_spec = ca.robustness_specifications(df, reg)
        rb_time = ca.robustness_temporal(df)
        sens = ca.robustness_threshold_sensitivity(df_pre)
        rb_size.to_csv(out / "table6_robustness_size.csv", index=False)
        rb_spec.to_csv(out / "table7_robustness_spec.csv", index=False)
        rb_time.to_csv(out / "table8_robustness_time.csv", index=False)
        sens.to_csv(out / "table11_threshold_sensitivity.csv", index=False)

    with pg.stage("between"):
        camp, bc = ca.between_campaign_analysis(df)
        camp.to_csv(out / "table12_campaign_level.csv", index=False)
        pd.DataFrame([bc]).to_csv(out / "table12b_between_campaign_fit.csv", index=False)

    with pg.stage("figures"):
        for name, fn in (("fig1_boxplots", lambda: ca.fig1_boxplots(df, out, dpi)),
                         ("fig2_mean_ctr_ci", lambda: ca.fig2_mean_ci(df, out, dpi)),
                         ("fig3_hourly_pattern", lambda: ca.fig3_hourly(df, out, dpi)),
                         ("fig4_marginal_effect", lambda: ca.fig4_marginal(df, reg, out, dpi)),
                         ("fig5_curve_fitting", lambda: ca.fig5_curves(df, curve_tbl, bkt_df, out, dpi)),
                         ("fig6_between_campaign", lambda: ca.fig6_between_campaign(camp, bc, reg, out, dpi)),
                         ("fig7_threshold_sensitivity", lambda: ca.fig7_threshold_sensitivity(sens, out, dpi))):
            try:
                fn()
            except Exception as e:
                fig_errors[name] = f"{type(e).__name__}: {e}"
                print(f"  [WARN] {name} failed: {fig_errors[name]}")
            finally:
                import matplotlib.pyplot as plt
                plt.close("all")

    with pg.stage("summary"):
        ca.write_summary(out / "results_summary.txt", log, desc, ca_t, sp, reg, curve_tbl,
                         rb_size, rb_spec, rb_time, sens, bc)

    with pg.stage("webdata"):
        res = build_results(ca, df, df_pre, log, desc, ca_t, sp, reg, curve_tbl, bkt_df,
                            rb_size, rb_spec, rb_time, sens, camp, bc)
        res["figures"] = figures
        res["files"] = list_outputs(out)
        save_panel(run_dir, df_pre)
        res["figure_errors"] = fig_errors
        res["checks"] = build_checks(res, pg.times, fig_errors)
        res["mode"] = "structured"
        res["stage_times"] = pg.times
        write_json(run_dir / "result.json", clean(res))
    print(f"\n✅  Done. Results saved to: {out}\n", flush=True)


def run_legacy(ca, run_dir, mapping, events, min_impr, dpi):
    """Script lacks the functions the structured wrapper needs → run its own main()."""
    run_dir = Path(run_dir)
    out = run_dir / "out"
    out.mkdir(parents=True, exist_ok=True)
    pg = Progress(run_dir, LEGACY_STAGES)
    figures = []
    if hasattr(ca, "save"):
        _save = ca.save

        def save(fig, path, dpi_):
            path = Path(path)
            try:
                fig.savefig(path.with_suffix(".png"), dpi=config.WEB_DPI, bbox_inches="tight")
            except Exception:
                pass
            _save(fig, path, dpi_)
            figures.append({"name": path.stem, "file": path.name, "png": path.with_suffix(".png").name, "caption": None})

        ca.save = save
    with pg.stage("legacy"):
        sys.argv = ["ctr_analysis.py", "--mapping", str(mapping), "--events", str(events),
                    "--out", str(out), "--dpi", str(dpi), "--min-impr", str(min_impr)]
        ca.main()
    with pg.stage("webdata"):
        write_json(run_dir / "result.json", clean({"mode": "legacy", "figures": figures,
                                                   "files": list_outputs(out), "stage_times": pg.times}))


def list_outputs(out):
    files = []
    for p in sorted(Path(out).iterdir()):
        if p.is_file():
            kind = {".csv": "table", ".pdf": "figure", ".png": "preview", ".txt": "summary"}.get(p.suffix, "other")
            files.append({"name": p.name, "kind": kind, "size": p.stat().st_size})
    return files


def save_panel(run_dir, df_pre):
    """Hourly campaign panel for the MRTG graphs (after hard exclusions, before the min-impr filter)."""
    p = df_pre[["campaign", "hour", "impr", "clicks"]].copy()
    p["campaign"] = p["campaign"].map(camp_key)
    p["impr"] = p["impr"].astype("int64")
    p["clicks"] = p["clicks"].astype("int64")
    p.to_pickle(Path(run_dir) / "panel.pkl")


# ═════════════════════════════════════════════════════════════════════════════
# structured results for the UI
# ═════════════════════════════════════════════════════════════════════════════

def build_results(ca, df, df_pre, log, desc, ca_t, sp, reg, curve_tbl, bkt_df,
                  rb_size, rb_spec, rb_time, sens, camp, bc):
    m1, m2, mt = reg["m1"], reg["m2"], reg["m_total"]
    s1, s2, st = reg["m1_stats"], reg["m2_stats"], reg["m_total_stats"]
    w, tot = coef(ca, m1), coef(ca, mt)
    expected = (tot["p"] is not None and w["p"] is not None and tot["p"] < 0.05 and tot["b"] < 0 and w["p"] >= 0.05)

    dataset = {
        "n_raw": log["n_raw"], "n_banners": log["n_banners"], "n_campaigns": log["n_campaigns"],
        "n_after_agg": log["n_after_agg"], "n_final": log["n_final"], "date_range": log["date_range"],
        "date_min": df["hour"].min(), "date_max": df["hour"].max(),
        "zero_click_share": log["zero_click_share"], "dead_campaigns": log.get("dead_campaigns"),
        "n_unmatched_banners": log.get("n_unmatched_banners"),
        "n_ctr_outliers": int(df["ctr_outlier"].sum()) if "ctr_outlier" in df else None,
        "exclusions": [{"label": k, "n": int(v)} for k, v in log["exclusions"].items()],
        "impr_stats": log["impr_stats"].to_dict(), "ctr_stats": log["ctr_stats"].to_dict(),
        "min_impr": ca.MIN_IMPRESSIONS,
        "totals": {"impr": int(df["impr"].sum()), "clicks": int(df["clicks"].sum())},
    }

    regression = {
        "phi": s2["phi"],
        "within": {**w, "or_doubling": [dbl(w["b"]), dbl(w["lo"]), dbl(w["hi"])],
                   "pseudo_r2": s1["pseudo_r2"], "qaic": s1["qaic"], "aic": s1["aic"],
                   "nobs": int(m1.nobs), "k": s1["k"], "supports": reg["m1_supports"]},
        "quadratic": {"b1": coef(ca, m2), "b2": coef(ca, m2, "log_v_sq"), "pseudo_r2": s2["pseudo_r2"],
                      "qaic": s2["qaic"], "aic": s2["aic"], "dqaic": s2["qaic"] - s1["qaic"],
                      "daic": s2["aic"] - s1["aic"], "supports": reg["m2_supports"]},
        "total": {**tot, "or_doubling": [dbl(tot["b"]), dbl(tot["lo"]), dbl(tot["hi"])],
                  "pseudo_r2": st["pseudo_r2"], "phi": st["phi"], "nobs": int(mt.nobs)},
        "ols": {"m1": {**coef(ca, reg["ols_m1"]), "r2": float(reg["ols_m1"].rsquared),
                       "supports": reg["ols_m1_supports"]},
                "m2": {"b1": coef(ca, reg["ols_m2"]), "b2": coef(ca, reg["ols_m2"], "log_v_sq")}},
        "decomposition": {
            "b_total": tot["b"], "p_total": tot["p"], "b_within": w["b"], "p_within": w["p"],
            "diff": (tot["b"] - w["b"]) if tot["b"] is not None and w["b"] is not None else None,
            "expected": bool(expected),
            # verbatim from the script's §4.7 block
            "message": ("Aggregate decline is a between-campaign composition effect; within-campaign association is null."
                        if expected else "Check: pattern differs from the expected (β_total<0 sig., β_within≈0)."),
        },
    }

    # curve fits → model rows + smooth lines for the chart
    labels = {getattr(ca, "H1_LABEL", "H1"): ("H1", ca.h1_decay), getattr(ca, "H2_LABEL", "H2"): ("H2", ca.h2_inverted_u),
              getattr(ca, "H3_LABEL", "H3"): ("H3", ca.h3_saturating), getattr(ca, "H4_LABEL", "H4"): ("H4", ca.h4_null)}
    V = bkt_df["mean_logv"].values.astype(float)
    V_s = np.linspace(V.min(), V.max(), 120)
    models = []
    for _, r in curve_tbl.iterrows():
        key, fn = labels.get(r["Model"], (str(r["Model"])[:2], None))
        failed = r["Params"] == "failed"
        line = None
        if not failed and fn is not None:
            popt = [float(x) for x in str(r["Params"]).split(", ")]
            line = np.column_stack([V_s, fn(V_s, *popt)]).round(6).tolist()
        models.append({"key": key, "model": r["Model"], "params": r["Params"], "k": r.get("k"),
                       "r2": fnum(r.get("R²")), "rmse": fnum(r.get("RMSE")), "aic": fnum(r.get("AIC")),
                       "bic": fnum(r.get("BIC")), "best": bool(r.get("Best fit")), "failed": bool(failed),
                       "line": line})
    buckets = [{"bucket": int(b), "mean_logv": float(v), "mean_ctr": float(c) * 100}
               for b, v, c in zip(bkt_df["bucket_int"], bkt_df["mean_logv"], bkt_df["mean_ctr"])]

    # robustness tables + numeric CIs for the forest plot
    def with_ci(tbl, cols):
        recs = table_records(tbl)
        for r in recs:
            for src, lo_k, hi_k in cols:
                if src in r:
                    r[lo_k], r[hi_k] = parse_ci(r[src])
        return recs
    glm_ols = [("GLM 95% CI", "glm_ci_lo", "glm_ci_hi"), ("OLS 95% CI", "ols_ci_lo", "ols_ci_hi")]
    robustness = {"size": with_ci(rb_size, glm_ols), "temporal": with_ci(rb_time, glm_ols),
                  "threshold": with_ci(sens, glm_ols), "spec": with_ci(rb_spec, [("95% CI", "ci_lo", "ci_hi")])}

    return {
        "dataset": dataset,
        "descriptive": table_records(desc),
        "trend": {"cochran_armitage": ca_t, "spearman": sp},
        "regression": regression,
        "curves": {"models": models, "buckets": buckets},
        "robustness": robustness,
        "between": {"stats": bc, "campaigns": campaign_rows(camp, df)},
        "charts": chart_data(ca, df, reg, camp),
    }


def campaign_rows(camp, df):
    g = df.groupby("campaign")
    extra = pd.DataFrame({
        "first": g["hour"].min(), "last": g["hour"].max(),
        "outlier_hours": g["ctr_outlier"].sum() if "ctr_outlier" in df else 0,
        "zero_click_share": g["clicks"].apply(lambda s: float((s == 0).mean())),
        "median_impr": g["impr"].median(),
    })
    daily = (df.assign(day=df["hour"].dt.floor("D")).groupby(["campaign", "day"])[["clicks", "impr"]].sum())
    daily["ctr"] = daily["clicks"] / daily["impr"] * 100
    days = pd.date_range(df["hour"].min().floor("D"), df["hour"].max().floor("D"), freq="D")
    rows = []
    for _, r in camp.iterrows():
        c = r["campaign"]
        e = extra.loc[c]
        try:
            spark = daily.loc[c]["ctr"].reindex(days)
        except KeyError:
            spark = pd.Series(index=days, dtype=float)
        rows.append({"campaign": camp_key(c), "clicks": int(r["clicks"]), "impr": int(r["impr"]),
                     "n_obs": int(r["n_obs"]), "mean_logv": fnum(r["mean_logv"]), "ctr": fnum(r["ctr"] * 100),
                     "first": e["first"], "last": e["last"], "outlier_hours": int(e["outlier_hours"]),
                     "zero_click_share": fnum(e["zero_click_share"]), "median_impr": fnum(e["median_impr"]),
                     "spark": [fnum(v) for v in spark.values]})
    rows.sort(key=lambda r: -r["impr"])
    return rows


def chart_data(ca, df, reg, camp):
    labels = ["B1", "B2", "B3", "B4", "B5"]
    thresholds = list(getattr(ca, "BUCKET_THRESHOLDS", [0, 500, 2000, 10000, 50000, np.inf]))
    ranges = [[fnum(thresholds[i]), fnum(thresholds[i + 1])] for i in range(len(labels))]

    # fig1 — boxplots, y capped at the 99th percentile exactly like the script
    ctr_pct = df["ctr"].dropna() * 100
    cap = float(np.percentile(ctr_pct, 99))
    box = []
    for i, b in enumerate(labels):
        s = df.loc[df["bucket"] == b]
        v = np.clip(s["ctr"].dropna().values * 100, 0, cap)
        if len(v) == 0:
            box.append({"bucket": b, "n": 0, "range": ranges[i]})
            continue
        q1, med, q3 = np.percentile(v, [25, 50, 75])
        iqr = q3 - q1
        lo_w = v[v >= q1 - 1.5 * iqr].min()
        hi_w = v[v <= q3 + 1.5 * iqr].max()
        box.append({"bucket": b, "range": ranges[i], "n": int(len(v)), "q1": q1, "median": med, "q3": q3,
                    "whisker_lo": lo_w, "whisker_hi": hi_w, "n_fliers": int(((v < lo_w) | (v > hi_w)).sum()),
                    "mean": float(s["ctr"].mean() * 100), "zero_click_share": float((s["clicks"] == 0).mean()),
                    "impr": int(s["impr"].sum()), "clicks": int(s["clicks"].sum())})

    # fig2 — mean ± 1.96·SEM
    from scipy import stats as _st
    g = df.groupby("bucket", observed=True)["ctr"].agg(["mean", _st.sem, "count"]).reset_index()
    mean_ci = [{"bucket": str(r["bucket"]), "mean": r["mean"] * 100, "sem": r["sem"] * 100,
                "lo": (r["mean"] - 1.96 * r["sem"]) * 100, "hi": (r["mean"] + 1.96 * r["sem"]) * 100,
                "n": int(r["count"])} for _, r in g.iterrows()]

    # fig3 — hour-of-day profile
    h = df.groupby("hour_of_day").agg(mean_ctr=("ctr", "mean"), mean_impr=("impr", "mean"),
                                      clicks=("clicks", "sum"), impr=("impr", "sum")).reset_index()
    hourly = [{"hour": int(r["hour_of_day"]), "mean_ctr": r["mean_ctr"] * 100, "mean_impr": r["mean_impr"],
               "pooled_ctr": r["clicks"] / r["impr"] * 100 if r["impr"] else None} for _, r in h.iterrows()]

    # fig4 — marginal effect bands at the grand means (same construction as the script)
    ml, mlv = df["logit_ctr"].mean(), df["log_v"].mean()
    lv = np.linspace(df["log_v"].min(), df["log_v"].max(), 120)

    def band(m):
        b = m.params["log_v"]
        ci = m.conf_int().loc["log_v"].values
        p, lo, hi = (ca.inv_logit(ml + c * (lv - mlv)) * 100 for c in (b, ci[0], ci[1]))
        return {"p": p.round(5).tolist(), "lo": np.minimum(lo, hi).round(5).tolist(),
                "hi": np.maximum(lo, hi).round(5).tolist(), "beta": float(b)}
    glm_b, ols_b = band(reg["m1"]), band(reg["ols_m1"])
    ymax = min(30.0, float(np.nanmax(ols_b["hi"])) * 1.05)
    samp = df[["log_v", "ctr"]].dropna()
    if len(samp) > config.SCATTER_SAMPLE:
        samp = samp.sample(config.SCATTER_SAMPLE, random_state=0)
    marginal = {"lv": lv.round(5).tolist(), "glm": glm_b, "ols": ols_b, "ymax": ymax,
                "points": np.column_stack([samp["log_v"].values, samp["ctr"].values * 100]).round(4).tolist(),
                "n_points": int(len(df)), "n_shown": int(len(samp))}

    # fig6 — campaigns + total vs within slope
    b_w, b_t = float(reg["m1"].params["log_v"]), float(reg["m_total"].params["log_v"])
    x = camp["mean_logv"].values.astype(float)
    gm_logit, gm_x = float(camp["logit_ctr"].mean()), float(x.mean())
    xl = np.linspace(x.min(), x.max(), 100)
    between = {"b_within": b_w, "b_total": b_t,
               "total": np.column_stack([xl, ca.inv_logit(gm_logit + b_t * (xl - gm_x)) * 100]).round(5).tolist(),
               "within": np.column_stack([xl, ca.inv_logit(gm_logit + b_w * (xl - gm_x)) * 100]).round(5).tolist()}

    return {"box": {"cap": cap, "n_above": int((ctr_pct > cap).sum()), "buckets": box},
            "mean_ci": mean_ci, "hourly": hourly, "marginal": marginal, "between": between}
