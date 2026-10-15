"""Mundlak (correlated random effects) version of ctr_analysis.py's binomial GLM — a direct test of the
between-campaign (composition) component.

    python3 tools/mundlak.py --mapping M.csv --events E.csv [--B 9999] [--seed 20261015] [--out results.csv]

    logit(p_it) = β0 + β_W·ln V_it + β_B·mean_i(ln V) + hour-of-day FE + day-of-week FE

i.e. model (9) without campaign fixed effects plus the campaign mean of ln V over all of that campaign's
hours in the analysis panel; standard errors clustered by campaign (statsmodels, exactly as the script's
fit_glm). β_W is the within-campaign slope, β_B the between-minus-within (composition) component, and
β_W + β_B the between-campaign slope. The sum is also estimated directly by the equivalent
reparametrisation  β_W·(ln V − mean) + (β_W + β_B)·mean.

Reported per term: estimate, cluster-robust 95 % CI and p, and the restricted wild cluster score bootstrap
p and 95 % CI (Rademacher and Webb; see wild_cluster_bootstrap.py). QAIC = −2·llf/φ + 2k with φ shared
from the script's quadratic model M2, as in its results summary, so it can sit next to M1's QAIC.

Variant "impr-weighted mean": the campaign mean of ln V weighted by impressions instead of by hours.
"""
import argparse
import contextlib
import io
import os

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd
import statsmodels.api as sm

from wild_cluster_bootstrap import WEBB, ScoreBootstrap, load_script


def mundlak_design(ca, df, weighted=False):
    df = df.copy()
    if weighted:
        w = df["impr"]
        df["mean_logv"] = (df["log_v"] * w).groupby(df["campaign"]).transform("sum") / w.groupby(df["campaign"]).transform("sum")
    else:
        df["mean_logv"] = df.groupby("campaign")["log_v"].transform("mean")
    d, X, groups = ca._design(df, campaign_fe=False)          # const, log_v, hour/day dummies
    X = X.copy()
    X.insert(2, "mean_logv", d["mean_logv"].astype(float).values)
    Xs = X.copy()                                             # reparametrised: within deviation + mean
    Xs["log_v"] = X["log_v"] - X["mean_logv"]
    Xs = Xs.rename(columns={"log_v": "dev_logv", "mean_logv": "between"})
    return d, X, Xs, groups


def fit(d, X, groups):
    y = np.column_stack([d["clicks"].values, (d["impr"] - d["clicks"]).values]).astype(float)
    return sm.GLM(y, X.astype(float), family=sm.families.Binomial()).fit(cov_type="cluster", cov_kwds={"groups": groups})


def bootstrap(d, X, groups, param, b_hat, se, B, seed):
    sb = ScoreBootstrap(X=X, clicks=d["clicks"].values, impr=d["impr"].values, groups=groups, param=param)
    out = {}
    for wname, draw in (("Rademacher", lambda r: r.choice([-1.0, 1.0], size=(B, sb.G))),
                        ("Webb", lambda r: r.choice(WEBB, size=(B, sb.G)))):
        V = draw(np.random.default_rng(seed))
        p, _ = sb.pvalue(0.0, V)
        lo, hi = sb.ci(b_hat, se, V)
        out.update({f"{wname} p": p, f"{wname} 95% CI lo": lo, f"{wname} 95% CI hi": hi})
    return out, sb.G


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
        df, _, _ = ca.load_and_clean(a.mapping, a.events)
        reg = ca.run_regression(df)                          # M1 (FE), M2 (quadratic, for shared φ), MT (total)
    phi = reg["m2_stats"]["phi"]
    qaic = lambda m: -2 * m.llf / phi + 2 * len(m.params)
    b1, _, _, p1 = ca.coef_summary(reg["m1"])
    bt, _, _, pt = ca.coef_summary(reg["m_total"])
    print(f"reference  M1 (campaign FE) β₁={b1:+.4f} p={p1:.4f}  k={len(reg['m1'].params)}  QAIC={qaic(reg['m1']):.1f}")
    print(f"reference  MT (no campaign FE) β_total={bt:+.4f} p={pt:.4f}  k={len(reg['m_total'].params)}  QAIC={qaic(reg['m_total']):.1f}"
          f"   (φ shared from M2 = {phi:.3f})")

    rows = []
    for variant, weighted in (("hour-weighted mean (main)", False), ("impr-weighted mean", True)):
        d, X, Xs, groups = mundlak_design(ca, df, weighted)
        m, ms = fit(d, X, groups), fit(d, Xs, groups)
        own_phi = float(m.pearson_chi2 / m.df_resid)
        print(f"\nMundlak — {variant}: N={int(m.nobs):,}  G={len(np.unique(groups))}  k={len(m.params)}  "
              f"QAIC={qaic(m):.1f} (φ shared {phi:.3f}; own φ {own_phi:.3f} → QAIC {-2 * m.llf / own_phi + 2 * len(m.params):.1f})"
              f"  llf={m.llf:.1f}  pseudo-R²={1 - m.deviance / m.null_deviance:.4f}")
        terms = (("β_W (within, ln V)", d, X, "log_v", m),
                 ("β_B (mean ln V: composition)", d, X, "mean_logv", m),
                 ("β_W + β_B (between slope)", d, Xs, "between", ms))
        for label, dd, XX, param, mm in terms:
            b, se, p = float(mm.params[param]), float(mm.bse[param]), float(mm.pvalues[param])
            lo, hi = (float(v) for v in mm.conf_int().loc[param])
            boot, G = bootstrap(dd, XX, groups, param, b, se, a.B, a.seed)
            row = {"variant": variant, "term": label, "estimate": b, "cluster SE": se, "cluster 95% CI lo": lo,
                   "cluster 95% CI hi": hi, "cluster p": p, **boot, "N": int(m.nobs), "G": G, "k": len(m.params),
                   "QAIC (shared phi)": qaic(m), "phi shared": phi, "own phi": own_phi}
            rows.append(row)
            print(f"  {label:30} {b:+.4f}  CI[{lo:+.4f}, {hi:+.4f}]  cluster p={p:.4f}  |  "
                  f"Rademacher p={boot['Rademacher p']:.4f} CI[{boot['Rademacher 95% CI lo']:+.4f}, {boot['Rademacher 95% CI hi']:+.4f}]  "
                  f"Webb p={boot['Webb p']:.4f} CI[{boot['Webb 95% CI lo']:+.4f}, {boot['Webb 95% CI hi']:+.4f}]", flush=True)
        # the two parametrisations must agree on the sum
        cov = m.cov_params()
        s_hat = m.params["log_v"] + m.params["mean_logv"]
        s_se = float(np.sqrt(cov.loc["log_v", "log_v"] + cov.loc["mean_logv", "mean_logv"] + 2 * cov.loc["log_v", "mean_logv"]))
        print(f"  check: β_W+β_B from the original parametrisation = {s_hat:+.4f} (SE {s_se:.4f}) "
              f"vs reparametrised {ms.params['between']:+.4f} (SE {ms.bse['between']:.4f})")
    if a.out:
        pd.DataFrame(rows).to_csv(a.out, index=False)


if __name__ == "__main__":
    main()
