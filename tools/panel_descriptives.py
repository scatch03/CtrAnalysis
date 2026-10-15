"""Descriptive completeness for the paper: panel totals, campaign durations, campaigns per volume bucket B1–B5
and fit statistics (pseudo-R², φ, QAIC) for every GLM in the model table — all on the script's cleaned panel.

    python3 tools/panel_descriptives.py --mapping M.csv --events E.csv [--out DIR]

1. Panel totals: Σ impressions, Σ clicks, pooled CTR = Σ clicks / Σ impressions, and the unweighted mean
   (and median) of the hourly CTRs for contrast.
2. Campaign duration: active hours per campaign (campaign-hours in the panel) and the calendar span from a
   campaign's first to its last active hour; min / P25 / median / P75 / max / mean (pandas linear quantiles).
3. Buckets B1–B5 (the script's thresholds): hours, campaigns with ≥ 1 hour in the bucket, Σ impressions,
   Σ clicks, pooled CTR, and concentration — the share of the bucket's hours (and impressions) contributed by
   its top-1 and top-3 campaigns, the Herfindahl index of campaign shares of hours and its inverse
   (the effective number of campaigns).
4. Fit statistics for M1 (9), M2 (10), MT (no campaign FE) and the Mundlak model (both variants, see
   mundlak.py): k, log-likelihood, deviance pseudo-R² = 1 − D/D₀ (the script's glm_fit_stats), the model's own
   Pearson φ = χ²/df, and QAIC = −2·llf/φ + 2k with φ shared from M2 (as the script does for M1/M2) and with
   the model's own φ.
"""
import argparse
import contextlib
import io
import os

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd

from mundlak import fit as fit_mundlak, mundlak_design
from wild_cluster_bootstrap import load_script


def panel_totals(df):
    impr, clicks = int(df["impr"].sum()), int(df["clicks"].sum())
    return {"campaign-hours": len(df), "campaigns": df["campaign"].nunique(), "impressions": impr, "clicks": clicks,
            "pooled CTR %": 100 * clicks / impr, "mean hourly CTR % (unweighted)": 100 * df["ctr"].mean(),
            "median hourly CTR %": 100 * df["ctr"].median(), "mean impressions / hour": df["impr"].mean(),
            "first hour": str(df["hour"].min()), "last hour": str(df["hour"].max())}


def durations(df):
    g = df.groupby("campaign")["hour"]
    span = (g.max() - g.min()) / pd.Timedelta(hours=1) + 1
    d = pd.DataFrame({"active hours": g.size(), "calendar span, h": span})
    d["active share of span"] = d["active hours"] / d["calendar span, h"]
    q = d.quantile([0, .25, .5, .75, 1]).set_axis(["min", "P25", "median", "P75", "max"])
    return pd.concat([q, d.mean().to_frame("mean").T]).T


def buckets(df):
    rows = []
    for b, d in df.groupby("bucket", observed=True):
        h = d["campaign"].value_counts(normalize=True)
        v = d.groupby("campaign")["impr"].sum().sort_values(ascending=False) / d["impr"].sum()
        hhi = float((h ** 2).sum())
        rows.append({"bucket": b, "hours": len(d), "campaigns": d["campaign"].nunique(),
                     "impressions": int(d["impr"].sum()), "share of all impressions %": 100 * d["impr"].sum() / df["impr"].sum(),
                     "clicks": int(d["clicks"].sum()), "pooled CTR %": 100 * d["clicks"].sum() / d["impr"].sum(),
                     "top-1 share of hours %": 100 * h.iloc[0], "top-3 share of hours %": 100 * h.head(3).sum(),
                     "HHI (hours)": hhi, "effective campaigns 1/HHI": 1 / hhi,
                     "top-3 share of impressions %": 100 * v.head(3).sum()})
    return pd.DataFrame(rows)


def fit_stats(name, m, phi_shared):
    k = len(m.params)
    phi_own = float(m.pearson_chi2 / m.df_resid)
    return {"model": name, "N": int(m.nobs), "k": k, "llf": float(m.llf), "deviance": float(m.deviance),
            "null deviance": float(m.null_deviance), "pseudo-R2 (deviance)": float(1 - m.deviance / m.null_deviance),
            "own phi (Pearson)": phi_own, "QAIC (phi shared from M2)": float(-2 * m.llf / phi_shared + 2 * k),
            "QAIC (own phi)": float(-2 * m.llf / phi_own + 2 * k)}


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mapping", required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--script", default=os.path.join(root, "ctr-monitor", "ctr_analysis.py"))
    ap.add_argument("--min-impr", type=int, default=10)
    ap.add_argument("--out", help="directory for the four tables as CSV")
    a = ap.parse_args()

    ca = load_script(a.script)
    ca.MIN_IMPRESSIONS = a.min_impr
    with contextlib.redirect_stdout(io.StringIO()):
        df, _, _ = ca.load_and_clean(a.mapping, a.events)
        reg = ca.run_regression(df)
    phi = reg["m2_stats"]["phi"]

    tot = pd.Series(panel_totals(df))
    dur = durations(df)
    bkt = buckets(df)
    models = [("M1 (9) within, campaign FE", reg["m1"]), ("M2 (10) quadratic, campaign FE", reg["m2"]),
              ("MT total, no campaign FE", reg["m_total"])]
    for variant, weighted in (("Mundlak, hour-weighted mean (main)", False), ("Mundlak, impr-weighted mean", True)):
        d, X, _, groups = mundlak_design(ca, df, weighted)
        models.append((variant, fit_mundlak(d, X, groups)))
    fits = pd.DataFrame([fit_stats(n, m, phi) for n, m in models])

    with pd.option_context("display.width", 250, "display.max_columns", 30, "display.float_format", "{:,.4f}".format):
        print("── 1. Panel totals ──", tot.to_string(), "", sep="\n")
        print("── 2. Campaign duration (hours) ──", dur.to_string(), "", sep="\n")
        print("── 3. Buckets B1–B5 ──", bkt.set_index("bucket").T.to_string(), "", sep="\n")
        print(f"── 4. Fit statistics (φ shared from M2 = {phi:.4f}) ──", fits.set_index("model").T.to_string(), sep="\n")
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        tot.to_frame("value").to_csv(os.path.join(a.out, "panel_totals.csv"))
        dur.to_csv(os.path.join(a.out, "campaign_duration.csv"))
        bkt.to_csv(os.path.join(a.out, "bucket_campaigns.csv"), index=False)
        fits.to_csv(os.path.join(a.out, "model_fit_stats.csv"), index=False)


if __name__ == "__main__":
    main()
