"""Fatigue as accumulated exposure: model (9) of ctr_analysis.py with the campaign's cumulative impressions
before hour t added next to ln V, with cluster-robust and wild cluster bootstrap inference.

    python3 tools/cumulative_exposure.py --mapping M.csv --events E.csv [--B 9999] [--seed 20261015] [--out results.csv]

    logit(p_it) = β0 + β1·ln V_it + β_C·ln(1 + C_i,t−1) + hour-of-day, day-of-week and campaign FE

C_i,t−1 = Σ impressions of campaign i over its hours before t inside the observation window (hour t itself
excluded). It is cumulated over every valid hour of the campaign, including the hours with fewer than
--min-impr impressions that the regression panel drops (the script's df_pre).

Specifications (clusters = campaigns throughout; each extra term also gets the WCR score bootstrap):
  C      (9) + ln(1+C)                                  — the requested specification
  age    (9) + campaign age in days since its first active hour in the window
         (with campaign FE this is the same as a linear calendar-time trend)
  C+date (9) + ln(1+C) with calendar-date FE in place of day-of-week FE, so the exposure term is identified
         net of common day-to-day shocks (age is not identified there)
  C new / age new: the C and age specifications on the campaigns whose first active hour is after the window
         starts — the only ones whose cumulative exposure is not left-censored
  C+date new, C new start ≥ 24 h (drops campaigns starting within the window's first day), C new after day 1
         (drops each new campaign's first 24 hours): checks of the C new result, plus a leave-one-campaign-out

Also printed: within-campaign correlations of ln V, ln(1+C) and age (campaign-demeaned), and QAIC with φ
shared from the script's quadratic model M2, next to M1's.
"""
import argparse
import contextlib
import io
import os

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd

from mundlak import bootstrap, fit
from wild_cluster_bootstrap import load_script

SPECS = (("C", ["log1p_C"], False, "all"), ("age", ["age_days"], False, "all"), ("C+date", ["log1p_C"], True, "all"),
         ("C new", ["log1p_C"], False, "new"), ("age new", ["age_days"], False, "new"),
         ("C+date new", ["log1p_C"], True, "new"), ("C new, start ≥ 24 h", ["log1p_C"], False, "new24"),
         ("C new, after day 1", ["log1p_C"], False, "new_after_day1"))
SUBSETS = {"all": lambda d: d, "new": lambda d: d[d["start_h"] > 0], "new24": lambda d: d[d["start_h"] >= 24],
           "new_after_day1": lambda d: d[(d["start_h"] > 0) & (d["age_days"] >= 1)]}
LABELS = {"log_v": "β₁ (ln V)", "log1p_C": "β_C (ln(1+C))", "age_days": "β_age (per day)"}


def add_exposure(df, df_pre):
    pre = df_pre.sort_values(["campaign", "hour"])[["campaign", "hour", "impr"]].copy()
    pre["C_prev"] = pre.groupby("campaign")["impr"].cumsum() - pre["impr"]
    pre["first_hour"] = pre.groupby("campaign")["hour"].transform("min")
    out = df.merge(pre[["campaign", "hour", "C_prev", "first_hour"]], on=["campaign", "hour"], how="left", validate="1:1")
    assert out["C_prev"].notna().all()
    out["log1p_C"] = np.log1p(out["C_prev"])
    out["age_days"] = (out["hour"] - out["first_hour"]) / pd.Timedelta(days=1)
    out["start_h"] = (out["first_hour"] - df_pre["hour"].min()) / pd.Timedelta(hours=1)   # > 0: not left-censored
    return out


def design(ca, df, extras, date_fe):
    d, X, groups = ca._design(df)                                   # const, log_v, hour/day-of-week, campaign
    X = X.copy()
    if date_fe:
        X = X.drop(columns=[c for c in X.columns if c.startswith("day_of_week_")])
        X = pd.concat([X, pd.get_dummies(d["hour"].dt.strftime("%Y-%m-%d"), prefix="date", drop_first=True).astype(float)], axis=1)
    for j, c in enumerate(extras):
        X.insert(2 + j, c, d[c].astype(float).values)
    return d, X, groups


def within_corr(df, cols):
    dev = df[cols] - df.groupby("campaign")[cols].transform("mean")
    return dev.corr()


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mapping", required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--script", default=os.path.join(root, "ctr-monitor", "ctr_analysis.py"))
    ap.add_argument("--min-impr", type=int, default=10)
    ap.add_argument("--B", type=int, default=9999)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--out", help="write the coefficient table as CSV")
    a = ap.parse_args()

    ca = load_script(a.script)
    ca.MIN_IMPRESSIONS = a.min_impr
    with contextlib.redirect_stdout(io.StringIO()):
        df, df_pre, _ = ca.load_and_clean(a.mapping, a.events)
        reg = ca.run_regression(df)
    phi = reg["m2_stats"]["phi"]
    qaic = lambda m: -2 * m.llf / phi + 2 * len(m.params)
    df = add_exposure(df, df_pre)
    new = SUBSETS["new"](df)
    print(f"campaigns: {df['campaign'].nunique()}, of which {new['campaign'].nunique()} start after the window opens "
          f"({len(new):,} campaign-hours); the rest are active in its first hour (exposure before it unknown)")
    print(f"reference  M1 (9): β₁={reg['m1'].params['log_v']:+.4f}  k={len(reg['m1'].params)}  QAIC={qaic(reg['m1']):.1f}  "
          f"(φ shared from M2 = {phi:.4f})")
    with pd.option_context("display.float_format", "{:+.3f}".format):
        print("\nwithin-campaign correlations, all campaigns:", within_corr(df, ["log_v", "log1p_C", "age_days"]).to_string(), sep="\n")
        print("within-campaign correlations, campaigns starting inside the window:",
              within_corr(new, ["log_v", "log1p_C", "age_days"]).to_string(), "", sep="\n")

    rows = []
    for spec, extras, date_fe, subset in SPECS:
        sub, only_new = SUBSETS[subset](df), subset != "all"
        d, X, groups = design(ca, sub, extras, date_fe)
        m = fit(d, X, groups)
        own_phi = float(m.pearson_chi2 / m.df_resid)
        head = (f"{spec}: N={int(m.nobs):,}  G={len(np.unique(groups))}  k={len(m.params)}  own φ={own_phi:.3f}  "
                f"pseudo-R²={1 - m.deviance / m.null_deviance:.4f}")
        print(head + ("" if only_new else f"  QAIC={qaic(m):.1f}  ΔQAIC vs M1={qaic(m) - qaic(reg['m1']):+.1f}"))
        for param in ["log_v"] + extras:
            b, se, p = float(m.params[param]), float(m.bse[param]), float(m.pvalues[param])
            lo, hi = (float(v) for v in m.conf_int().loc[param])
            boot, G = bootstrap(d, X, groups, param, b, se, a.B, a.seed)
            rows.append({"spec": spec, "term": LABELS[param], "estimate": b, "cluster SE": se, "cluster 95% CI lo": lo,
                         "cluster 95% CI hi": hi, "cluster p": p, **boot, "N": int(m.nobs), "G": G, "k": len(m.params),
                         "QAIC (phi shared)": np.nan if only_new else qaic(m), "own phi": own_phi,
                         "pseudo-R2": float(1 - m.deviance / m.null_deviance)})
            print(f"  {LABELS[param]:17} {b:+.6f}  CI[{lo:+.6f}, {hi:+.6f}]  cluster p={p:.4f}  |  "
                  f"Rademacher p={boot['Rademacher p']:.4f} CI[{boot['Rademacher 95% CI lo']:+.6f}, {boot['Rademacher 95% CI hi']:+.6f}]  "
                  f"Webb p={boot['Webb p']:.4f} CI[{boot['Webb 95% CI lo']:+.6f}, {boot['Webb 95% CI hi']:+.6f}]", flush=True)
    # leave-one-campaign-out on the campaigns starting inside the window (cluster-robust only)
    loo = []
    for c in new["campaign"].unique():
        d, X, groups = design(ca, new[new["campaign"] != c], ["log1p_C"], False)
        m = fit(d, X, groups)
        loo.append((float(m.params["log1p_C"]), float(m.pvalues["log1p_C"])))
    loo = np.array(loo)
    print(f"\nC new, leave one campaign out ({len(loo)} fits): β_C from {loo[:, 0].min():+.6f} to {loo[:, 0].max():+.6f}, "
          f"cluster p ≤ {loo[:, 1].max():.4f}")
    if a.out:
        pd.DataFrame(rows).to_csv(a.out, index=False)


if __name__ == "__main__":
    main()
