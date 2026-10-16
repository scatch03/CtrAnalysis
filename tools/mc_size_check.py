"""Monte Carlo size check: rejection rate under a true β₁ = 0 of the conventional cluster-robust Wald test vs the
WCR score bootstrap (wild_cluster_bootstrap.py), on the structure of one campaign-size quartile (default Q2).

    python3 tools/mc_size_check.py --mapping M.csv --events E.csv [--R 400] [--B 999] [--seed 1] [--quartile Q2]

Data-generating process (one synthetic dataset per replication):
  1. Campaigns, hours and impressions are the real ones of the chosen quartile (`assign_size_quartiles`):
     every campaign-hour keeps its actual V_it and time stamp; only the clicks are simulated.
  2. Systematic part η⁰_it: model (9) fitted to the real quartile data with β₁ = 0 imposed, i.e. the binomial
     GLM with campaign, hour-of-day and day-of-week FE but without ln V. So the true β₁ is exactly 0.
  3. Noise u_it, serially correlated within a campaign, one of
       --noise campaign-day (default): u_it = a_i,d + e_it, a campaign × calendar-day effect a_i,d ~ N(0, sd_day²)
                shared by all hours of campaign i on day d (hours of the same day share a shock, days are
                independent), plus an independent hour-level term e_it ~ N(0, sd_hour²);
       --noise ar1: u_it = w_it + e_it, w a stationary AR(1) over each campaign's hours with autocorrelation
                rho per hour and sd sd_ar (gaps of Δ hours use rho^Δ), plus e_it ~ N(0, sd_hour²).
  4. clicks_it ~ Binomial(impr_it, logit⁻¹(η⁰_it + u_it))  (a logit-normal binomial mixture: overdispersed).
  5. Each dataset is analysed with the script's fit_glm (model (9), cluster-robust Wald p) and with the WCR
     score bootstrap at β₁ = 0 (Rademacher and Webb, B draws each); a test rejects at p < 0.05.

The noise parameters are inputs (defaults: campaign-day, sd_day 0.35, sd_hour 0.15). --calibrate instead
grid-searches the AR(1) parameters (rho × sd_ar × sd_hour, 12 datasets per point, seed 7) for the closest match
to the real quartile's φ and residual autocorrelations, prints the best points and exits; on n2615 Q2 it picks
rho 0.995, sd_ar 0.12, sd_hour 0, i.e.  --noise ar1 --rho 0.995 --sd-ar 0.12 --sd-hour 0. To show how close the synthetic
data are to the real ones, --diag extra datasets (separate random stream, so the size results do not depend on
it) are compared with the real quartile on: Pearson φ of model (9), and the within-campaign autocorrelation of
its Pearson residuals at lags of 1 h, 2 h, 6 h and 24 h.
"""
import argparse
import contextlib
import io
import os
import time
import warnings

os.environ.setdefault("MPLBACKEND", "Agg")
warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import statsmodels.api as sm

from wild_cluster_bootstrap import WEBB, ScoreBootstrap, load_script

LAGS = (1, 2, 6, 24)


def ar1_noise(rng, camp, gap, rho, sd):
    """Stationary AR(1) per campaign over rows sorted by (campaign, hour); gap = hours since the previous row."""
    eps = rng.normal(0, 1, len(camp))
    w = np.empty(len(camp))
    for k in range(len(camp)):
        if k == 0 or camp[k] != camp[k - 1]:
            w[k] = sd * eps[k]
        else:
            r = rho ** gap[k]
            w[k] = r * w[k - 1] + sd * np.sqrt(1 - r * r) * eps[k]
    return w


def simulate(ca, base, eta0, day, rng, sd_day, sd_hour, ar=None):
    if ar is None:
        u = rng.normal(0, sd_day, day.max() + 1)[day] + rng.normal(0, sd_hour, len(base))
    else:                                           # ar = (order, camp, gap, rho, sd_ar) on the sorted rows
        order, camp, gap, rho, sd_ar = ar
        u = np.empty(len(base))
        u[order] = ar1_noise(rng, camp, gap, rho, sd_ar)
        u += rng.normal(0, sd_hour, len(base))
    p = 1 / (1 + np.exp(-(eta0 + u)))
    sim = base.copy()
    sim["clicks"] = rng.binomial(sim["impr"].astype(int).values, p)
    sim["ctr"] = sim["clicks"] / sim["impr"]; sim["logit_ctr"] = ca.logit(sim["ctr"])
    return sim


def fit_diagnostics(ca, d):
    """Pearson φ of model (9) and within-campaign autocorrelation of its Pearson residuals at LAGS hours."""
    m = ca.fit_glm(d)
    p = np.asarray(m.fittedvalues, dtype=float)
    r = (d["clicks"].values - d["impr"].values * p) / np.sqrt(d["impr"].values * p * (1 - p))
    s = pd.DataFrame({"campaign": d["campaign"].values, "hour": d["hour"].values, "r": r})
    out = {"phi": float(m.pearson_chi2 / m.df_resid)}
    for k in LAGS:
        nxt = s.assign(hour=s["hour"] - pd.Timedelta(hours=k))
        j = s.merge(nxt, on=["campaign", "hour"], suffixes=("", "_k"))
        out[f"acf{k}"] = float(np.corrcoef(j["r"], j["r_k"])[0, 1])
    return out


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mapping", required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--script", default=os.path.join(root, "ctr-monitor", "ctr_analysis.py"))
    ap.add_argument("--min-impr", type=int, default=10)
    ap.add_argument("--quartile", default="Q2")
    ap.add_argument("--R", type=int, default=400, help="synthetic datasets")
    ap.add_argument("--B", type=int, default=999, help="bootstrap draws per dataset")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--noise", choices=["campaign-day", "ar1"], default="campaign-day")
    ap.add_argument("--sd-day", type=float, default=0.35, help="campaign-day noise sd")
    ap.add_argument("--sd-hour", type=float, default=0.15, help="independent hour-level noise sd")
    ap.add_argument("--rho", type=float, default=0.98, help="AR(1) autocorrelation per hour (--noise ar1)")
    ap.add_argument("--sd-ar", type=float, default=0.1, help="AR(1) stationary sd (--noise ar1)")
    ap.add_argument("--diag", type=int, default=100, help="extra datasets for the calibration diagnostics (0 = skip)")
    ap.add_argument("--calibrate", action="store_true", help="grid-search the AR(1) noise parameters and exit")
    a = ap.parse_args()

    ca = load_script(a.script)
    ca.MIN_IMPRESSIONS = a.min_impr
    with contextlib.redirect_stdout(io.StringIO()):
        df, _, _ = ca.load_and_clean(a.mapping, a.events)
    df2, _ = ca.assign_size_quartiles(df)
    base = df2[df2["size_q"] == a.quartile].drop(columns="size_q").copy()

    # null DGP: the restricted fit (β₁ = 0) gives the systematic part; noise = campaign-day + hour-level
    sb0 = ScoreBootstrap(ca, base)
    m0 = sm.GLM(sb0.endog, sb0.Xr, family=sm.families.Binomial()).fit()
    eta0 = sb0.Xr.values @ m0.params.values
    day = pd.factorize(base["campaign"].astype(str) + base["hour"].dt.strftime("%Y%m%d"))[0]
    ar = None
    if a.noise == "ar1" or a.calibrate:
        order = np.lexsort((base["hour"].values, base["campaign"].astype(str).values))
        camp = base["campaign"].astype(str).values[order]
        hrs = base["hour"].values[order]
        gap = np.r_[0, (np.diff(hrs) / np.timedelta64(1, "h")).astype(float)]
        ar = (order, camp, gap, a.rho, a.sd_ar)
        noise = ("AR(1) within campaign — grid search" if a.calibrate
                 else f"AR(1) within campaign, rho {a.rho}/h, sd {a.sd_ar}; hour sd {a.sd_hour}")
    else:
        noise = f"campaign-day sd {a.sd_day}, hour sd {a.sd_hour}"
    print(f"{a.quartile} structure: G={sb0.G} campaigns, {len(base):,} campaign-hours, {day.max() + 1:,} campaign-days; "
          f"noise: {noise}")

    if a.calibrate:
        real = fit_diagnostics(ca, base)
        crng, rows = np.random.default_rng(7), []
        for rho in (0.95, 0.98, 0.99, 0.995):
            for sd_ar in (0.03, 0.05, 0.08, 0.12):
                for sd_h in (0.0, 0.05):
                    d = pd.DataFrame([fit_diagnostics(ca, simulate(ca, base, eta0, day, crng, 0, sd_h, (order, camp, gap, rho, sd_ar)))
                                      for _ in range(12)]).mean()
                    loss = (((d["phi"] - real["phi"]) / real["phi"]) ** 2
                            + sum((d[f"acf{k}"] - real[f"acf{k}"]) ** 2 / 0.03 ** 2 for k in LAGS) / len(LAGS))
                    rows.append({"rho": rho, "sd_ar": sd_ar, "sd_hour": sd_h, **d.to_dict(), "loss": loss})
        print("real:", "  ".join(f"{k} {v:.3f}" for k, v in real.items()))
        with pd.option_context("display.float_format", "{:.3f}".format):
            print(pd.DataFrame(rows).sort_values("loss").head(8).to_string(index=False))
        return

    if a.diag:
        real = fit_diagnostics(ca, base)
        drng = np.random.default_rng(a.seed + 10_000)
        sims = pd.DataFrame([fit_diagnostics(ca, simulate(ca, base, eta0, day, drng, a.sd_day, a.sd_hour, ar))
                             for _ in range(a.diag)])
        print(f"\ncalibration ({a.diag} synthetic datasets): real | synthetic mean [P5, P95]")
        for c in ["phi"] + [f"acf{k}" for k in LAGS]:
            name = "Pearson φ" if c == "phi" else f"residual ACF, lag {c[3:]} h"
            print(f"  {name:24} {real[c]:7.3f} | {sims[c].mean():7.3f} [{sims[c].quantile(.05):.3f}, {sims[c].quantile(.95):.3f}]")

    rng = np.random.default_rng(a.seed)
    rej = {"Wald cluster (conventional)": 0, "WCR score bootstrap, Rademacher": 0, "WCR score bootstrap, Webb": 0}
    t0 = time.time()
    for _ in range(a.R):
        sim = simulate(ca, base, eta0, day, rng, a.sd_day, a.sd_hour, ar)
        m = ca.fit_glm(sim)
        rej["Wald cluster (conventional)"] += m.pvalues["log_v"] < 0.05
        sb = ScoreBootstrap(ca, sim)
        V_r = rng.choice([-1.0, 1.0], size=(a.B, sb.G)); V_w = rng.choice(WEBB, size=(a.B, sb.G))
        S = sb.cluster_scores(0.0); t = S.sum() / np.sqrt((S ** 2).sum())
        for name, V in (("WCR score bootstrap, Rademacher", V_r), ("WCR score bootstrap, Webb", V_w)):
            VS = V * S; ts = VS.sum(1) / np.sqrt((VS ** 2).sum(1))
            rej[name] += np.mean(np.abs(ts) >= abs(t) - 1e-12) < 0.05
    se = np.sqrt(0.05 * 0.95 / a.R)
    print(f"\n{a.R} null datasets (true β₁ = 0), B = {a.B}, seed {a.seed}; {time.time() - t0:.0f}s")
    for k, v in rej.items():
        print(f"  {k:34} rejection rate at 5%: {v / a.R:.3f}   (MC 95% band for a correct test: "
              f"{0.05 - 1.96 * se:.3f}–{0.05 + 1.96 * se:.3f})")


if __name__ == "__main__":
    main()
