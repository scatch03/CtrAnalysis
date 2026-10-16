"""Naive-benchmark grid for the robustness table: OLS on a logit-transformed CTR with campaign + hour-of-day +
day-of-week FE, clustered by campaign — outcome {zeros clipped to 1e-6 (the script's logit_ctr), empirical
logit ln((clicks + 0.5)/(impr − clicks + 0.5))} × weights {none, impressions}.

    python3 tools/empirical_logit.py --mapping M.csv --events E.csv [--B 9999] [--seed 20261015] [--out results.csv]

Estimates and cluster-robust CIs/p come from the script's own fitters with only the outcome swapped:
fit_ols_logit (unweighted; campaign FE by within-transform, as the script's naive row) and fit_wls_logit
(weights = impressions; campaign dummies, as the script's WLS row), so the clipped cells reproduce table 7.

Bootstrap: the linear analogue of wild_cluster_bootstrap.py's restricted score bootstrap (Kline & Santos 2012).
Under H0: β₁ = b0 the model is refitted by (weighted) least squares with b0·ln V moved to the left-hand side;
the score of observation i is w_i·x̃_i·ũ_i, with x̃ = ln V residualised on the other regressors (weighted) and
ũ the restricted residual; T = ΣS_g / sqrt(ΣS_g²) over campaign sums S_g, T* with Rademacher or Webb weights
on S_g, symmetric p, and the 95 % CI by test inversion with the same draws (same seed as the other tools).
"""
import argparse
import contextlib
import io
import os

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd

from mundlak import bootstrap
from wild_cluster_bootstrap import ScoreBootstrap, load_script


class LinearScoreBootstrap(ScoreBootstrap):
    """Restricted score bootstrap for one coefficient of a (weighted) linear model with design X."""

    def __init__(self, X, y, weights, groups, param="log_v"):
        self.X = X.astype(float)
        self.cols = list(self.X.columns)
        self.j = self.cols.index(param)
        Xr = self.X.drop(columns=param).values
        x = self.X[param].values
        w = np.asarray(weights, dtype=float)
        sw = np.sqrt(w)
        resid = lambda v: v - Xr @ np.linalg.lstsq(Xr * sw[:, None], v * sw, rcond=None)[0]
        self.x_tilde = resid(x)                       # ln V residualised on the other regressors (weighted)
        self.u_y = resid(np.asarray(y, dtype=float))  # restricted residual at b0 = 0; at b0 it is u_y − b0·x̃
        self.w = w
        codes, self.clusters = pd.factorize(pd.Series(groups), sort=True)
        self.codes, self.G = codes, len(self.clusters)

    def cluster_scores(self, b0):
        s = self.w * self.x_tilde * (self.u_y - b0 * self.x_tilde)
        return np.bincount(self.codes, weights=s, minlength=self.G)


def empirical_logit(d):
    return np.log((d["clicks"] + 0.5) / (d["impr"] - d["clicks"] + 0.5))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mapping", required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--script", default=os.path.join(root, "ctr-monitor", "ctr_analysis.py"))
    ap.add_argument("--min-impr", type=int, default=10)
    ap.add_argument("--B", type=int, default=9999)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--out", help="write results as CSV")
    a = ap.parse_args()

    ca = load_script(a.script)
    ca.MIN_IMPRESSIONS = a.min_impr
    with contextlib.redirect_stdout(io.StringIO()):
        df, _, _ = ca.load_and_clean(a.mapping, a.events)

    rows = []
    for outcome, y_of in (("zeros clipped to 1e-6", lambda d: d["logit_ctr"]), ("empirical logit (+0.5)", empirical_logit)):
        dd = df.copy()
        dd["logit_ctr"] = y_of(dd)
        for weighting, fitter in (("unweighted OLS", ca.fit_ols_logit), ("WLS, weights = impressions", ca.fit_wls_logit)):
            m = fitter(dd)
            b, lo, hi, p = ca.coef_summary(m)
            se = float(m.bse["log_v"])
            d, X, groups = ca._design(dd)
            w = d["impr"].values if weighting.startswith("WLS") else np.ones(len(d))
            sb = LinearScoreBootstrap(X, d["logit_ctr"].values, w, groups)
            out = {}
            for wname, draw in (("Rademacher", lambda r: r.choice([-1.0, 1.0], size=(a.B, sb.G))),
                                ("Webb", lambda r: r.choice(np.array([-np.sqrt(1.5), -1.0, -np.sqrt(0.5), np.sqrt(0.5), 1.0, np.sqrt(1.5)]), size=(a.B, sb.G)))):
                V = draw(np.random.default_rng(a.seed))
                pb, _ = sb.pvalue(0.0, V)
                clo, chi = sb.ci(b, se, V)
                out.update({f"{wname} p": pb, f"{wname} 95% CI lo": clo, f"{wname} 95% CI hi": chi})
            rows.append({"outcome": outcome, "weights": weighting, "beta1": b, "cluster SE": se, "cluster 95% CI lo": lo,
                         "cluster 95% CI hi": hi, "cluster p": p, **out, "N": int(m.nobs), "G": sb.G,
                         "supports": ca.conclusion(b, p)})
            print(f"  {outcome:24} {weighting:27} β₁={b:+.4f}  CI[{lo:+.4f}, {hi:+.4f}]  cluster p={p:.4f}  |  "
                  f"Rademacher p={out['Rademacher p']:.4f} CI[{out['Rademacher 95% CI lo']:+.4f}, {out['Rademacher 95% CI hi']:+.4f}]  "
                  f"Webb p={out['Webb p']:.4f} CI[{out['Webb 95% CI lo']:+.4f}, {out['Webb 95% CI hi']:+.4f}]  → {ca.conclusion(b, p)}",
                  flush=True)
    if a.out:
        pd.DataFrame(rows).to_csv(a.out, index=False)


if __name__ == "__main__":
    main()
