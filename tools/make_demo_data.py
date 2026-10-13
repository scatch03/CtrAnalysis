"""Synthetic demo dataset — try ctr-monitor without real data (also used for the README screenshots).

    python3 tools/make_demo_data.py [OUT_DIR]      # default: ./demo-data

Writes demo-banner.csv and demo-ads_log_hour.csv in the format ctr_analysis.py expects (no headers).
48 made-up campaigns over 14 days with a diurnal traffic cycle, campaign-level CTR heterogeneity,
a mild within-campaign fatigue effect (CTR ∝ volume^-0.1) and two campaigns whose clicks are never
tracked. Deterministic (seed 7). Needs numpy + pandas.
"""
import os, sys
import numpy as np, pandas as pd
rng = np.random.default_rng(7)
out = sys.argv[1] if len(sys.argv) > 1 else "demo-data"
os.makedirs(out, exist_ok=True)
days = pd.date_range("2026-01-05", periods=14, freq="D")
hours = np.arange(24)
diurnal = 0.35 + 0.65 * np.clip(np.sin((hours - 5) / 24 * 2 * np.pi), 0, None) ** 0.8 + 0.08
mapping, rows = [], []
banner = 1000
for c in range(1, 49):
    camp = 100 + c
    size = np.exp(rng.uniform(np.log(40), np.log(120_000)))          # mean impressions / hour
    base_ctr = np.clip(0.028 * (size / 2000) ** -0.12 * np.exp(rng.normal(0, 0.35)), 0.002, 0.08)
    dead = c in (17, 41)                                                # click tracking broken
    nb = rng.integers(2, 9)
    shares = rng.dirichlet(np.ones(nb))
    start = rng.integers(0, 4)
    for b in range(nb):
        banner += 1
        mapping.append((banner, camp))
        for di, day in enumerate(days):
            if di < start:
                continue
            for h in hours:
                lam = size * shares[b] * diurnal[h] * np.exp(rng.normal(0, 0.25))
                impr = rng.poisson(lam)
                if impr == 0:
                    continue
                p = 0.0 if dead else base_ctr * (lam / (size * shares[b])) ** -0.10    # mild within-campaign fatigue
                p = np.clip(p * np.exp(rng.normal(0, 0.15)), 0, 0.9)
                rows.append((day.strftime("%Y-%m-%d"), h, banner, impr, rng.binomial(impr, p)))
pd.DataFrame(mapping).to_csv(f"{out}/demo-banner.csv", header=False, index=False)
pd.DataFrame(rows).to_csv(f"{out}/demo-ads_log_hour.csv", header=False, index=False)
print(f"{len(mapping)} banners, 48 campaigns, {len(rows):,} event rows")
