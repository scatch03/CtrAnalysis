"""One analysis run in its own process:  python -m app.worker <run_dir>

A fresh interpreter per run means the drop-in script is re-imported every time
(swap ctr_analysis.py → next run uses it, no restart), memory is returned to the
OS afterwards, and a run can be cancelled by killing its process group.
"""
import os
import sys
import traceback
from pathlib import Path

os.environ.setdefault("MPLBACKEND", "Agg")
sys.dont_write_bytecode = True  # never leave __pycache__ next to the drop-in script

from . import config  # noqa: E402
from .script_info import REQUIRED_API  # noqa: E402
from .store import read_json, write_json  # noqa: E402


def main():
    run_dir = Path(sys.argv[1])
    meta = read_json(run_dir / "meta.json")
    p, inp = meta["params"], meta["inputs"]
    mapping, events = run_dir / "input" / inp["mapping"]["stored"], run_dir / "input" / inp["events"]["stored"]
    try:
        from .memfix import free_irls_garbage
        from .pipeline import load_script, run_legacy, run_structured
        free_irls_garbage()
        print(f"script : {config.SCRIPT_PATH}")
        ca = load_script(config.SCRIPT_PATH)
        print(f"version: {(ca.__doc__ or '').strip().splitlines()[0] if ca.__doc__ else '?'}")
        print(f"params : min_impr={p['min_impr']} dpi={p['dpi']}", flush=True)
        missing = [f for f in REQUIRED_API if not hasattr(ca, f)]
        if missing:
            print(f"[legacy] script lacks {', '.join(missing)} — falling back to its own main()", flush=True)
            run_legacy(ca, run_dir, mapping, events, p["min_impr"], p["dpi"])
        else:
            run_structured(ca, run_dir, mapping, events, p["min_impr"], p["dpi"])
    except BaseException as e:  # noqa: BLE001 — report everything, including SystemExit from argparse
        tb = traceback.format_exc()
        print(tb, file=sys.stderr, flush=True)
        write_json(run_dir / "error.json", {"type": type(e).__name__, "message": str(e) or type(e).__name__,
                                            "traceback": tb})
        sys.exit(1)


if __name__ == "__main__":
    main()
