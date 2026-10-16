"""Wild cluster score bootstrap (WCR) for the full-sample coefficients of the main model table:
β₁ of the within model (9), β₁ and β₂ of the quadratic model (10), and β_total of the model without
campaign fixed effects — 57 campaign clusters on n2615.

    python3 tools/wcb_models.py --mapping M.csv --events E.csv [--B 9999] [--seed 20261015] [--out results.csv]

Same procedure as wild_cluster_bootstrap.py (restricted score bootstrap, Kline & Santos 2012): H0 for the
tested coefficient is imposed through an offset, every other parameter (including the other polynomial term
in (10)) is re-estimated, and the efficient score is formed with the nuisance parameters partialled out.
Designs and the conventional cluster-robust estimates are the script's own `_design` / `fit_glm`. Rademacher
and Webb weights use the same seed as wild_cluster_bootstrap.py, so the β₁ row of (9) reproduces its
"Full sample" row.
"""
import argparse
import contextlib
import io
import os

os.environ.setdefault("MPLBACKEND", "Agg")

import pandas as pd

from mundlak import bootstrap
from wild_cluster_bootstrap import load_script

TERMS = (("(9) within, campaign FE", "β₁ (ln V)", {}, "log_v"),
         ("(10) quadratic, campaign FE", "β₁ (ln V)", {"quadratic": True}, "log_v"),
         ("(10) quadratic, campaign FE", "β₂ (ln² V)", {"quadratic": True}, "log_v_sq"),
         ("total, no campaign FE", "β_total (ln V)", {"campaign_fe": False}, "log_v"))


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
    for model, label, kw, param in TERMS:
        m = ca.fit_glm(df, **kw)
        d, X, groups = ca._design(df, **kw)
        b, lo, hi, p = ca.coef_summary(m, param)
        se = float(m.bse[param])
        boot, G = bootstrap(d, X, groups, param, b, se, a.B, a.seed)
        rows.append({"model": model, "term": label, "estimate": b, "cluster SE": se, "cluster 95% CI lo": lo,
                     "cluster 95% CI hi": hi, "cluster p": p, **boot, "N": int(m.nobs), "G": G, "k": len(m.params)})
        print(f"  {model:28} {label:15} {b:+.6f}  CI[{lo:+.6f}, {hi:+.6f}]  cluster p={p:.4f}  |  "
              f"Rademacher p={boot['Rademacher p']:.4f} CI[{boot['Rademacher 95% CI lo']:+.6f}, {boot['Rademacher 95% CI hi']:+.6f}]  "
              f"Webb p={boot['Webb p']:.4f} CI[{boot['Webb 95% CI lo']:+.6f}, {boot['Webb 95% CI hi']:+.6f}]", flush=True)
    if a.out:
        pd.DataFrame(rows).to_csv(a.out, index=False)


if __name__ == "__main__":
    main()
