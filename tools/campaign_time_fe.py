"""Campaign-specific time profiles: model (9) with the common hour-of-day FE replaced by campaign × hour-of-day
FE (and, as a lighter variant, with campaign × weekend FE added), with cluster-robust and WCR bootstrap inference.

    python3 tools/campaign_time_fe.py --mapping M.csv --events E.csv [--B 9999] [--seed 20261015] [--ci] [--out results.csv]

Specifications (binomial GLM, logit, SE clustered by campaign — statsmodels as in the script's fit_glm):
  A  campaign × hour-of-day FE + day-of-week FE   (the campaign and hour-of-day FE are nested in the cells)
  B  campaign FE + campaign × weekend FE + hour-of-day FE + day-of-week FE   (weekend = Saturday, Sunday)

Before fitting, the tool reports empty cells and cells with no click over the whole period (their FE would
diverge to −∞; such observations would be dropped). Collinear dummy columns are removed by pivoted QR, so k is
the number of identified parameters. φ is the model's own Pearson χ²/df.

Bootstrap: wild_cluster_bootstrap.ScoreBootstrap (restricted score bootstrap, Kline & Santos 2012) at β₁ = 0;
the restricted GLM is fitted from a cold start and must converge (its iteration count is printed). The score
vector is computed once and shared by the Rademacher and Webb draws. --ci adds the bootstrap 95 % CI by test
inversion (many restricted refits; slow for specification A).
"""
import argparse
import contextlib
import io
import os
import time

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd
import scipy.linalg
import statsmodels.api as sm

from wild_cluster_bootstrap import WEBB, ScoreBootstrap, load_script


def full_rank(X, keep="log_v"):
    """Drop columns that are linear combinations of earlier ones (pivoted QR); never drops `keep`."""
    cols = [keep] + [c for c in X.columns if c != keep]
    R = scipy.linalg.qr(X[cols].values, mode="r", pivoting=True)
    r, piv = R[0], R[1]
    rank = int((np.abs(np.diag(r)) > np.abs(r[0, 0]) * 1e-10).sum())
    kept = sorted(piv[:rank])
    assert 0 in kept, "ln V is collinear with the fixed effects"
    return X[[cols[i] for i in kept]]


def design(df, spec):
    d = df.copy()
    dow = pd.get_dummies(d["day_of_week"], prefix="dow", drop_first=True)
    if spec == "A":
        cell = d["campaign"].astype(str) + "×h" + d["hour_of_day"].astype(str)
        fe = [pd.get_dummies(cell, prefix="cell", drop_first=True), dow]
    else:
        camp = pd.get_dummies(d["campaign"].astype(str), prefix="camp", drop_first=True)
        wk = (d["day_of_week"] >= 5).astype(float)
        campwk = pd.get_dummies(d["campaign"].astype(str), prefix="campwk").mul(wk, axis=0)
        hod = pd.get_dummies(d["hour_of_day"], prefix="hod", drop_first=True)
        fe = [camp, campwk, hod, dow]
    X = pd.concat([pd.Series(1.0, index=d.index, name="const"), d["log_v"].rename("log_v")] + fe, axis=1).astype(float)
    return d, full_rank(X), d["campaign"].values


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mapping", required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--script", default=os.path.join(root, "ctr-monitor", "ctr_analysis.py"))
    ap.add_argument("--min-impr", type=int, default=10)
    ap.add_argument("--B", type=int, default=9999)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--specs", default="A,B")
    ap.add_argument("--ci", action="store_true", help="also the bootstrap 95 %% CI (slow for A)")
    ap.add_argument("--out", help="write results as CSV")
    a = ap.parse_args()

    ca = load_script(a.script)
    ca.MIN_IMPRESSIONS = a.min_impr
    with contextlib.redirect_stdout(io.StringIO()):
        df, _, _ = ca.load_and_clean(a.mapping, a.events)
    n_camp = df["campaign"].nunique()
    cells = df.groupby(["campaign", "hour_of_day"])["clicks"].agg(["size", "sum"])
    wk = df.assign(wk=df["day_of_week"] >= 5).groupby(["campaign", "wk"])["clicks"].agg(["size", "sum"])
    print(f"campaign × hour-of-day: {len(cells)} of {n_camp * 24} cells observed ({n_camp * 24 - len(cells)} empty), "
          f"{int((cells['sum'] == 0).sum())} with no click, {int((cells['size'] == 1).sum())} with a single observation")
    print(f"campaign × weekend: {len(wk)} of {n_camp * 2} cells observed, {int((wk['sum'] == 0).sum())} with no click")

    rows = []
    for spec in a.specs.split(","):
        t0 = time.time()
        d, X, groups = design(df, spec)
        y = np.column_stack([d["clicks"].values, (d["impr"] - d["clicks"]).values]).astype(float)
        m = sm.GLM(y, X, family=sm.families.Binomial()).fit(cov_type="cluster", cov_kwds={"groups": groups})
        b, se, p = float(m.params["log_v"]), float(m.bse["log_v"]), float(m.pvalues["log_v"])
        lo, hi = (float(v) for v in m.conf_int().loc["log_v"])
        phi = float(m.pearson_chi2 / m.df_resid)
        it = int(m.fit_history["iteration"]) if hasattr(m, "fit_history") else -1
        print(f"\n{spec}: N={int(m.nobs):,}  G={len(np.unique(groups))}  k={X.shape[1]}  φ={phi:.3f}  converged={m.converged} "
              f"({it} iterations)  pseudo-R²={1 - m.deviance / m.null_deviance:.4f}  [{time.time() - t0:.0f}s]")
        sb = ScoreBootstrap(X=X, clicks=d["clicks"].values, impr=d["impr"].values, groups=groups, param="log_v")
        t1 = time.time()
        S = sb.cluster_scores(0.0)                        # restricted fit at β₁ = 0 (raises if it does not converge)
        restricted = sm.GLM(sb.endog, sb.Xr, family=sm.families.Binomial()).fit(maxiter=300)
        T = sb.stat(S)
        row = {"spec": spec, "beta1": b, "cluster SE": se, "cluster 95% CI lo": lo, "cluster 95% CI hi": hi, "cluster p": p,
               "N": int(m.nobs), "G": sb.G, "k": X.shape[1], "phi": phi, "converged": bool(m.converged),
               "restricted converged": bool(restricted.converged),
               "restricted iterations": int(restricted.fit_history["iteration"])}
        for wname, choices in (("Rademacher", np.array([-1.0, 1.0])), ("Webb", WEBB)):
            V = np.random.default_rng(a.seed).choice(choices, size=(a.B, sb.G))
            VS = V * S
            row[f"{wname} p"] = float(np.mean(np.abs(VS.sum(1) / np.sqrt((VS ** 2).sum(1))) >= abs(T) - 1e-12))
            if a.ci:
                row[f"{wname} 95% CI lo"], row[f"{wname} 95% CI hi"] = sb.ci(b, se, V)
        print(f"  β₁={b:+.4f}  CI[{lo:+.4f}, {hi:+.4f}]  cluster p={p:.4f}  |  restricted fit converged="
              f"{row['restricted converged']} ({row['restricted iterations']} iterations)  |  "
              f"Rademacher p={row['Rademacher p']:.4f}  Webb p={row['Webb p']:.4f}"
              + (f"  CI R[{row['Rademacher 95% CI lo']:+.4f}, {row['Rademacher 95% CI hi']:+.4f}] "
                 f"W[{row['Webb 95% CI lo']:+.4f}, {row['Webb 95% CI hi']:+.4f}]" if a.ci else "")
              + f"  [{time.time() - t1:.0f}s]", flush=True)
        rows.append(row)
    if a.out:
        pd.DataFrame(rows).to_csv(a.out, index=False)


if __name__ == "__main__":
    main()
