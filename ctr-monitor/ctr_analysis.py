"""
ctr_analysis.py  (v4.2 — binomial GLM primary; QAIC; total-vs-within decomposition)
───────────────────────────────────────────────────────────────────────────────
Full analysis pipeline: CTR vs. Impression Volume (Observational Panel Study)

Hypothesis labelling aligned to paper §3.3:
  H1 — Fatigue (exponential decay):        CTR = a·exp(−b·V) + g,  a>0
  H2 — Novelty-then-Fatigue (inverted-U):  CTR = a·V^b·exp(−g·V), a,b,g>0
  H3 — Diminishing-Returns Growth (sat. exponential):
                                            CTR = g − a·exp(−b·V), a>0
  H4 — Null (constant):                    CTR = μ

PRIMARY SPECIFICATION — binomial GLM, logit link:
      clicks_it ~ Binomial(impr_it, p_it),  logit(p_it) = β₀ + β₁ ln V_it + h_t + d_t + α_i
  explicit campaign dummies α_i, hour/day dummies, SEs clustered by campaign.
  OLS on logit(CTR) is kept as the NAIVE comparison (spurious positive β₁ from
  zero-click hours) — reported side by side in every robustness block.

v4.1 additions:
  • Overdispersion φ = Pearson χ²/df and QAIC = −2·llf/φ + 2k for GLM model
    comparison (raw binomial AIC is not usable under overdispersion).
  • "Total" GLM slope (time FE, NO campaign FE) — the pooled association
    across all hours. Decomposition: β_total − β_within = composition effect,
    in the same logit-per-ln(V) units. This replaces the campaign-totals GLM
    as the primary between-vs-within evidence (that GLM is dominated by a few
    giant campaigns; Spearman ρ across campaigns is still reported).
  • fig6 now overlays the total and within slopes on the campaign scatter.

v4.2 (figures only; estimates unchanged):
  • fig2: y axis starts at zero.
  • fig4: GLM and OLS curves drawn only over the typical within-campaign range of ln(V)
    (mean ln V + P5…P95 of the deviation from the campaign mean), shaded; y axis capped
    at the 99th percentile of hourly CTR.
  • fig6: within-campaign slope drawn as a short segment over that same range at the centre
    of the campaign cloud, not as a line across it. The range is stored in
    table12b_between_campaign_fit.csv (within_dev_p05 / within_dev_p95).
  • fig7: right axis extended so the zero-click bars are never clipped.

Usage:
    python ctr_analysis.py --mapping M.csv --events E.csv [--out ./results] [--dpi 300] [--min-impr 10]
"""

import argparse
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats
from scipy.optimize import curve_fit
import statsmodels.api as sm
import matplotlib
import matplotlib.pyplot as plt
from matplotlib.ticker import Formatter

warnings.filterwarnings("ignore")

THEME = {
    "font.family": "DejaVu Sans", "font.size": 10, "axes.labelsize": 10, "axes.titlesize": 10,
    "axes.facecolor": "white", "axes.edgecolor": "black", "axes.linewidth": 0.8, "axes.grid": True,
    "axes.spines.top": True, "axes.spines.right": True, "axes.spines.left": True, "axes.spines.bottom": True,
    "grid.color": "#d9d9d9", "grid.linewidth": 0.5, "grid.linestyle": "-",
    "xtick.bottom": True, "ytick.left": True, "xtick.direction": "out", "ytick.direction": "out",
    "xtick.labelsize": 9, "ytick.labelsize": 9,
    "legend.frameon": True, "legend.framealpha": 1.0, "legend.edgecolor": "black", "legend.fancybox": False,
    "legend.fontsize": 9, "figure.facecolor": "white", "savefig.facecolor": "white",
    "figure.dpi": 150, "lines.linewidth": 1.5,
}
matplotlib.rcParams.update(THEME)

COL_MAPPING = dict(banner="banner_id", campaign="campaign_id")
COL_EVENTS  = dict(date="date", hour="hour", banner="banner_id", impr="impressions", clicks="clicks")

BUCKET_THRESHOLDS   = [0, 500, 2_000, 10_000, 50_000, np.inf]
BUCKET_LABELS_CLEAN = ["B1", "B2", "B3", "B4", "B5"]
BUCKET_LABELS_UK    = ["B₁", "B₂", "B₃", "B₄", "B₅"]

# Black-and-white palette (journal requirement): series are distinguished by
# line style, marker shape and marker fill — never by colour alone.
CLR_MAIN = "black"; CLR_ALT = "#4d4d4d"
CLR_H1 = "black"; CLR_H2 = "#4d4d4d"; CLR_H3 = "#808080"; CLR_H4 = "#808080"
CLR_TOTAL = "black"
import cycler as _cycler
matplotlib.rcParams["axes.prop_cycle"] = _cycler.cycler(color=["black"])
matplotlib.rcParams["hatch.linewidth"] = 0.5

CTR_OUTLIER_THRESHOLD = 0.20
MIN_IMPRESSIONS       = 10
THRESHOLD_GRID        = (10, 50, 100, 200)

H1_LABEL = "H1 — Exponential decay (Fatigue)"
H2_LABEL = "H2 — Inverted-U (Novelty→Fatigue)"
H3_LABEL = "H3 — Saturating growth (Dim. Returns)"
H4_LABEL = "H4 — Null (constant)"


# ═══════════════════════════════════════════════════════════════════════════════
# 0.  HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

def logit(p):
    p = np.clip(p, 1e-6, 1 - 1e-6); return np.log(p / (1 - p))

def inv_logit(x): return 1 / (1 + np.exp(-x))

def stars(p):
    if p is None or not np.isfinite(p): return "—"
    return "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "n.s."

def conclusion(b, p):
    if not np.isfinite(b) or not np.isfinite(p): return "—"
    if p >= 0.05: return "H4 (null)"
    return "H3 (positive)" if b > 0 else "H1 (negative)"

THIN = "\u202f"
def uk(x, nd=2, sign=False):
    if x is None or not np.isfinite(x): return "—"
    s = f"{x:{'+' if sign else ''}.{nd}f}"; sgn = ""
    if s[0] in "+-": sgn, s = s[0], s[1:]
    ip, _, fp = s.partition(".")
    if len(ip) > 3: ip = f"{int(ip):,}".replace(",", THIN)
    return sgn + ip + ("," + fp if fp else "")

class UkTickFormatter(Formatter):
    def __init__(self, nd=None): super().__init__(); self.nd = nd
    def _decimals(self):
        if self.nd is not None: return self.nd
        try:
            locs = np.sort(np.asarray(self.axis.get_majorticklocs(), dtype=float))
            d = np.diff(locs); step = d[d > 0].min()
        except Exception: return 0
        return 0 if step >= 1 else int(np.ceil(-np.log10(step) - 1e-9))
    def __call__(self, x, pos=None): return uk(x, self._decimals())

def uk_axis(axis, nd=None): axis.set_major_formatter(UkTickFormatter(nd))

def legend_below(ax, handles, labels, ncol=2, pad=0.16):
    ax.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, -pad), ncol=ncol,
              frameon=True, borderaxespad=0.0)

def legend_compact(ax, handles, labels, loc="upper right"):
    """Small in-plot legend: short labels, 7.5 pt, tight padding, drawn on top."""
    leg = ax.legend(handles, labels, loc=loc, fontsize=7.5, frameon=True,
                    borderpad=0.35, labelspacing=0.3, handlelength=1.8,
                    handletextpad=0.5, borderaxespad=0.5)
    leg.set_zorder(10)
    return leg

def add_derived(df):
    df = df.copy()
    df["ctr"] = df["clicks"] / df["impr"]; df["log_v"] = np.log(df["impr"])
    df["day_of_week"] = df["hour"].dt.dayofweek
    df["bucket"] = pd.cut(df["impr"], bins=BUCKET_THRESHOLDS, labels=BUCKET_LABELS_CLEAN, right=False)
    df["bucket_int"] = df["bucket"].cat.codes + 1
    df["ctr_outlier"] = df["ctr"] > CTR_OUTLIER_THRESHOLD
    df["logit_ctr"] = logit(df["ctr"])
    return df

def time_dummies(df):
    d = pd.get_dummies(df, columns=["hour_of_day", "day_of_week"], drop_first=True)
    return d, [c for c in d.columns if c.startswith(("hour_of_day_", "day_of_week_"))]

def within_transform(df, outcome, predictors):
    cols = [outcome] + predictors
    return (df[cols] - df.groupby("campaign")[cols].transform("mean")) + df[cols].mean()

def coef_summary(m, name="log_v"):
    try:
        ci = m.conf_int().loc[name].values
        return float(m.params[name]), float(ci[0]), float(ci[1]), float(m.pvalues[name])
    except Exception:
        return np.nan, np.nan, np.nan, np.nan


# ── model fitters ─────────────────────────────────────────────────────────────

def _design(sub, quadratic=False, time_fe=True, campaign_fe=True):
    d, tc = time_dummies(sub) if time_fe else (sub.copy(), [])
    groups = d["campaign"].values.copy()
    if quadratic: d["log_v_sq"] = d["log_v"] ** 2
    cc = []
    if campaign_fe:
        d = pd.get_dummies(d, columns=["campaign"], drop_first=True, prefix="camp")
        cc = [c for c in d.columns if c.startswith("camp_")]
    cols = ["log_v"] + (["log_v_sq"] if quadratic else []) + tc + cc
    return d, sm.add_constant(d[cols].astype(float)), groups

def fit_glm(sub, quadratic=False, time_fe=True, campaign_fe=True, cov="cluster"):
    """PRIMARY: binomial GLM (logit). campaign_fe=False → 'total' pooled slope."""
    d, X, groups = _design(sub, quadratic, time_fe, campaign_fe)
    y = np.column_stack([d["clicks"].values, (d["impr"] - d["clicks"]).values]).astype(float)
    model = sm.GLM(y, X, family=sm.families.Binomial())
    return (model.fit(cov_type="cluster", cov_kwds={"groups": groups}) if cov == "cluster"
            else model.fit(cov_type=cov))

def fit_ols_logit(sub, quadratic=False, time_fe=True, cov="cluster"):
    """NAIVE: OLS on logit(CTR), campaign FE by within-transform."""
    d, tc = time_dummies(sub) if time_fe else (sub.copy(), [])
    preds = ["log_v"] + tc
    if quadratic: d["log_v_sq"] = d["log_v"] ** 2; preds = ["log_v", "log_v_sq"] + tc
    dm = within_transform(d, "logit_ctr", preds)
    X = sm.add_constant(dm[preds].astype(float)); y = dm["logit_ctr"].astype(float)
    return (sm.OLS(y, X).fit(cov_type="cluster", cov_kwds={"groups": d["campaign"].values})
            if cov == "cluster" else sm.OLS(y, X).fit(cov_type=cov))

def fit_wls_logit(sub, time_fe=True):
    d, X, groups = _design(sub, False, time_fe, True)
    return sm.WLS(d["logit_ctr"].astype(float), X, weights=d["impr"].astype(float)).fit(
        cov_type="cluster", cov_kwds={"groups": groups})

def glm_fit_stats(m, phi=None):
    """AIC, llf-BIC, deviance pseudo-R², overdispersion φ, QAIC (φ may be shared)."""
    k, n = len(m.params), m.nobs
    phi_own = float(m.pearson_chi2 / m.df_resid) if m.df_resid > 0 else np.nan
    phi_use = phi if phi is not None else phi_own
    return {"aic": float(m.aic), "bic": float(-2 * m.llf + k * np.log(n)),
            "pseudo_r2": float(1 - m.deviance / m.null_deviance) if m.null_deviance else np.nan,
            "deviance": float(m.deviance), "llf": float(m.llf), "k": k,
            "phi": phi_own, "qaic": float(-2 * m.llf / phi_use + 2 * k) if np.isfinite(phi_use) else np.nan}


# ═══════════════════════════════════════════════════════════════════════════════
# 1.  LOAD & PREPROCESS
# ═══════════════════════════════════════════════════════════════════════════════

def load_and_clean(mapping_path, events_path):
    log = {}
    mp = pd.read_csv(mapping_path, header=None, names=[COL_MAPPING["banner"], COL_MAPPING["campaign"]])
    mp = mp.rename(columns={v: k for k, v in COL_MAPPING.items()})[["banner", "campaign"]].drop_duplicates()
    dupes = mp.groupby("banner")["campaign"].nunique(); multi = dupes[dupes > 1]
    if not multi.empty:
        print(f"  [WARN] {len(multi)} banner(s) map to >1 campaign — keeping first")
        mp = mp.groupby("banner", as_index=False).first()

    ev = pd.read_csv(events_path, header=None,
                     names=[COL_EVENTS["date"], COL_EVENTS["hour"], COL_EVENTS["banner"],
                            COL_EVENTS["impr"], COL_EVENTS["clicks"]])
    ev = ev.rename(columns={v: k for k, v in COL_EVENTS.items()}); log["n_raw"] = len(ev)
    ev["date"] = pd.to_datetime(ev["date"], format="%Y-%m-%d", errors="coerce")
    if ev["date"].isna().sum():
        print(f"  [WARN] {ev['date'].isna().sum()} rows with unparseable dates — dropping"); ev = ev.dropna(subset=["date"])
    ev["hour"] = pd.to_numeric(ev["hour"], errors="coerce").astype("Int64")
    bad = ev["hour"].isna() | (ev["hour"] < 0) | (ev["hour"] > 23)
    if bad.sum(): print(f"  [WARN] {bad.sum()} rows with invalid hour — dropping"); ev = ev[~bad]
    ev["hour_ts"] = ev["date"] + pd.to_timedelta(ev["hour"].astype(int), unit="h")
    ev = ev.merge(mp, on="banner", how="left")
    n_un = ev["campaign"].isna().sum()
    if n_un: print(f"  [WARN] {n_un} rows with no campaign mapping — dropping"); ev = ev.dropna(subset=["campaign"])
    log["n_unmatched_banners"] = n_un

    df = (ev.groupby(["campaign", "hour_ts", "hour"], as_index=False).agg(impr=("impr", "sum"), clicks=("clicks", "sum"))
            .rename(columns={"hour_ts": "hour", "hour": "hour_of_day"}))
    log["n_after_agg"] = len(df)

    excl = {}
    m = df["impr"] == 0;           excl["impressions == 0"] = int(m.sum());     df = df[~m]
    m = df["clicks"] > df["impr"]; excl["clicks > impressions"] = int(m.sum()); df = df[~m]
    m = df["clicks"] < 0;          excl["clicks < 0"] = int(m.sum());           df = df[~m]
    # campaign-level: zero clicks over the ENTIRE active period at non-trivial volume
    # → click tracking failure / non-clickable placement, not a behavioural CTR of 0.
    camp_clicks = df.groupby("campaign")["clicks"].transform("sum")
    m = camp_clicks == 0
    n_dead = int(df.loc[m, "campaign"].nunique())
    excl[f"campaigns with 0 clicks over whole period ({n_dead} campaign(s))"] = int(m.sum()); df = df[~m]
    log["dead_campaigns"] = n_dead
    df_pre = df.copy()
    m = df["impr"] < MIN_IMPRESSIONS; excl[f"impressions < {MIN_IMPRESSIONS}"] = int(m.sum()); df = df[~m]
    df, df_pre = add_derived(df), add_derived(df_pre)
    excl["ctr > 0.20 (flagged, not removed)"] = int(df["ctr_outlier"].sum())

    log.update(exclusions=excl, n_final=len(df), n_campaigns=df["campaign"].nunique(),
               n_banners=ev["banner"].nunique(),
               date_range=f"{df['hour'].min().date()} – {df['hour'].max().date()}",
               impr_stats=df["impr"].describe(), ctr_stats=df["ctr"].describe(),
               zero_click_share=float((df["clicks"] == 0).mean()))
    return df, df_pre, log


# ═══════════════════════════════════════════════════════════════════════════════
# 2–3.  DESCRIPTIVES & TREND TESTS
# ═══════════════════════════════════════════════════════════════════════════════

def descriptive_stats(df):
    tbl = (df.groupby("bucket", observed=True)["ctr"]
             .agg(N="count", Mean=lambda x: x.mean()*100, SD=lambda x: x.std()*100,
                  Median=lambda x: x.median()*100, Q25=lambda x: x.quantile(.25)*100, Q75=lambda x: x.quantile(.75)*100)
             .reset_index())
    tbl["IQR"] = tbl["Q75"] - tbl["Q25"]; tbl = tbl.drop(columns=["Q25", "Q75"])
    for c in ["Mean", "SD", "Median", "IQR"]: tbl[c] = tbl[c].round(4)
    return tbl

def cochran_armitage(df):
    g = df.groupby("bucket_int", observed=True).agg(clicks=("clicks", "sum"), impr=("impr", "sum")).reset_index().sort_values("bucket_int")
    s, c, n = g["bucket_int"].values.astype(float), g["clicks"].values.astype(float), g["impr"].values.astype(float)
    p_bar = c.sum() / n.sum()
    Z = np.sum(s * (c - n * p_bar)) / np.sqrt(p_bar * (1 - p_bar) * (np.sum(n * s**2) - np.sum(n * s)**2 / n.sum()))
    p = 2 * stats.norm.sf(abs(Z)); direction = "decreasing" if Z < 0 else "increasing"
    return {"Z_CA": Z, "p": p, "direction": direction,
            "supports": f"{'H1' if Z < 0 else 'H3'} (monotone {direction})" if p < 0.05 else "H4 (no sig. trend)",
            "note": "p ignores within-campaign clustering — descriptive only"}

def spearman_test(df):
    bm = df.groupby("bucket_int", observed=True)["ctr"].mean().reset_index().sort_values("bucket_int")
    rho, p = stats.spearmanr(bm["bucket_int"], bm["ctr"])
    return {"rho": rho, "p": p, "supports": ("H1" if rho < 0 else "H3") if p < 0.05 else "H4",
            "note": f"N={len(bm)} bucket means — very low power; directional signal only"}


# ═══════════════════════════════════════════════════════════════════════════════
# 4.  REGRESSION
# ═══════════════════════════════════════════════════════════════════════════════

def run_regression(df):
    r = {}
    r["m1"] = fit_glm(df)                              # within (campaign FE)
    r["m2"] = fit_glm(df, quadratic=True)
    r["m_total"] = fit_glm(df, campaign_fe=False)      # total (no campaign FE)
    r["m2_stats"] = glm_fit_stats(r["m2"])
    phi_shared = r["m2_stats"]["phi"]                  # use the richer model's φ for both QAICs
    r["m1_stats"] = glm_fit_stats(r["m1"], phi=phi_shared)
    r["m2_stats"] = glm_fit_stats(r["m2"], phi=phi_shared)
    r["m_total_stats"] = glm_fit_stats(r["m_total"])

    b1, _, _, p1 = coef_summary(r["m1"]); b1q, _, _, _ = coef_summary(r["m2"]); b2, _, _, p2 = coef_summary(r["m2"], "log_v_sq")
    r["m1_supports"] = conclusion(b1, p1)
    r["m2_supports"] = ("H2 (inverted-U — β₁ > 0, β₂ < 0)" if (p2 < 0.05 and b2 < 0 and b1q > 0)
                        else "No evidence for H2 (inverted-U not supported)")
    r["ols_m1"] = fit_ols_logit(df); r["ols_m2"] = fit_ols_logit(df, quadratic=True)
    ob1, _, _, op1 = coef_summary(r["ols_m1"]); r["ols_m1_supports"] = conclusion(ob1, op1)
    return r


# ═══════════════════════════════════════════════════════════════════════════════
# 5.  CURVE FITTING
# ═══════════════════════════════════════════════════════════════════════════════

def h1_decay(V, a, b, g):      return a * np.exp(-b * V) + g
def h2_inverted_u(V, a, b, g): return a * (V ** b) * np.exp(-g * V)
def h3_saturating(V, a, b, g): return g - a * np.exp(-b * V)
def h4_null(V, mu):            return np.full_like(V, mu, dtype=float)

def fit_h1_h3_grid(V, CTR, direction):
    best_ss, best_popt = np.inf, None
    for beta in np.logspace(-3, 1, 200):
        basis = np.exp(-beta * V)
        c0, g = [float(v) for v in np.linalg.lstsq(np.column_stack([basis, np.ones_like(V)]), CTR, rcond=None)[0]]
        if (direction == "decay" and c0 <= 0) or (direction == "saturating" and c0 >= 0): continue
        ss = float(np.sum((CTR - (c0 * basis + g)) ** 2))
        if ss < best_ss:
            best_popt = np.array([c0, beta, g]) if direction == "decay" else np.array([-c0, beta, g]); best_ss = ss
    if best_popt is None: return None
    fn = h1_decay if direction == "decay" else h3_saturating; pred = fn(V, *best_popt)
    return best_popt, float(np.sum((CTR - pred) ** 2)), pred

def fit_h2_grid(V, CTR):
    vmin, vmax = V.min(), V.max(); best_ss, best_popt = np.inf, None
    for b in np.linspace(0.5, 8.0, 80):
        for g in np.linspace(0.01, 2.0, 80):
            if not (vmin <= b / g <= vmax): continue
            basis = (V ** b) * np.exp(-g * V)
            if not np.all(np.isfinite(basis)) or np.all(basis == 0): continue
            a = float(np.linalg.lstsq(basis.reshape(-1, 1), CTR, rcond=None)[0][0])
            if a <= 0: continue
            ss = float(np.sum((CTR - a * basis) ** 2))
            if ss < best_ss: best_ss, best_popt = ss, np.array([a, b, g])
    return None if best_popt is None else (best_popt, best_ss, h2_inverted_u(V, *best_popt))

def try_fit(fn, V, CTR, p0_list, bounds):
    best = None
    for p0 in p0_list:
        try:
            popt, _ = curve_fit(fn, V, CTR, p0=p0, bounds=bounds, maxfev=20_000)
            pred = fn(V, *popt); ss = float(np.sum((CTR - pred) ** 2))
            if best is None or ss < best[1]: best = (popt, ss, pred)
        except Exception: continue
    return best

def fit_curves(df):
    bkt = df.groupby("bucket_int", observed=True).agg(mean_ctr=("ctr", "mean"), mean_logv=("log_v", "mean")).reset_index().sort_values("bucket_int")
    V, CTR = bkt["mean_logv"].values, bkt["mean_ctr"].values * 100; ctr_mean = CTR.mean()
    cands = [(H1_LABEL, h1_decay, "decay"), (H2_LABEL, h2_inverted_u, None), (H3_LABEL, h3_saturating, "saturating"), (H4_LABEL, h4_null, None)]
    rows = []
    for label, fn, extra in cands:
        res = (fit_h1_h3_grid(V, CTR, "decay") if label == H1_LABEL else fit_h1_h3_grid(V, CTR, "saturating") if label == H3_LABEL
               else fit_h2_grid(V, CTR) if label == H2_LABEL else try_fit(fn, V, CTR, [[ctr_mean]], ([-np.inf], [np.inf])))
        k_nom = 1 if label == H4_LABEL else 3
        if res is None:
            print(f"  [WARN] {label}: no valid solution with sign constraint")
            rows.append({"Model": label, "Params": "failed", "k": k_nom, "R²": np.nan, "RMSE": np.nan, "AIC": np.nan, "BIC": np.nan}); continue
        popt, ss_res, _ = res; ss_tot = np.sum((CTR - ctr_mean) ** 2)
        k, n_ = len(popt), len(CTR); ll = -n_ / 2 * np.log(ss_res / n_ + 1e-12)
        rows.append({"Model": label, "Params": ", ".join(f"{p:.4f}" for p in popt), "k": k,
                     "R²": round(float(1 - ss_res / ss_tot) if ss_tot > 0 else np.nan, 4),
                     "RMSE": round(float(np.sqrt(ss_res / n_)), 6), "AIC": round(2*k - 2*ll, 3), "BIC": round(k*np.log(n_) - 2*ll, 3)})
    tbl = pd.DataFrame(rows); valid = tbl.dropna(subset=["AIC"]); tbl["Best fit"] = False
    if not valid.empty: tbl.loc[valid["AIC"].idxmin(), "Best fit"] = True
    return tbl, bkt


# ═══════════════════════════════════════════════════════════════════════════════
# 6.  ROBUSTNESS
# ═══════════════════════════════════════════════════════════════════════════════

def assign_size_quartiles(df):
    med = df.groupby("campaign")["impr"].median(); labels = ["Q1 (smallest)", "Q2", "Q3", "Q4 (largest)"]
    out = df.copy(); out["size_q"] = out["campaign"].map(pd.qcut(med, q=4, labels=labels, duplicates="drop"))
    return out, labels

def _both(sub):
    try: g = coef_summary(fit_glm(sub))
    except Exception: g = (np.nan,)*4
    try: o = coef_summary(fit_ols_logit(sub))
    except Exception: o = (np.nan,)*4
    return g, o

def _row_both(base, g, o):
    (gb, glo, ghi, gp), (ob, olo, ohi, op) = g, o
    base.update({"GLM β₁": round(gb, 4), "GLM 95% CI": f"[{glo:.4f}, {ghi:.4f}]", "GLM p": round(gp, 4), "GLM sig": stars(gp),
                 "OLS-logit β₁": round(ob, 4), "OLS 95% CI": f"[{olo:.4f}, {ohi:.4f}]", "OLS p": round(op, 4), "OLS sig": stars(op)})
    return base

def robustness_by_size(df):
    df2, labels = assign_size_quartiles(df); rows = []
    for q in labels:
        sub = df2[df2["size_q"] == q]
        if len(sub) < 30: continue
        rows.append(_row_both({"Quartile": q, "Median impr/hr": round(sub["impr"].median(), 1),
                               "N campaigns": sub["campaign"].nunique(), "N obs": len(sub),
                               "Zero-click share": round(float((sub["clicks"] == 0).mean()), 4)}, *_both(sub)))
    return pd.DataFrame(rows)

def robustness_temporal(df):
    mid = df["hour"].median(); rows = []
    for label, mask in [("First half", df["hour"] <= mid), ("Second half", df["hour"] > mid)]:
        sub = df[mask]
        rows.append(_row_both({"Period": label, "Date range": f"{sub['hour'].min().date()} – {sub['hour'].max().date()}",
                               "N obs": len(sub)}, *_both(sub)))
    return pd.DataFrame(rows)

def robustness_threshold_sensitivity(df_pre, thresholds=THRESHOLD_GRID):
    rows = []
    variants = [(f"impr >= {t}", df_pre[df_pre["impr"] >= t]) for t in thresholds]
    variants.append(("impr >= 10 & clicks > 0", df_pre[(df_pre["impr"] >= 10) & (df_pre["clicks"] > 0)]))
    for label, sub in variants:
        if len(sub) < 100: continue
        sub2, labels = assign_size_quartiles(sub); q1 = sub2[sub2["size_q"] == labels[0]]
        row = _row_both({"Filter": label, "N obs": len(sub2), "N campaigns": sub2["campaign"].nunique(),
                         "Zero-click share (all)": round(float((sub2["clicks"] == 0).mean()), 4),
                         "Zero-click share (Q1)": round(float((q1["clicks"] == 0).mean()), 4) if len(q1) else np.nan}, *_both(sub2))
        (gq, _, _, gqp), (oq, _, _, oqp) = _both(q1)
        row.update({"GLM β₁ Q1": round(gq, 4), "GLM Q1 p": round(gqp, 4), "GLM Q1 sig": stars(gqp),
                    "OLS β₁ Q1": round(oq, 4), "OLS Q1 p": round(oqp, 4), "OLS Q1 sig": stars(oqp)})
        rows.append(row)
    return pd.DataFrame(rows)

def robustness_specifications(df, reg):
    rows = []
    def _row(label, m, role):
        b, lo, hi, p = coef_summary(m)
        rows.append({"Specification": label, "Role": role, "β₁": round(b, 4), "95% CI": f"[{lo:.4f}, {hi:.4f}]",
                     "p": round(p, 4), "sig": stars(p), "Conclusion": conclusion(b, p)})
    _row("Binomial GLM (logit), campaign FE + time FE, clustered SE", reg["m1"], "PRIMARY (within)")
    _row("Binomial GLM (logit), time FE only — NO campaign FE, clustered SE", reg["m_total"], "TOTAL (pooled)")
    for label, fn, role in [
        ("Binomial GLM (logit), campaign FE only, clustered SE", lambda: fit_glm(df, time_fe=False), "GLM variant"),
        ("Binomial GLM (logit), campaign FE + time FE, HC3 SE (no clustering)", lambda: fit_glm(df, cov="HC3"), "GLM variant — SE only"),
        ("WLS logit(CTR), weights = impressions, campaign FE + time FE, clustered SE", lambda: fit_wls_logit(df), "weighted OLS"),
    ]:
        try: _row(label, fn(), role)
        except Exception as e: print(f"  [WARN] {label} failed: {e}")
    _row("OLS logit(CTR), campaign FE + time FE, clustered SE", reg["ols_m1"], "NAIVE (unweighted, zeros clipped)")
    for label, fn in [("OLS logit(CTR), campaign FE only, clustered SE", lambda: fit_ols_logit(df, time_fe=False)),
                      ("OLS logit(CTR), campaign FE + time FE, HC3 SE", lambda: fit_ols_logit(df, cov="HC3"))]:
        try: _row(label, fn(), "naive variant")
        except Exception as e: print(f"  [WARN] {label} failed: {e}")
    return pd.DataFrame(rows)

def within_range(df, q=(0.05, 0.95)):
    """P5…P95 of ln V's deviation from its campaign mean: the range volume actually moves within a campaign."""
    dev = df["log_v"] - df.groupby("campaign")["log_v"].transform("mean")
    return tuple(float(x) for x in dev.quantile(q))

def between_campaign_analysis(df):
    camp = (df.groupby("campaign").agg(clicks=("clicks", "sum"), impr=("impr", "sum"), n_obs=("impr", "size"),
                                       mean_logv=("log_v", "mean")).reset_index())
    camp["ctr"] = camp["clicks"] / camp["impr"]; camp["logit_ctr"] = logit(camp["ctr"])
    rho, p_rho = stats.spearmanr(camp["mean_logv"], camp["ctr"]); tau, p_tau = stats.kendalltau(camp["mean_logv"], camp["ctr"])
    w_lo, w_hi = within_range(df)
    return camp, {"n_campaigns": len(camp), "spearman_rho": float(rho), "spearman_p": float(p_rho),
                  "kendall_tau": float(tau), "kendall_p": float(p_tau), "within_dev_p05": w_lo, "within_dev_p95": w_hi}


# ═══════════════════════════════════════════════════════════════════════════════
# 7.  FIGURES
# ═══════════════════════════════════════════════════════════════════════════════

def save(fig, path, dpi): fig.savefig(path, dpi=dpi, bbox_inches="tight"); plt.close(fig); print(f"  ✓  {path}")
def _caption(note): print(f"     ↳ підпис: {note}")

def fig1_boxplots(df, out, dpi):
    cap = float(np.percentile(df["ctr"].dropna() * 100, 99)); n_above = int((df["ctr"] * 100 > cap).sum())
    b1z = (df[df["bucket"] == "B1"]["clicks"] == 0).mean() * 100
    fig, ax = plt.subplots(figsize=(7, 4.2))
    ax.boxplot([np.clip(df[df["bucket"] == b]["ctr"].dropna() * 100, 0, cap) for b in BUCKET_LABELS_CLEAN],
               patch_artist=True, widths=0.55, boxprops=dict(facecolor="#e6e6e6", edgecolor="black", linewidth=0.8),
               whiskerprops=dict(color="black", linewidth=0.8), capprops=dict(color="black", linewidth=0.8),
               medianprops=dict(color="black", linewidth=1.3),
               flierprops=dict(marker="o", markersize=2, markerfacecolor="#7f7f7f", markeredgecolor="none", alpha=0.5))
    ax.set_xticks(range(1, 6)); ax.set_xticklabels(BUCKET_LABELS_UK); ax.set_ylim(0, cap * 1.05)
    ax.set_xlabel("Група обсягу показів"); ax.set_ylabel("Погодинна клікабельність, %"); uk_axis(ax.yaxis)
    save(fig, out / "fig1_boxplots.pdf", dpi)
    _caption(f"вісь ординат обмежено 99-м перцентилем ({uk(cap,1)} %); {n_above} спостережень не показано; у B₁ {uk(b1z,0)} % годин без кліків")

def fig2_mean_ci(df, out, dpi):
    g = df.groupby("bucket", observed=True)["ctr"].agg(mean=np.mean, sem=stats.sem).reset_index()
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.errorbar(range(len(g)), g["mean"] * 100, yerr=g["sem"] * 1.96 * 100, fmt="o-", color=CLR_MAIN, linewidth=1.5,
                markersize=5, capsize=3, capthick=1.0, elinewidth=1.0, label="Середня клікабельність, 95 % довірчий інтервал")
    ax.set_xticks(range(len(g))); ax.set_xticklabels(BUCKET_LABELS_UK)
    ax.set_ylim(0, float(((g["mean"] + g["sem"] * 1.96) * 100).max()) * 1.12)   # from zero: no visual exaggeration
    ax.set_xlabel("Група обсягу показів"); ax.set_ylabel("Середня погодинна клікабельність, %"); uk_axis(ax.yaxis); ax.legend(loc="lower left")
    save(fig, out / "fig2_mean_ctr_ci.pdf", dpi)

def fig3_hourly(df, out, dpi):
    h = df.groupby("hour_of_day").agg(mean_ctr=("ctr", "mean"), mean_impr=("impr", "mean")).reset_index()
    fig, ax1 = plt.subplots(figsize=(7, 4.4))
    l1, = ax1.plot(h["hour_of_day"], h["mean_ctr"] * 100, color=CLR_MAIN, marker="o", markersize=4, linewidth=1.5)
    ax1.set_xlabel("Година доби"); ax1.set_ylabel("Середня клікабельність, %"); ax1.set_xticks(range(0, 24, 2)); uk_axis(ax1.yaxis)
    ax2 = ax1.twinx(); ax2.grid(False)
    l2, = ax2.plot(h["hour_of_day"], h["mean_impr"], color=CLR_ALT, linestyle="--", marker="s", markersize=3.5, linewidth=1.3)
    ax2.set_ylabel("Середня кількість показів за годину"); uk_axis(ax2.yaxis, nd=0)
    legend_below(ax1, [l1, l2], ["Середня клікабельність, %", "Середня кількість показів за годину"], ncol=2)
    fig.subplots_adjust(bottom=0.26); save(fig, out / "fig3_hourly_pattern.pdf", dpi)

def fig4_marginal(df, reg, out, dpi):
    ml, mlv = df["logit_ctr"].mean(), df["log_v"].mean()
    w_lo, w_hi = within_range(df)                       # slopes are within-campaign: draw them only where a campaign moves
    lv = np.linspace(mlv + w_lo, mlv + w_hi, 200)
    cap = float(np.percentile(df["ctr"].dropna() * 100, 99)); n_above = int((df["ctr"] * 100 > cap).sum())
    def band(m):
        b = m.params["log_v"]; ci = m.conf_int().loc["log_v"].values
        p, lo, hi = (inv_logit(ml + c * (lv - mlv)) * 100 for c in (b, ci[0], ci[1]))
        return p, np.minimum(lo, hi), np.maximum(lo, hi)
    pg, lg, hg = band(reg["m1"]); po, _, ho = band(reg["ols_m1"])
    fig, ax = plt.subplots(figsize=(7, 4.4))
    h_rng = ax.axvspan(lv[0], lv[-1], facecolor="#ededed", edgecolor="none", zorder=0)
    ax.scatter(df["log_v"], df["ctr"] * 100, s=5, color="#9e9e9e", alpha=0.25, edgecolor="none", zorder=1)
    ax.fill_between(lv, lg, hg, color=CLR_MAIN, alpha=0.20, zorder=2)
    hg_, = ax.plot(lv, pg, color=CLR_MAIN, linewidth=1.8, zorder=4); ho_, = ax.plot(lv, po, color=CLR_ALT, linewidth=1.5, linestyle="--", zorder=3)
    ax.set_ylim(0, cap * 1.05)
    ax.set_xlabel("Логарифм погодинного обсягу показів, ln(V)"); ax.set_ylabel("Передбачувана клікабельність, %"); uk_axis(ax.yaxis)
    legend_compact(ax, [hg_, ho_, h_rng], ["Біноміальна GLM, 95 % довірча смуга", "МНК на logit(CTR)",
                                           "Типовий внутрішньокампанійний діапазон ln(V)"], loc="upper right")
    save(fig, out / "fig4_marginal_effect.pdf", dpi)
    _caption(f"GLM β₁ = {uk(reg['m1'].params['log_v'],3,sign=True)}; МНК β₁ = {uk(reg['ols_m1'].params['log_v'],3,sign=True)}; "
             "прогноз при середніх logit(CTR) та ln(V); часові коваріати на середніх; сірі точки — погодинні спостереження; "
             f"криві показано лише в типовому внутрішньокампанійному діапазоні ln(V) = {uk(lv[0],2)}…{uk(lv[-1],2)} "
             f"(середнє ln(V) плюс 5-й…95-й перцентилі відхилень ln(V) від середнього кампанії, ≈ {uk((w_hi - w_lo) / np.log(2),1)} подвоєння); "
             f"вісь ординат обмежено 99-м перцентилем ({uk(cap,1)} %), {n_above} спостережень не показано")

def fig5_curves(df, curve_tbl, bkt_df, out, dpi):
    V, CTR = bkt_df["mean_logv"].values, bkt_df["mean_ctr"].values * 100; V_s = np.linspace(V.min(), V.max(), 300)
    fig, ax = plt.subplots(figsize=(7, 4.4))
    for label, (color, dash, ll, fn) in {H1_LABEL: (CLR_H1, "-", "H1 — експоненційний спад", h1_decay),
                                          H2_LABEL: (CLR_H2, "-.", "H2 — перевернута U", h2_inverted_u),
                                          H3_LABEL: (CLR_H3, "--", "H3 — зростання з насиченням", h3_saturating),
                                          H4_LABEL: (CLR_H4, ":", "H4 — константа", h4_null)}.items():
        row = curve_tbl[curve_tbl["Model"] == label]
        if row.empty or row.iloc[0]["Params"] == "failed":
            ax.plot([], [], color="#bdbdbd", linewidth=1.2, linestyle="--", label=f"{ll} (не зійшовся)"); continue
        popt = [float(x) for x in row.iloc[0]["Params"].split(", ")]; best = bool(row.iloc[0]["Best fit"])
        ax.plot(V_s, fn(V_s, *popt), color=color, linestyle=dash, linewidth=2.0 if best else 1.4, label=ll)
    ax.scatter(V, CTR, color="black", s=45, zorder=5, marker="D", label="Спостережувані середні по групах")
    ax.set_xlabel("Середній логарифм обсягу показів у групі, ln(V)"); ax.set_ylabel("Середня клікабельність, %"); uk_axis(ax.yaxis)
    # lower-left corner is empty (curves lie above ≈2.4 % at low ln(V)); keeps all five bucket means visible
    h, l = ax.get_legend_handles_labels()
    legend_compact(ax, h, l, loc="lower left")
    save(fig, out / "fig5_curve_fitting.pdf", dpi)
    best_m = curve_tbl.loc[curve_tbl["Best fit"], "Model"].values
    _caption(f"найкраща апроксимація за AIC: {best_m[0] if len(best_m) else '—'} (потовщена лінія); "
             "ромби — середні по п'яти групах обсягу")

def fig6_between_campaign(camp, bc, reg, out, dpi):
    """Рис. 6 — кампанії (точки) + загальний нахил (без ФЕ) проти внутрішньокампанійного (з ФЕ)."""
    b_w = reg["m1"].params["log_v"]; b_t = reg["m_total"].params["log_v"]
    x = camp["mean_logv"].values; y = camp["ctr"].values * 100
    s = 15 + 150 * np.sqrt(camp["n_obs"].values / camp["n_obs"].max())
    x_line = np.linspace(x.min(), x.max(), 200)
    gm_logit = float(camp["logit_ctr"].mean()); gm_x = float(x.mean())
    y_total = inv_logit(gm_logit + b_t * (x_line - gm_x)) * 100
    # the within slope describes movement inside one campaign, not this cloud: a short segment at its centre
    x_seg = np.linspace(gm_x + bc["within_dev_p05"], gm_x + bc["within_dev_p95"], 50)
    y_within = inv_logit(gm_logit + b_w * (x_seg - gm_x)) * 100
    fig, ax = plt.subplots(figsize=(7, 4.4))
    h_pts = ax.scatter(x, y, s=s, facecolor="#d0d0d0", edgecolor="black", linewidth=0.5, alpha=0.8, zorder=3)
    h_t, = ax.plot(x_line, y_total, color="black", linestyle="--", linewidth=1.6, zorder=4)
    h_w, = ax.plot(x_seg, y_within, color="black", linestyle="-", linewidth=2.6, solid_capstyle="butt", zorder=5)
    ax.plot(x_seg[[0, -1]], y_within[[0, -1]], linestyle="none", marker="|", markersize=9, markeredgewidth=1.6, color="black", zorder=5)
    ax.set_xlabel("Середній логарифм обсягу показів кампанії, ln(V)"); ax.set_ylabel("Клікабельність кампанії, %"); uk_axis(ax.yaxis)
    from matplotlib.lines import Line2D
    h_pts_proxy = Line2D([], [], marker="o", linestyle="none", markersize=6, markerfacecolor="#d0d0d0",
                         markeredgecolor="black", markeredgewidth=0.5)
    legend_compact(ax, [h_pts_proxy, h_t, h_w],
                   ["Кампанії", "Загальний нахил (без ФЕ кампаній)",
                    "Внутрішньокампанійний нахил (типовий діапазон у межах кампанії)"],
                   loc="upper right")
    save(fig, out / "fig6_between_campaign.pdf", dpi)
    _caption(f"n = {bc['n_campaigns']} кампаній; розмір маркера ∝ √кількості годин; "
             f"ρ Спірмена = {uk(bc['spearman_rho'],2,sign=True)} (p = {uk(bc['spearman_p'],3)}); "
             f"загальний нахил β = {uk(b_t,3,sign=True)}, внутрішньокампанійний β₁ = {uk(b_w,3,sign=True)}; "
             f"різниця {uk(b_t - b_w,3,sign=True)} — композиційна складова; внутрішньокампанійний нахил показано відрізком "
             f"завдовжки ≈ {uk((bc['within_dev_p95'] - bc['within_dev_p05']) / np.log(2),1)} подвоєння "
             "(5-й…95-й перцентилі відхилень ln(V) від середнього кампанії) у центрі хмари кампаній")

def fig7_threshold_sensitivity(sens, out, dpi):
    d = sens[sens["Filter"].str.startswith("impr >=") & ~sens["Filter"].str.contains("clicks")].copy()
    if d.empty: return
    d["thr"] = d["Filter"].str.extract(r"(\d+)").astype(int); d = d.sort_values("thr")
    def ci(col):
        return (d[col].str.extract(r"\[(-?[\d.]+)").astype(float).iloc[:, 0].values,
                d[col].str.extract(r",\s*(-?[\d.]+)\]").astype(float).iloc[:, 0].values)
    glo, ghi = ci("GLM 95% CI"); olo, ohi = ci("OLS 95% CI")
    fig, ax1 = plt.subplots(figsize=(7, 4.4))
    lo_ = ax1.errorbar(d["thr"] * 0.94, d["OLS-logit β₁"], yerr=[d["OLS-logit β₁"] - olo, ohi - d["OLS-logit β₁"]],
                       fmt="s--", color=CLR_ALT, mfc="white", mec=CLR_ALT, capsize=3, linewidth=1.3, markersize=5)
    lg_ = ax1.errorbar(d["thr"] * 1.06, d["GLM β₁"], yerr=[d["GLM β₁"] - glo, ghi - d["GLM β₁"]],
                       fmt="o-", color=CLR_MAIN, mfc=CLR_MAIN, capsize=3, linewidth=1.5, markersize=5)
    ax1.axhline(0, color="black", linewidth=0.8, linestyle=":")
    ax1.set_xscale("log"); ax1.set_xticks(d["thr"]); ax1.set_xticklabels([str(t) for t in d["thr"]]); ax1.minorticks_off()
    ax1.set_xlabel("Мінімальна кількість показів за годину (поріг включення)"); ax1.set_ylabel("Коефіцієнт β₁ при ln(V)"); uk_axis(ax1.yaxis)
    ax2 = ax1.twinx(); ax2.grid(False)
    # hatched, unfilled bars: readable in B/W and transparent, so the ax1 series stay visible
    b = ax2.bar(d["thr"], d["Zero-click share (all)"] * 100, width=d["thr"] * 0.25,
                facecolor="none", edgecolor="#808080", hatch="///", linewidth=0.6)
    zmax = float((d["Zero-click share (all)"] * 100).max())
    ax2.set_ylim(0, max(0.5, np.ceil(zmax * 1.25 / 0.5) * 0.5))   # top tick above the tallest bar: never clipped
    ax2.set_ylabel("Частка годин без кліків, %"); uk_axis(ax2.yaxis)
    # legend on ax2 (the top-most axes) so the twin-axis bars never cover it
    legend_compact(ax2, [lg_, lo_, b],
                   ["Біноміальна GLM, 95 % ДІ", "МНК на logit(CTR), 95 % ДІ", "Частка годин без кліків"],
                   loc="upper right")
    save(fig, out / "fig7_threshold_sensitivity.pdf", dpi)


# ═══════════════════════════════════════════════════════════════════════════════
# 8.  RESULTS SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

def write_summary(path, log, desc, ca, sp, reg, curve_tbl, rb_size, rb_spec, rb_time, sens, bc):
    g1, g2, gt = reg["m1"], reg["m2"], reg["m_total"]; s1, s2, st = reg["m1_stats"], reg["m2_stats"], reg["m_total_stats"]
    b1, lo1, hi1, p1 = coef_summary(g1); b1q, lo1q, hi1q, p1q = coef_summary(g2); b2, lo2, hi2, p2 = coef_summary(g2, "log_v_sq")
    bt, lot, hit, pt = coef_summary(gt)
    ob1, olo1, ohi1, op1 = coef_summary(reg["ols_m1"]); ob1q, _, _, op1q = coef_summary(reg["ols_m2"]); ob2, olo2, ohi2, op2 = coef_summary(reg["ols_m2"], "log_v_sq")
    dbl = lambda b: np.exp(b * np.log(2))

    L = ["═"*70, "RESULTS SUMMARY — CTR vs. Impression Volume  (v4.1: GLM primary)", "═"*70, "",
         "── 4.1 DATASET ─────────────────────────────────────────────",
         f"  Total event rows (raw):       {log['n_raw']:,}", f"  Unique banners:               {log['n_banners']:,}",
         f"  Unique campaigns:             {log['n_campaigns']:,}", f"  Rows after campaign agg:      {log['n_after_agg']:,}",
         f"  Final analysis dataset:       {log['n_final']:,}", f"  Date range:                   {log['date_range']}",
         f"  Zero-click hours (share):     {log['zero_click_share']:.4f}", "", "  Exclusions (sequential — totals add up):"]
    L += [f"    {k:<45} {v:,}" for k, v in log["exclusions"].items()]
    L += ["", "  Impressions/hr:",
          f"    Min={log['impr_stats']['min']:.0f}  Median={log['impr_stats']['50%']:.0f}  Mean={log['impr_stats']['mean']:.1f}  Max={log['impr_stats']['max']:.0f}",
          "", "── 4.2 DESCRIPTIVE (bucket-level mean CTR %) ────────────────", desc.to_string(index=False), "",
          "── 4.3 TREND TESTS ──────────────────────────────────────────",
          f"  Cochran-Armitage  Z_CA={ca['Z_CA']:.4f}  p={ca['p']:.6f} {stars(ca['p'])}  direction={ca['direction']}  supports={ca['supports']}",
          f"  ⚠  {ca['note']}",
          f"  Spearman          ρ={sp['rho']:.4f}       p={sp['p']:.6f} {stars(sp['p'])}  supports={sp['supports']}",
          f"  ⚠  {sp['note']}", "",
          "── 4.4 REGRESSION — PRIMARY: binomial GLM (logit), campaign + time FE, clustered SE ──",
          f"  Overdispersion φ = Pearson χ²/df = {s2['phi']:.2f}   (φ ≫ 1 → raw AIC/BIC unreliable; QAIC used for model comparison)", "",
          "  Model 1 — Linear in ln(V)  [WITHIN-campaign]",
          f"    β₁ (ln V) = {b1:+.6f}  95%CI=[{lo1:.6f}, {hi1:.6f}]  p={p1:.6f} {stars(p1)}",
          f"    odds ratio per doubling of impressions: {dbl(b1):.4f}  [{dbl(lo1):.4f}, {dbl(hi1):.4f}]",
          f"    pseudo-R²(dev)={s1['pseudo_r2']:.4f}  QAIC={s1['qaic']:.1f}  (raw AIC={s1['aic']:.1f})  N={int(g1.nobs):,}  k={s1['k']}",
          f"    → {reg['m1_supports']}", "",
          "  Model 2 — Quadratic (H2 test)",
          f"    β₁ (ln V)   = {b1q:+.6f}  95%CI=[{lo1q:.6f}, {hi1q:.6f}]  p={p1q:.6f} {stars(p1q)}",
          f"    β₂ (ln V²)  = {b2:+.6f}  95%CI=[{lo2:.6f}, {hi2:.6f}]  p={p2:.6f} {stars(p2)}",
          f"    pseudo-R²={s2['pseudo_r2']:.4f}  QAIC={s2['qaic']:.1f}  ΔQAIC(M2−M1)={s2['qaic']-s1['qaic']:+.1f}  (raw ΔAIC={s2['aic']-s1['aic']:+.1f} — inflated by overdispersion)",
          f"    → {reg['m2_supports']}", "",
          "  Model T — TOTAL slope (time FE, NO campaign FE)  [pooled across campaigns]",
          f"    β_total (ln V) = {bt:+.6f}  95%CI=[{lot:.6f}, {hit:.6f}]  p={pt:.6f} {stars(pt)}",
          f"    odds ratio per doubling: {dbl(bt):.4f}  [{dbl(lot):.4f}, {dbl(hit):.4f}]", "",
          "── 4.4b NAIVE COMPARISON — OLS on logit(CTR), within-transform, clustered SE ──",
          "  (zero-click hours clipped to logit(1e-6); all hours weighted equally)",
          f"  Model 1:  β₁ = {ob1:+.6f}  95%CI=[{olo1:.6f}, {ohi1:.6f}]  p={op1:.6f} {stars(op1)}  R²={reg['ols_m1'].rsquared:.4f}  → {reg['ols_m1_supports']}",
          f"  Model 2:  β₁ = {ob1q:+.6f} (p={op1q:.4f});  β₂ = {ob2:+.6f}  95%CI=[{olo2:.6f}, {ohi2:.6f}]  p={op2:.6f} {stars(op2)}",
          "  ⚠  Positive β₁ here is NOT reproduced by the exposure-weighted GLM (see 4.6d for the mechanism).", "",
          "── 4.5 CURVE FITTING (5 bucket means — illustrative) ────────", curve_tbl.to_string(index=False), "",
          "── 4.6a ROBUSTNESS — campaign size quartiles (GLM vs naive OLS) ──", rb_size.to_string(index=False),
          "  ⚠  14–15 clusters per quartile: cluster-robust p-values are approximate.", "",
          "── 4.6b ROBUSTNESS — specification ──────────────────────────", rb_spec.to_string(index=False), "",
          "── 4.6c ROBUSTNESS — temporal halves (GLM vs naive OLS) ─────", rb_time.to_string(index=False), "",
          "── 4.6d ROBUSTNESS — min-impression threshold ────────────────",
          "  Expectation: GLM β₁ stable across thresholds; naive OLS β₁ collapses as zero-click hours drop out.",
          sens.to_string(index=False), "",
          "── 4.7 TOTAL vs WITHIN — composition decomposition ──────────",
          f"  β_total  (no campaign FE)  = {bt:+.4f}  p={pt:.4f} {stars(pt)}",
          f"  β_within (campaign FE)     = {b1:+.4f}  p={p1:.4f} {stars(p1)}",
          f"  β_total − β_within         = {bt-b1:+.4f}   ← composition (between-campaign) component",
          f"  Campaign-level rank correlation (n={bc['n_campaigns']}): Spearman ρ={bc['spearman_rho']:+.3f} (p={bc['spearman_p']:.4f}), "
          f"Kendall τ={bc['kendall_tau']:+.3f} (p={bc['kendall_p']:.4f})",
          ("  → Aggregate decline is a between-campaign composition effect; within-campaign association is null."
           if (pt < 0.05 and bt < 0 and p1 >= 0.05) else
           "  → Check: pattern differs from the expected (β_total<0 sig., β_within≈0)."),
          "", "═"*70]
    text = "\n".join(L)
    with open(path, "w") as f: f.write(text)
    print(text); print(f"\n  ✓  {path}")


# ═══════════════════════════════════════════════════════════════════════════════
# 9.  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    global MIN_IMPRESSIONS
    ap = argparse.ArgumentParser(); ap.add_argument("--mapping", required=True); ap.add_argument("--events", required=True)
    ap.add_argument("--out", default="./results"); ap.add_argument("--dpi", type=int, default=300)
    ap.add_argument("--min-impr", type=int, default=MIN_IMPRESSIONS)
    a = ap.parse_args(); MIN_IMPRESSIONS = a.min_impr
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)

    print("\n── Loading & cleaning ───────────────────────────────────────")
    df, df_pre, log = load_and_clean(a.mapping, a.events)
    print(f"  {log['n_final']:,} records | {log['n_campaigns']:,} campaigns | {log['date_range']}")

    print("\n── Descriptive statistics ───────────────────────────────────")
    desc = descriptive_stats(df); desc.to_csv(out / "table2_descriptive.csv", index=False)

    print("\n── Trend tests ──────────────────────────────────────────────")
    ca = cochran_armitage(df); sp = spearman_test(df)
    pd.DataFrame([{**{f"CA_{k}": v for k, v in ca.items()}, **{f"Sp_{k}": v for k, v in sp.items()}}]).to_csv(out / "table3_trend_tests.csv", index=False)

    print("\n── Regression (GLM primary + total + naive OLS) ────────────")
    reg = run_regression(df)
    for tag, m in (("table4_glm_within_linear.csv", reg["m1"]), ("table4b_glm_within_quadratic.csv", reg["m2"]),
                   ("table4t_glm_total_linear.csv", reg["m_total"]),
                   ("table4c_ols_logit_linear.csv", reg["ols_m1"]), ("table4d_ols_logit_quadratic.csv", reg["ols_m2"])):
        pd.DataFrame({"predictor": m.params.index, "coef": m.params.values, "ci_lo": m.conf_int()[0].values,
                      "ci_hi": m.conf_int()[1].values, "p": m.pvalues.values}).to_csv(out / tag, index=False)

    print("\n── Curve fitting ────────────────────────────────────────────")
    curve_tbl, bkt_df = fit_curves(df); curve_tbl.to_csv(out / "table5_curve_fitting.csv", index=False)

    print("\n── Robustness checks ────────────────────────────────────────")
    rb_size = robustness_by_size(df); rb_spec = robustness_specifications(df, reg)
    rb_time = robustness_temporal(df); sens = robustness_threshold_sensitivity(df_pre)
    rb_size.to_csv(out / "table6_robustness_size.csv", index=False); rb_spec.to_csv(out / "table7_robustness_spec.csv", index=False)
    rb_time.to_csv(out / "table8_robustness_time.csv", index=False); sens.to_csv(out / "table11_threshold_sensitivity.csv", index=False)

    print("\n── Between-campaign analysis ────────────────────────────────")
    camp, bc = between_campaign_analysis(df); camp.to_csv(out / "table12_campaign_level.csv", index=False)
    pd.DataFrame([bc]).to_csv(out / "table12b_between_campaign_fit.csv", index=False)

    print("\n── Generating figures ───────────────────────────────────────")
    fig1_boxplots(df, out, a.dpi); fig2_mean_ci(df, out, a.dpi); fig3_hourly(df, out, a.dpi); fig4_marginal(df, reg, out, a.dpi)
    fig5_curves(df, curve_tbl, bkt_df, out, a.dpi); fig6_between_campaign(camp, bc, reg, out, a.dpi); fig7_threshold_sensitivity(sens, out, a.dpi)

    print("\n── Writing results summary ──────────────────────────────────")
    write_summary(out / "results_summary.txt", log, desc, ca, sp, reg, curve_tbl, rb_size, rb_spec, rb_time, sens, bc)
    print(f"\n✅  Done. Results saved to: {out.resolve()}\n")

if __name__ == "__main__":
    main()
