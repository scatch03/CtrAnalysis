"""Wild cluster score bootstrap (restricted / WCR) for β₁ on ln(V) in ctr_analysis.py's binomial GLM.

    python3 tools/wild_cluster_bootstrap.py --mapping M.csv --events E.csv [--B 9999] [--seed 20261015]
                                            [--script ctr-monitor/ctr_analysis.py] [--out results.csv]

Model: the script's primary GLM (9) — binomial, logit link, campaign + hour-of-day + day-of-week fixed
effects, clusters = campaigns — built with the script's own `_design`. Subsamples are taken exactly as in
the script's robustness tables: campaign-size quartiles (`assign_size_quartiles`, table 9) and the two
halves of the period split at the median hour (`robustness_temporal`, table 12), plus the full sample.

Procedure — the score bootstrap of Kline & Santos (2012), the WCR analogue for ML estimators
(Roodman, MacKinnon, Nielsen & Webb 2019, sec. 3.3):
  1. Impose H0: β₁ = b0 — refit the GLM with b0·ln V as an offset, all other parameters free.
  2. At that restricted fit, form each observation's score for β₁ with the nuisance parameters
     partialled out: s_i = x̃_i (clicks_i − impr_i·p̃_i), where x̃ is ln V residualised on the other
     regressors with weights impr·p̃(1−p̃) (the efficient score), and sum it within each campaign: S_g.
  3. Statistic T = Σ_g S_g / sqrt(Σ_g S_g²)  (cluster-robust score / LM statistic).
  4. Bootstrap: T*_b = Σ_g v_gb S_g / sqrt(Σ_g (v_gb S_g)²) with cluster weights v_gb
     (Rademacher ±1, or Webb's six-point distribution), b = 1..B.
  5. Symmetric two-sided p = share of |T*_b| ≥ |T|.
  6. 95 % CI = {b0 : p(b0) > 0.05}, found by bisection with the same weight draws for every b0.

The G/(G−1) small-sample factor cancels between T and T*, so the bootstrap p does not depend on it.
β₁ and the conventional cluster-robust p are the script's own `fit_glm` results (statsmodels).
"""
import argparse
import contextlib
import importlib.util
import io
import os
import time

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd
import statsmodels.api as sm

WEBB = np.array([-np.sqrt(1.5), -1.0, -np.sqrt(0.5), np.sqrt(0.5), 1.0, np.sqrt(1.5)])


def load_script(path):
    spec = importlib.util.spec_from_file_location("ctr_analysis", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ScoreBootstrap:
    """Restricted score bootstrap for the coefficient on `log_v` in one subsample."""

    def __init__(self, ca, sub):
        d, X, groups = ca._design(sub)
        self.X = X.astype(float)
        self.cols = list(self.X.columns)
        self.j = self.cols.index("log_v")
        self.others = [i for i in range(len(self.cols)) if i != self.j]
        self.Xv = self.X.values
        self.Xr = self.X.drop(columns="log_v")
        self.lv = d["log_v"].values.astype(float)
        self.y = d["clicks"].values.astype(float)
        self.n = d["impr"].values.astype(float)
        self.endog = np.column_stack([self.y, self.n - self.y])
        codes, self.clusters = pd.factorize(pd.Series(groups), sort=True)
        self.codes, self.G = codes, len(self.clusters)

    def cluster_scores(self, b0):
        """Efficient-score contributions S_g for β₁ at the fit restricted to β₁ = b0."""
        m = sm.GLM(self.endog, self.Xr, family=sm.families.Binomial(), offset=b0 * self.lv)
        res = m.fit(maxiter=300)                  # cold start every time: warm starts can stall in rank-deficient designs
        if not res.converged:
            raise RuntimeError(f"restricted GLM did not converge at b0={b0}")
        eta = self.Xr.values @ res.params.values + b0 * self.lv
        p = 1.0 / (1.0 + np.exp(-eta))
        w = self.n * p * (1.0 - p)
        H = self.Xv.T @ (self.Xv * w[:, None])
        o, j = self.others, self.j
        # least squares, not solve: a subsample's dummy set can be rank-deficient (statsmodels uses pinv
        # there too); x̃ — the weighted residual of ln V on the other regressors — is unique either way
        coef = np.linalg.lstsq(H[np.ix_(o, o)], H[o, j], rcond=None)[0]
        x_tilde = self.Xv[:, j] - self.Xv[:, o] @ coef
        s = x_tilde * (self.y - self.n * p)
        return np.bincount(self.codes, weights=s, minlength=self.G)

    @staticmethod
    def stat(S):
        return S.sum() / np.sqrt((S ** 2).sum())

    def pvalue(self, b0, V):
        S = self.cluster_scores(b0)
        t = self.stat(S)
        VS = V * S                                  # B × G perturbed cluster scores
        t_star = VS.sum(1) / np.sqrt((VS ** 2).sum(1))
        return float(np.mean(np.abs(t_star) >= np.abs(t) - 1e-12)), float(t)

    def ci(self, b_hat, se, V, level=0.95, tol=1e-5):
        alpha = 1 - level

        def bound(direction):
            inside, step = b_hat, max(se, 1e-3)
            outside = b_hat + direction * step
            for _ in range(40):                       # expand until p(b0) ≤ alpha
                if self.pvalue(outside, V)[0] <= alpha:
                    break
                inside, step = outside, step * 2
                outside = b_hat + direction * step
            else:
                return np.inf * direction             # never rejected → unbounded
            while abs(outside - inside) > tol:        # bisection on the accept/reject boundary
                mid = 0.5 * (inside + outside)
                if self.pvalue(mid, V)[0] > alpha:
                    inside = mid
                else:
                    outside = mid
            return 0.5 * (inside + outside)

        return bound(-1), bound(+1)


def subsamples(ca, df):
    out = [("Full sample", df)]
    df2, labels = ca.assign_size_quartiles(df)
    for q in labels:
        sub = df2[df2["size_q"] == q]
        if len(sub) >= 30:
            out.append((q, sub.drop(columns="size_q")))
    mid = df["hour"].median()
    out += [("First half", df[df["hour"] <= mid]), ("Second half", df[df["hour"] > mid])]
    return out


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
    for name, sub in subsamples(ca, df):
        t0 = time.time()
        m = ca.fit_glm(sub)
        b, lo, hi, p_cl = ca.coef_summary(m)
        se = float(m.bse["log_v"])
        sb = ScoreBootstrap(ca, sub)
        _, t_score = sb.pvalue(0.0, np.ones((1, sb.G)))
        G = sb.G
        from scipy.stats import norm
        p_score_asy = float(2 * norm.sf(abs(t_score) * np.sqrt(G / (G - 1))))
        row = {"Subsample": name, "G (clusters)": G, "N obs": len(sub), "beta1": b, "cluster SE": se,
               "cluster 95% CI lo": lo, "cluster 95% CI hi": hi, "cluster p": p_cl,
               "score test p (asymptotic)": p_score_asy}
        for wname, draw in (("Rademacher", lambda r: r.choice([-1.0, 1.0], size=(a.B, G))),
                            ("Webb", lambda r: r.choice(WEBB, size=(a.B, G)))):
            V = draw(np.random.default_rng(a.seed))
            p_boot, _ = sb.pvalue(0.0, V)
            ci_lo, ci_hi = sb.ci(b, se, V)
            row.update({f"{wname} p": p_boot, f"{wname} 95% CI lo": ci_lo, f"{wname} 95% CI hi": ci_hi})
        rows.append(row)
        print(f"  {name:16} G={G:2}  β₁={b:+.4f}  cluster p={p_cl:.4f}  "
              f"Rademacher p={row['Rademacher p']:.4f} CI[{row['Rademacher 95% CI lo']:+.4f}, {row['Rademacher 95% CI hi']:+.4f}]  "
              f"Webb p={row['Webb p']:.4f} CI[{row['Webb 95% CI lo']:+.4f}, {row['Webb 95% CI hi']:+.4f}]  "
              f"({time.time() - t0:.0f}s)", flush=True)

    out = pd.DataFrame(rows)
    if a.out:
        out.to_csv(a.out, index=False)
    return out


if __name__ == "__main__":
    main()
