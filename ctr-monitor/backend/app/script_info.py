"""Static facts about the drop-in analysis script, read without importing it."""
import ast
import hashlib
import re
from datetime import datetime, timezone

from . import config

# functions the structured pipeline (pipeline.py) calls — a script without them
# still runs, but in "legacy" mode (its own main(), files + summary only)
REQUIRED_API = (
    "load_and_clean", "descriptive_stats", "cochran_armitage", "spearman_test",
    "run_regression", "coef_summary", "fit_curves", "robustness_by_size",
    "robustness_specifications", "robustness_temporal", "robustness_threshold_sensitivity",
    "between_campaign_analysis", "write_summary", "save", "inv_logit",
    "fig1_boxplots", "fig2_mean_ci", "fig3_hourly", "fig4_marginal", "fig5_curves",
    "fig6_between_campaign", "fig7_threshold_sensitivity",
    "h1_decay", "h2_inverted_u", "h3_saturating", "h4_null",
)


def script_info():
    p = config.SCRIPT_PATH
    if not p.exists():
        return {"path": str(p), "present": False}
    src = p.read_bytes()
    text = src.decode("utf-8", errors="replace")
    version, missing, default_min = None, list(REQUIRED_API), None
    try:
        tree = ast.parse(text)
        doc = ast.get_docstring(tree) or ""
        version = next((ln.strip() for ln in doc.splitlines() if ln.strip()), None)
        defined = {n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
        defined |= {t.id for n in tree.body if isinstance(n, ast.Assign) for t in n.targets
                    if isinstance(t, ast.Name)}
        missing = [f for f in REQUIRED_API if f not in defined]
    except SyntaxError as e:
        version = f"syntax error: {e}"
    m = re.search(r"^MIN_IMPRESSIONS\s*=\s*(\d+)", text, re.M)
    if m:
        default_min = int(m.group(1))
    return {
        "path": str(p), "present": True, "version": version,
        "sha256": hashlib.sha256(src).hexdigest(),
        "mtime": datetime.fromtimestamp(p.stat().st_mtime, timezone.utc).isoformat(timespec="seconds"),
        "size": len(src), "missing_api": missing, "structured": not missing,
        "default_min_impr": default_min or 10,
    }
