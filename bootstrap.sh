#!/usr/bin/env bash
# ctr-monitor bootstrap — writes ./ctr-monitor (Flask + React + Docker) for ctr_analysis.py
#   bash bootstrap.sh        # then: cd ctr-monitor && docker compose up --build -d  → http://localhost:8080
# If ./ctr_analysis.py sits next to this script (or in the current folder) it replaces the embedded v4.1 copy.
set -euo pipefail
DEST="${1:-ctr-monitor}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "refusing to overwrite non-empty $DEST (set FORCE=1 to overwrite its files)" >&2; exit 1
fi
mkdir -p "$DEST"
w() { mkdir -p "$(dirname "$DEST/$1")"; cat > "$DEST/$1"; }

w '.dockerignore' <<'__CTRMON_EOF__'
**/node_modules
**/dist
**/__pycache__
**/*.pyc
data
.claude
.git
__CTRMON_EOF__
w '.gitignore' <<'__CTRMON_EOF__'
node_modules/
frontend/dist/
backend/static/
data/
__pycache__/
*.pyc
__CTRMON_EOF__
w 'Dockerfile' <<'__CTRMON_EOF__'
# syntax=docker/dockerfile:1

# ── 1. React UI ─────────────────────────────────────────────────────────────
FROM node:20.18.1-alpine AS ui
WORKDIR /ui
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

# ── 2. Flask API + analysis worker ──────────────────────────────────────────
FROM python:3.12.8-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLBACKEND=Agg \
    MPLCONFIGDIR=/home/ctr/.mpl \
    CTR_DATA_DIR=/data \
    CTR_SCRIPT=/app/ctr_analysis.py \
    CTR_STATIC_DIR=/app/static

COPY backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

RUN useradd --system --uid 10001 --create-home ctr && mkdir -p /data && chown ctr:ctr /data
COPY backend/ /app/backend/
COPY ctr_analysis.py /app/ctr_analysis.py
COPY --from=ui /ui/dist /app/static

USER ctr
# warm matplotlib's font cache so the first run doesn't pay for it
RUN python -c "import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot"

WORKDIR /app/backend
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/health', timeout=4)" || exit 1

# one gunicorn worker on purpose: it owns the run dispatcher; heavy work runs in
# per-run subprocesses, threads keep the API responsive meanwhile
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--timeout", "900", "--graceful-timeout", "30", "--access-logfile", "-", "wsgi:app"]
__CTRMON_EOF__
w 'README.md' <<'__CTRMON_EOF__'
# ctr·monitor

A web front end for `ctr_analysis.py` (v4.1 — binomial GLM primary; QAIC; total-vs-within decomposition).
It is a Flask API with a React UI, packaged as one Docker image. The layout borrows from Nagios (grouped status
tables, totals strip, tactical overview) and MRTG (Daily/Weekly/Monthly graphs with Max/Average/Current rows).

```bash
docker compose up --build -d
# → http://localhost:8080
```

Upload the two input files on **Runs**. These are the same ones the CLI takes, with no header row:

| file | columns |
|---|---|
| mapping | `banner_id, campaign_id` |
| events  | `date (YYYY-MM-DD), hour (0-23), banner_id, impressions, clicks` — `.gz/.bz2/.xz/.zip` accepted |

## What you get per run

| page | contents |
|---|---|
| **Tactical Overview** | upload form, plain-language summary, evidence tally, run details and primary specification, quartile cards, primary within-campaign β₁, total-vs-within verdict, dataset tiles, hypothesis board H1–H4, estimates that disagree with the primary result, traffic graph |
| **Estimates** | every estimate (34 rows for the v4.1 script) labelled with the hypothesis it supports (H1–H4), grouped by section §4.1–§4.7, filterable by hypothesis or "disagrees with primary", and expandable to the full numbers |
| **Campaigns** | campaign table with each campaign's size quartile and that quartile's hypothesis, plus hours, volume, CTR, zero-click share, CTR>20 % flags and a daily-CTR sparkline. The quartile cards above it act as a filter |
| **Traffic Graphs** | evidence tally per hypothesis, then the MRTG view per campaign or for all campaigns: impressions/h and CTR over 48 h / 8 d / 35 d / full range. A selected campaign's header shows its size quartile and that quartile's hypothesis |
| **Analysis** | evidence tally per hypothesis, then the paper figures, redrawn interactively, each with a table view: buckets, regression, curve fits, total vs within, threshold sensitivity, and a forest plot of every robustness β₁ |
| **Results Summary** | the "In plain words" summary, then `results_summary.txt` exactly as written by the script |
| **Figures & Tables** | the script's own PDFs (with PNG previews and captions), every CSV, and a zip of everything |
| **Runs** | upload, re-run with new `--min-impr` / `--dpi`, cancel, delete, live event log |

On **every page**, under the upload form, there's an **In plain words** summary. It's 3–5 sentences written by fixed rules
from the run's numbers, and is also saved in the zip as `plain_summary.txt`. It starts as its one-line headline;
**Show** expands the full text on every page and **Hide** collapses it again. Your browser remembers the choice.

Below it is the **Evidence by hypothesis** tally, also on every page. It starts as one line
(H1 5 · H2 0 · H3 7 · H4 13 · 12 disagree with H4), and each count links to that filter on the Estimates page. It has
its own app-wide Show/Hide, remembered by your browser. On Overview and Estimates, a two-box row with the run details
and the primary specification follows.

Then come the **campaign size quartile** cards (§4.6a): Q1–Q4, each with the hypothesis its GLM slope supports. On
Campaigns, clicking a card or chip filters the table (`#/campaigns?q=Q2`); on other pages it opens that filtered view.
The cards start as a row of chips (Q1 H4 · Q2 H1 · Q3 H1 · Q4 H3) with one app-wide Show/Hide.

So every page opens with three slim bars: summary headline, tally, and quartile chips. Each expands with **Show**,
which applies everywhere until you click **Hide**. A run's detail page shows that run's summary, tally and quartiles,
rather than those of the run picked in the top bar.

## How it works

```
browser ──► gunicorn (1 worker, 8 threads) ── Flask API ── dispatcher thread
                                                              │ one subprocess per run
                                                              ▼
                                         python -m app.worker  →  imports ctr_analysis.py
                                                                  runs the same steps as its main()
                                                                  writes out/ + result.json + panel.pkl
```

* **The script is not modified.** `backend/app/pipeline.py` calls the script's functions in the same order
  `main()` does and writes the same files. It also keeps the in-memory results for the UI. The script's
  `save()` / `_caption()` hooks are wrapped to add PNG previews and to collect the figure captions.
  On the n2615 dataset, every CSV and `results_summary.txt` matched the existing `results2615-v10` output.
  Running natively on macOS, all files were byte-identical. Inside the container, `results_summary.txt` is
  byte-identical and six regression/trend CSVs differ only in the last digits (≤ 1e-8 relative), because the
  container uses OpenBLAS instead of Apple Accelerate.
* **Swapping the script:** `docker-compose.yml` bind-mounts `./ctr_analysis.py`. Each run starts a fresh
  interpreter, so replacing the file means the next run uses the new version, with no restart needed. If a future
  version renames or removes the functions the wrapper relies on (listed in `backend/app/script_info.py`), the
  app falls back to calling the script's own `main()`. That **legacy mode** gives only the summary, files and log,
  with no checks or interactive charts.
* **Storage:** each run lives in the `ctr-data` volume under `/data/runs/<id>/`. That folder holds the inputs (so a
  run can be repeated with other parameters), `out/`, `run.log`, and the JSON for the UI.

### Hypothesis labels

Every estimate in a run is labelled by the hypothesis it supports (paper §3.3). The rule is the script's own
`conclusion()`:

| label | rule | meaning |
|---|---|---|
| **H1** fatigue | β < 0, p < .05 | CTR falls as volume rises |
| **H2** inverted-U | quadratic β₂ < 0 with β₁ > 0, p < .05 | CTR rises, then falls (shown as "H2 not supported" otherwise) |
| **H3** growth | β > 0, p < .05 | CTR rises with volume |
| **H4** null | p ≥ .05 | no detectable effect |

A **weight** tag shows how much the script relies on each estimate:

- `primary`: the main specification.
- `pooled`: no campaign fixed effects.
- `naive`: unweighted OLS, kept for comparison.
- `descriptive`, `low power`, `few clusters`, `SE only`: p-values the script itself flags as approximate.
- `illustrative`: the 5-point curve fit.
- `info`: rows that are not hypothesis tests, such as data ingest, dispersion, decomposition and pipeline.

Every page shows an **Evidence by hypothesis** tally: how many estimates support each hypothesis, and how many disagree
with the primary result. Each cell links to that filter on the Estimates page. The tally describes the run picked in the top
bar; a run's own detail page shows that run's tally instead.

## Configuration

| env | default | |
|---|---|---|
| `CTR_MAX_CONCURRENT_RUNS` | `1` | runs executed in parallel |
| `CTR_MAX_UPLOAD_MB` | `2048` | request size limit |
| `CTR_WEB_DPI` | `110` | DPI of the PNG previews (PDFs use the run's `--dpi`) |
| `CTR_SCATTER_SAMPLE` | `4000` | raw points sent to the browser for the marginal-effect scatter |

## Memory and large datasets

The script's primary GLM uses one dummy column per campaign, so the design matrix is
rows × (campaigns + ~30) × 8 bytes. That's about 20 MB for n2204 (104 campaigns), but 1.4 GB for n1985
(797 campaigns, 215,781 campaign-hours).

statsmodels' IRLS also holds on to every iteration's weighted copy of that matrix: each iteration's
`_MinimalWLS` result is a self-referencing `Bunch`, which Python frees only when its cycle collector
happens to run. The worker therefore runs a full garbage collection once per IRLS iteration
(`backend/app/memfix.py`). That's pure memory management: estimates are identical and the script is untouched.

Even so, a large dataset needs a lot of memory, and nothing caps it per container, so it's bounded by the
Docker VM. Give Docker Desktop enough memory under Settings → Resources (see the run page for the
measured peak). A run killed for lack of memory is reported as **Out of memory … during "<stage>"**, and
the run page shows each stage's peak memory.

## Security

The app has no authentication. Compose publishes it on **127.0.0.1 only** because uploads are client traffic data.
To share it with a team, put it behind an authenticating reverse proxy before changing the port binding.

## Development

```bash
# backend (needs the requirements.txt stack)
cd backend && python wsgi.py                 # :5000, no reloader (it would start a second dispatcher)
# frontend
cd frontend && npm install && npm run dev    # :5173, proxies /api → :5000
```

After changing anything under `ctr-monitor/`, regenerate the installer from the repo root with
`python3 tools/make_bootstrap.py`.

Python packages are pinned to the versions that produced the v10 results (numpy 2.3.2, pandas 3.0.1, scipy 1.16.1,
statsmodels 0.14.6, matplotlib 3.10.5).
__CTRMON_EOF__
w 'backend/app/__init__.py' <<'__CTRMON_EOF__'
import logging

from flask import Flask, send_from_directory

from . import config


def create_app(start_dispatcher=True):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    app = Flask(__name__, static_folder=None)
    app.config["MAX_CONTENT_LENGTH"] = config.MAX_UPLOAD_MB * 1024 * 1024
    app.json.ensure_ascii = False

    from .api import bp
    app.register_blueprint(bp)

    # single-page app: real files from the React build, everything else → index.html
    @app.get("/", defaults={"path": ""})
    @app.get("/<path:path>")
    def spa(path):
        if path.startswith("api/"):
            return {"error": "not found"}, 404
        if path and (config.STATIC_DIR / path).is_file():
            return send_from_directory(config.STATIC_DIR, path, max_age=31536000 if path.startswith("assets/") else 0)
        if (config.STATIC_DIR / "index.html").is_file():
            return send_from_directory(config.STATIC_DIR, "index.html", max_age=0)
        return ("frontend not built — run `npm run build` in frontend/ or use the Vite dev server", 404)

    if start_dispatcher:
        from .jobs import dispatcher
        dispatcher.start()
    return app
__CTRMON_EOF__
w 'backend/app/api.py' <<'__CTRMON_EOF__'
import hashlib
import io
import os
import shutil
import zipfile
from pathlib import Path

import pandas as pd
from flask import Blueprint, abort, jsonify, request, send_file, send_from_directory
from werkzeug.utils import secure_filename

from . import config, series, store
from .jobs import describe_exit, dispatcher
from .jsonsafe import clean
from .checks import build_checks, size_quartiles
from .narrative import narrate
from .pipeline import STAGES
from .script_info import script_info

bp = Blueprint("api", __name__, url_prefix="/api")


def _dir_or_404(run_id):
    try:
        d = store.run_dir(run_id)
    except KeyError:
        abort(404)
    if not (d / "meta.json").exists():
        abort(404)
    return d


def _load_result(d):
    """result.json with checks rebuilt from the numbers — older runs get the current labelling too."""
    res = store.read_json(d / "result.json")
    if res and res.get("mode") == "structured":
        res["checks"] = build_checks(res, res.get("stage_times"), res.get("figure_errors") or {})
        res["size_quartiles"] = size_quartiles(res)
    return res


def _run_view(meta):
    d = store.run_dir(meta["id"])
    if meta.get("status") == "ok" and "tally" not in meta:   # one-time migration of runs made before the H1–H4 labels
        res = _load_result(d)
        checks = (res or {}).get("checks") or {}
        meta = {k: v for k, v in (store.read_meta(meta["id"]) or meta).items() if k != "totals"}
        meta.update(tally=checks.get("tally"), primary=checks.get("primary"))
        store.write_json(d / "meta.json", meta)
    if meta.get("status") == "failed" and meta.get("exit_code", 0) < 0 and not (d / "error.json").exists() \
            and str(meta.get("error", "")).startswith("──"):   # runs that failed before describe_exit existed
        meta = store.update_meta(meta["id"], error=describe_exit(d, meta["exit_code"]))
    view = dict(meta)
    view.pop("pid", None)
    view.pop("totals", None)
    if meta.get("status") in store.ACTIVE:
        view["progress"] = store.read_json(d / "progress.json")
    return view


@bp.errorhandler(400)
@bp.errorhandler(404)
@bp.errorhandler(409)
@bp.errorhandler(413)
def _err(e):
    return jsonify(error=getattr(e, "description", str(e))), e.code


@bp.get("/health")
def health():
    return {"ok": True}


@bp.get("/info")
def info():
    return {"script": script_info(),
            "config": {"max_upload_mb": config.MAX_UPLOAD_MB, "max_concurrent_runs": config.MAX_CONCURRENT_RUNS,
                       "web_dpi": config.WEB_DPI, "upload_suffixes": config.UPLOAD_SUFFIXES},
            "stages": [{"key": k, "label": l} for k, l in STAGES]}


# ── runs ─────────────────────────────────────────────────────────────────────

@bp.get("/runs")
def runs():
    return jsonify([_run_view(m) for m in store.list_runs()])


def _suffix(name):
    n = name.lower()
    for s in (".gz", ".bz2", ".xz", ".zip"):
        if n.endswith(s):
            return ".csv" + s
    if n.endswith((".csv", ".txt")):
        return ".csv"
    abort(400, f"unsupported file type: {name!r} — expected .csv (optionally .gz/.bz2/.xz/.zip)")


def _save_upload(fs, dest_dir, role):
    if not fs or not fs.filename:
        abort(400, f"missing file: {role}")
    stored = role + _suffix(fs.filename)
    h, size = hashlib.sha256(), 0
    with open(dest_dir / stored, "wb") as f:
        while chunk := fs.stream.read(1 << 20):
            h.update(chunk)
            size += len(chunk)
            f.write(chunk)
    if size == 0:
        abort(400, f"{role} file is empty")
    return {"name": secure_filename(fs.filename) or stored, "stored": stored, "size": size, "sha256": h.hexdigest()}


def _int_param(name, default, lo, hi):
    raw = request.form.get(name, "")
    if raw == "":
        return default
    try:
        v = int(raw)
    except ValueError:
        abort(400, f"{name} must be an integer")
    if not lo <= v <= hi:
        abort(400, f"{name} must be between {lo} and {hi}")
    return v


@bp.post("/runs")
def create_run():
    si = script_info()
    if not si.get("present"):
        abort(409, f"analysis script not found at {si['path']}")
    params = {"min_impr": _int_param("min_impr", si.get("default_min_impr", 10), 1, 1_000_000),
              "dpi": _int_param("dpi", 300, 50, 1200)}
    label = (request.form.get("label") or "").strip()[:80]
    src = request.form.get("from_run")

    rid = store.new_run_id()
    d = config.RUNS_DIR / rid
    (d / "input").mkdir(parents=True)
    try:
        if src:
            sd = _dir_or_404(src)
            smeta = store.read_meta(src)
            inputs = smeta["inputs"]
            for role in ("mapping", "events"):
                s, t = sd / "input" / inputs[role]["stored"], d / "input" / inputs[role]["stored"]
                try:
                    os.link(s, t)          # same volume → no copy
                except OSError:
                    shutil.copy2(s, t)
            label = label or smeta.get("label") or ""
        else:
            inputs = {"mapping": _save_upload(request.files.get("mapping"), d / "input", "mapping"),
                      "events": _save_upload(request.files.get("events"), d / "input", "events")}
    except BaseException:
        shutil.rmtree(d, ignore_errors=True)
        raise

    meta = {"id": rid, "label": label or inputs["events"]["name"], "status": "queued", "created": store.now_iso(),
            "params": params, "inputs": inputs, "from_run": src,
            "script": {k: si.get(k) for k in ("version", "sha256", "mtime", "structured")}}
    store.write_json(d / "meta.json", meta)
    dispatcher.submit(rid)
    return jsonify(_run_view(meta)), 201


@bp.get("/runs/<run_id>")
def get_run(run_id):
    d = _dir_or_404(run_id)
    view = _run_view(store.read_meta(run_id))
    if view.get("status") == "failed":
        view["traceback"] = (store.read_json(d / "error.json") or {}).get("traceback")
    if not view.get("progress"):
        view["progress"] = store.read_json(d / "progress.json")
    return jsonify(view)


@bp.post("/runs/<run_id>/cancel")
def cancel_run(run_id):
    _dir_or_404(run_id)
    if not dispatcher.cancel(run_id):
        abort(409, "run is not queued or running")
    return jsonify(_run_view(store.read_meta(run_id)))


@bp.delete("/runs/<run_id>")
def delete_run(run_id):
    _dir_or_404(run_id)
    dispatcher.cancel(run_id)
    store.delete_run(run_id)
    return "", 204


@bp.get("/runs/<run_id>/result")
def result(run_id):
    d = _dir_or_404(run_id)
    res = _load_result(d)
    if res is None:
        abort(404, "no result yet")
    return jsonify(clean(res))


@bp.get("/runs/<run_id>/narrative")
def narrative(run_id):
    d = _dir_or_404(run_id)
    n = narrate(_load_result(d))
    if not n:
        abort(404, "no plain-language summary for this run (no structured results)")
    return jsonify(n)


@bp.get("/runs/<run_id>/log")
def run_log(run_id):
    d = _dir_or_404(run_id)
    offset = request.args.get("offset", type=int)
    p = d / "run.log"
    if offset is not None:
        try:
            with open(p, "rb") as f:
                f.seek(offset)
                data = f.read(512_000)
            return {"text": data.decode("utf-8", errors="replace"), "offset": offset + len(data)}
        except FileNotFoundError:
            return {"text": "", "offset": 0}
    text, size = store.tail(p)
    return {"text": text, "offset": size}


@bp.get("/runs/<run_id>/files/<path:name>")
def run_file(run_id, name):
    d = _dir_or_404(run_id)
    return send_from_directory(d / "out", name, as_attachment=request.args.get("download") == "1", max_age=3600)


@bp.get("/runs/<run_id>/bundle.zip")
def bundle(run_id):
    d = _dir_or_404(run_id)
    out = d / "out"
    if not out.exists():
        abort(404)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(out.iterdir()):
            if p.is_file() and p.suffix != ".png":
                z.write(p, f"results-{run_id}/{p.name}")
        if (d / "run.log").exists():
            z.write(d / "run.log", f"results-{run_id}/run.log")
        n = narrate(_load_result(d))
        if n:
            z.writestr(f"results-{run_id}/plain_summary.txt", f"{n['headline']}\n\n{n['text']}\n\n— {n['note']}\n")
    buf.seek(0)
    return send_file(buf, mimetype="application/zip", as_attachment=True, download_name=f"ctr-results-{run_id}.zip")


@bp.get("/runs/<run_id>/tables/<name>")
def table(run_id, name):
    d = _dir_or_404(run_id)
    if not name.endswith(".csv") or "/" in name or name.startswith("."):
        abort(404)
    p = d / "out" / name
    if not p.exists():
        abort(404)
    df = pd.read_csv(p)
    return jsonify(clean({"name": name, "columns": list(df.columns), "rows": df.values.tolist()}))


@bp.get("/runs/<run_id>/mrtg")
def mrtg(run_id):
    d = _dir_or_404(run_id)
    if not (d / "panel.pkl").exists():
        abort(404, "no traffic panel for this run")
    try:
        return jsonify(clean(series.mrtg(run_id, request.args.get("campaign") or None)))
    except KeyError:
        abort(404, "unknown campaign")
__CTRMON_EOF__
w 'backend/app/checks.py' <<'__CTRMON_EOF__'
"""Every estimate in a run, labelled by the hypothesis it supports (paper §3.3).

  H1  fatigue      CTR falls with volume        (β < 0, p < .05)
  H2  inverted-U   rise then fall               (quadratic: β₁ > 0, β₂ < 0, p₂ < .05)
  H3  growth       CTR rises with volume        (β > 0, p < .05)
  H4  null         no detectable effect         (p ≥ .05)

This mirrors the script's own conclusion() / *_supports labels. Each estimate also
carries a `weight` tag saying how much the script trusts it (primary, pooled, naive,
descriptive, low power, few clusters, SE only, illustrative, …). Rows that are not a
hypothesis test (data, pipeline, dispersion, decomposition) are `info`.
"""
import re

from .jsonsafe import fnum

ALPHA = 0.05
HYPS = ("H1", "H2", "H3", "H4")

GROUPS = {
    "glm":              ("Binomial GLM", "§4.4 primary specification"),
    "decomposition":    ("Total vs within", "§4.7 composition"),
    "trend":            ("Trend tests", "§4.3 bucket-level, pooled"),
    "naive":            ("Naive OLS", "§4.4b OLS on logit(CTR)"),
    "curves":           ("Curve fitting", "§4.5 five bucket means"),
    "robust-size":      ("Robust · size", "§4.6a campaign size quartiles"),
    "robust-time":      ("Robust · time", "§4.6c temporal halves"),
    "robust-threshold": ("Robust · threshold", "§4.6d min-impression threshold"),
    "robust-spec":      ("Robust · spec", "§4.6b specification variants"),
    "dataset":          ("Dataset", "§4.1 ingest & exclusions"),
    "pipeline":         ("Pipeline", "run integrity, figures"),
}


def fp(p):
    if p is None:
        return "—"
    if p == 0:
        return "<1e-300"
    return f"{p:.2e}" if p < 1e-4 else f"{p:.4f}"


def stars(p):
    if p is None:
        return "—"
    return "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "n.s."


def hyp_of(b, p):
    """Same rule as the script's conclusion(): n.s. → H4, negative → H1, positive → H3."""
    if b is None or p is None:
        return None
    if p >= ALPHA:
        return "H4"
    return "H3" if b > 0 else "H1"


def first_hyp(text):
    m = re.match(r"\s*(H[1-4])\b", str(text or ""))
    return m.group(1) if m else None


def fmt_beta(b, lo=None, hi=None, p=None, sym="β₁"):
    if b is None:
        return f"{sym} not computable"
    s = f"{sym}={b:+.4f}"
    if lo is not None and hi is not None:
        s += f" CI[{lo:+.4f}, {hi:+.4f}]"
    if p is not None:
        s += f" p={fp(p)} {stars(p)}"
    return s


def perf(**kv):
    return " ".join(f"{k}={v:.6g}" for k, v in kv.items() if v is not None)


class _Builder:
    def __init__(self, stage_times):
        self.rows, self.stage_times = [], stage_times or {}

    def add(self, group, service, output, *, hyp=None, supported=True, weight=None, info=False, stage=None,
            perfdata="", detail=None, view=None, note=None, primary=False):
        self.rows.append({
            "id": f"{group}/{service}", "host": group, "service": service,
            "kind": "info" if info else "hypothesis", "hyp": hyp, "supported": supported,
            "weight": weight, "primary": primary, "output": output, "perf": perfdata,
            "detail": detail or [], "note": note, "stage": stage, "duration": self.stage_times.get(stage), "view": view,
        })

    def effect(self, group, service, est, *, weight=None, note=None, stage, view=None, label=None, extra=None, primary=False):
        b, lo, hi, p = (fnum(est.get(k)) for k in ("b", "lo", "hi", "p"))
        out = f"{label + ' · ' if label else ''}{fmt_beta(b, lo, hi, p)}"
        if extra:
            out += f" · {extra}"
        self.add(group, service, out, hyp=hyp_of(b, p), weight=weight, note=note, stage=stage, view=view,
                 primary=primary, perfdata=perf(beta=b, ci_lo=lo, ci_hi=hi, p=p))


def build_checks(res, stage_times=None, figure_errors=None):
    c = _Builder(stage_times)
    ds, reg = res["dataset"], res["regression"]
    w = reg["within"]

    # ── GLM (primary) ───────────────────────────────────────────────────────
    c.effect("glm", "within_slope", w, stage="regression", view="analysis/marginal", weight="primary", primary=True,
             label="campaign + time FE, clustered SE",
             extra=f"OR per doubling {w['or_doubling'][0]:.4f}" if w.get("or_doubling") and w["or_doubling"][0] else None)
    q = reg["quadratic"]
    b2, p2 = fnum(q["b2"].get("b")), fnum(q["b2"].get("p"))
    h2 = str(q.get("supports", "")).startswith("H2")
    c.add("glm", "quadratic_h2",
          f"{fmt_beta(b2, q['b2'].get('lo'), q['b2'].get('hi'), p2, 'β₂')} · ΔQAIC(M2−M1)={q['dqaic']:+.1f} · {q.get('supports')}"
          if b2 is not None and q.get("dqaic") is not None else str(q.get("supports") or "not computable"),
          hyp="H2" if b2 is not None else None, supported=h2, weight="primary", stage="regression",
          view="analysis/curves", perfdata=perf(beta2=b2, p=p2, dqaic=fnum(q.get("dqaic"))))
    c.effect("glm", "total_slope", reg["total"], stage="regression", view="analysis/between", weight="pooled",
             label="time FE only, no campaign FE")
    phi = fnum(reg.get("phi"))
    c.add("glm", "overdispersion",
          f"φ = Pearson χ²/df = {phi:.2f} (φ ≫ 1 → raw AIC/BIC unreliable; QAIC used for model comparison)"
          if phi is not None else "φ not computable", info=True, stage="regression", perfdata=perf(phi=phi))

    # ── decomposition (§4.7) ───────────────────────────────────────────────
    d = reg["decomposition"]
    c.add("decomposition", "total_vs_within",
          (f"β_total={d['b_total']:+.4f} {stars(d.get('p_total'))} − β_within={d['b_within']:+.4f} "
           f"{stars(d.get('p_within'))} = {d['diff']:+.4f} composition · {d['message']}")
          if d.get("b_total") is not None and d.get("b_within") is not None else d.get("message", "not computable"),
          info=True, stage="regression", view="analysis/between",
          perfdata=perf(b_total=fnum(d.get("b_total")), b_within=fnum(d.get("b_within")), diff=fnum(d.get("diff"))))
    bc = res["between"]["stats"]
    rho, p = fnum(bc.get("spearman_rho")), fnum(bc.get("spearman_p"))
    c.add("decomposition", "campaign_rank_corr",
          f"n={bc.get('n_campaigns')} campaigns · Spearman ρ={rho:+.3f} (p={fp(p)}) · Kendall τ="
          f"{fnum(bc.get('kendall_tau')):+.3f} (p={fp(fnum(bc.get('kendall_p')))}) — association across campaigns, not within"
          if rho is not None else "not computable", info=True, stage="between", view="analysis/between",
          perfdata=perf(rho=rho, p=p))

    # ── trend tests ─────────────────────────────────────────────────────────
    t = res["trend"]
    ca_, sp = t["cochran_armitage"], t["spearman"]
    z, p = fnum(ca_.get("Z_CA")), fnum(ca_.get("p"))
    c.add("trend", "cochran_armitage",
          f"Z_CA={z:+.3f} p={fp(p)} {stars(p)} · {ca_.get('direction')} · {ca_.get('supports')}"
          if z is not None and p is not None else "not computable",
          hyp=first_hyp(ca_.get("supports")), weight="descriptive", note=ca_.get("note"),
          stage="trend", view="analysis/buckets", perfdata=perf(z=z, p=p))
    rho, p = fnum(sp.get("rho")), fnum(sp.get("p"))
    c.add("trend", "spearman_buckets",
          f"ρ={rho:+.3f} p={fp(p)} {stars(p)} · {sp.get('supports')}" if rho is not None and p is not None
          else "not computable", hyp=first_hyp(sp.get("supports")), weight="low power", note=sp.get("note"),
          stage="trend", view="analysis/buckets", perfdata=perf(rho=rho, p=p))

    # ── naive OLS ───────────────────────────────────────────────────────────
    o = reg["ols"]["m1"]
    agree = hyp_of(fnum(o.get("b")), fnum(o.get("p"))) == hyp_of(fnum(w.get("b")), fnum(w.get("p")))
    c.effect("naive", "ols_logit_within", o, weight="naive", stage="regression", view="analysis/marginal",
             note="zero-click hours clipped to logit(1e-6), all hours weighted equally",
             extra="agrees with the GLM" if agree else "disagrees with the GLM")

    # ── curve fitting ───────────────────────────────────────────────────────
    cv = res["curves"]["models"]
    best = next((m for m in cv if m.get("best")), None)
    failed = [m["model"] for m in cv if m.get("failed")]
    out = (f"best AIC: {best['model']} (R²={best['r2']:.3f})" if best and best.get("r2") is not None
           else f"best AIC: {best['model']}" if best else "no valid fit")
    if failed:
        out += f" · no valid solution: {', '.join(failed)}"
    c.add("curves", "best_fit", out, hyp=best.get("key") if best else None, weight="illustrative",
          stage="curves", view="analysis/curves", note="5 bucket means — illustrative only",
          detail=[[m["model"], "failed" if m.get("failed") else f"AIC={m.get('aic')}  R²={m.get('r2')}"] for m in cv])

    # ── robustness ──────────────────────────────────────────────────────────
    rb = res["robustness"]
    for r in rb["size"]:
        c.effect("robust-size", _slug(r["Quartile"]), _glm(r), stage="robustness", view="analysis/forest",
                 weight="few clusters", note=f"{r.get('N campaigns')} clusters — cluster-robust p approximate",
                 extra=f"{r.get('N campaigns')} campaigns, {r.get('N obs'):,} obs")
    for r in rb["temporal"]:
        c.effect("robust-time", _slug(r["Period"]), _glm(r), stage="robustness", view="analysis/forest",
                 extra=r.get("Date range"))
    for r in rb["threshold"]:
        c.effect("robust-threshold", _slug(r["Filter"]), _glm(r), stage="robustness", view="analysis/threshold",
                 extra=f"zero-click {r['Zero-click share (all)'] * 100:.1f}% · OLS β₁={r.get('OLS-logit β₁'):+.4f}"
                 if r.get("Zero-click share (all)") is not None and r.get("OLS-logit β₁") is not None else None)
    for r in rb["spec"]:
        c.effect("robust-spec", _spec_name(r["Specification"]), {"b": r.get("β₁"), "lo": r.get("ci_lo"),
                 "hi": r.get("ci_hi"), "p": r.get("p")}, stage="robustness", view="analysis/forest",
                 weight=_spec_weight(r.get("Role")), label=r.get("Role"), extra=r.get("Specification"))

    # ── dataset ─────────────────────────────────────────────────────────────
    notes = []
    if ds.get("n_unmatched_banners"):
        notes.append(f"{ds['n_unmatched_banners']:,} event rows without campaign mapping dropped")
    if ds.get("dead_campaigns"):
        notes.append(f"{ds['dead_campaigns']} campaign(s) with 0 clicks over whole period excluded "
                     "(click tracking failure / non-clickable placement)")
    kept = ds["n_final"] / ds["n_after_agg"] * 100 if ds.get("n_after_agg") else None
    c.add("dataset", "ingest",
          f"{ds['n_raw']:,} raw rows → {ds['n_final']:,} campaign-hours"
          f"{f' ({kept:.1f}% of aggregated)' if kept is not None else ''} · {ds['n_campaigns']} campaigns · {ds['date_range']}",
          info=True, note="; ".join(notes) or None, stage="load", view="overview",
          perfdata=perf(rows_raw=ds["n_raw"], rows_final=ds["n_final"], campaigns=ds["n_campaigns"]),
          detail=[[e["label"], f"{e['n']:,}"] for e in ds.get("exclusions", [])])
    zc = fnum(ds.get("zero_click_share"))
    c.add("dataset", "zero_click_hours",
          f"zero-click share {zc * 100:.1f}% of campaign-hours · drives the naive-OLS bias (see §4.6d)"
          if zc is not None else "zero-click share not computable",
          info=True, stage="load", view="graphs", perfdata=perf(zero_click_share=zc))
    if ds.get("n_ctr_outliers") is not None:
        c.add("dataset", "ctr_outliers", f"{ds['n_ctr_outliers']:,} campaign-hours with CTR > 20% — flagged, not removed",
              info=True, stage="load", view="campaigns", perfdata=perf(flagged=ds["n_ctr_outliers"]))

    # ── pipeline ────────────────────────────────────────────────────────────
    n_fig = len(res.get("figures") or [])
    c.add("pipeline", "figures",
          f"{n_fig} publication figure(s) rendered (PDF + PNG preview)"
          + (f", {len(figure_errors)} failed: " + ", ".join(f"{k} ({v})" for k, v in figure_errors.items())
             if figure_errors else ""),
          info=True, note="some figures failed" if figure_errors else None, stage="figures", view="files",
          perfdata=perf(figures=n_fig))
    total = sum(v for v in (stage_times or {}).values() if v)
    c.add("pipeline", "runtime", f"pipeline completed in {total:.1f}s across {len(stage_times or {})} stages",
          info=True, perfdata=perf(seconds=total), detail=[[k, f"{v:.2f}s"] for k, v in (stage_times or {}).items()])

    rows = c.rows
    tally = {h: sum(1 for r in rows if r["hyp"] == h and r["supported"]) for h in HYPS}
    tally["info"] = sum(1 for r in rows if r["kind"] == "info")
    primary = next((r["hyp"] for r in rows if r["id"] == "glm/within_slope"), None)
    if h2:
        primary = "H2"
    groups = []
    for g, (name, desc) in GROUPS.items():
        gr = [r for r in rows if r["host"] == g]
        if gr:
            groups.append({"id": g, "name": name, "desc": desc,
                           "tally": {h: sum(1 for r in gr if r["hyp"] == h and r["supported"]) for h in HYPS}})
    return {"services": rows, "tally": tally, "primary": primary, "groups": groups,
            "n_hypothesis": sum(1 for r in rows if r["kind"] == "hypothesis")}


def _glm(r):
    return {"b": r.get("GLM β₁"), "lo": r.get("glm_ci_lo"), "hi": r.get("glm_ci_hi"), "p": r.get("GLM p")}


def _spec_weight(role):
    role = str(role or "")
    if role.startswith("PRIMARY"):
        return "primary"
    if role.startswith("TOTAL"):
        return "pooled"
    if "naive" in role.lower():
        return "naive"
    if "SE only" in role:
        return "SE only"
    if "weighted" in role.lower():
        return "weighted"
    return None


def _slug(s):
    s = re.sub(r"[^0-9A-Za-z>=<]+", "_", str(s)).strip("_").lower()
    return s.replace(">=", "ge").replace("<", "lt").replace(">", "gt").replace("=", "")[:60]


def _spec_name(spec):
    """'Binomial GLM (logit), campaign FE + time FE, clustered SE' → 'glm_campFE+timeFE_cluster'."""
    s = str(spec)
    est = "wls" if s.startswith("WLS") else "glm" if "GLM" in s else "ols" if "OLS" in s else "model"
    fe = ("campFE+timeFE" if "campaign FE + time FE" in s else "timeFE" if "time FE only" in s
          else "campFE" if "campaign FE only" in s else "fe")
    se = "hc3" if "HC3" in s else "cluster" if "clustered" in s else "se"
    return f"{est}_{fe}_{se}"


SIZE_LABELS = ["Q1 (smallest)", "Q2", "Q3", "Q4 (largest)"]


def size_quartiles(res):
    """Campaign → size quartile, by the same rule as the script's assign_size_quartiles()
    (qcut of each campaign's median hourly impressions), joined to that quartile's §4.6a
    estimates. Adds `size_q` to every campaign row; returns one summary per quartile."""
    import pandas as pd

    camps = (res.get("between") or {}).get("campaigns") or []
    if not camps:
        return None
    med = pd.Series([c.get("median_impr") for c in camps], index=[c["campaign"] for c in camps], dtype=float)
    try:
        q = pd.qcut(med, q=4, labels=SIZE_LABELS, duplicates="drop")
    except ValueError:  # too many tied medians for four bins — the script would fail here too
        return None
    for c in camps:
        lab = q.get(c["campaign"])
        c["size_q"] = lab.split(" ")[0] if isinstance(lab, str) else None
    est = {r.get("Quartile"): r for r in (res.get("robustness") or {}).get("size", [])}
    out = []
    for lab in SIZE_LABELS:
        r = est.get(lab)
        glm = {"b": fnum(r.get("GLM β₁")), "lo": fnum(r.get("glm_ci_lo")), "hi": fnum(r.get("glm_ci_hi")),
               "p": fnum(r.get("GLM p"))} if r else None
        ols = {"b": fnum(r.get("OLS-logit β₁")), "p": fnum(r.get("OLS p"))} if r else None
        out.append({
            "label": lab, "short": lab.split(" ")[0], "n_campaigns": int((q == lab).sum()),
            "tested": r is not None,  # the script skips quartiles with < 30 campaign-hours
            "hyp": hyp_of(glm["b"], glm["p"]) if glm else None, "glm": glm,
            "ols_hyp": hyp_of(ols["b"], ols["p"]) if ols else None, "ols": ols,
            "n_obs": r.get("N obs") if r else None, "median_impr": fnum(r.get("Median impr/hr")) if r else None,
            "zero_click_share": fnum(r.get("Zero-click share")) if r else None,
        })
    return out
__CTRMON_EOF__
w 'backend/app/config.py' <<'__CTRMON_EOF__'
import os
from pathlib import Path


def _int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


DATA_DIR = Path(os.environ.get("CTR_DATA_DIR", Path(__file__).resolve().parents[2] / "data"))
RUNS_DIR = DATA_DIR / "runs"
SCRIPT_PATH = Path(os.environ.get("CTR_SCRIPT", Path(__file__).resolve().parents[2] / "ctr_analysis.py"))
STATIC_DIR = Path(os.environ.get("CTR_STATIC_DIR", Path(__file__).resolve().parents[1] / "static"))

MAX_CONCURRENT_RUNS = max(1, _int("CTR_MAX_CONCURRENT_RUNS", 1))
MAX_UPLOAD_MB = _int("CTR_MAX_UPLOAD_MB", 2048)
WEB_DPI = _int("CTR_WEB_DPI", 110)          # PNG previews of the publication figures
SCATTER_SAMPLE = _int("CTR_SCATTER_SAMPLE", 4000)  # raw points shipped to the browser for fig4

# accepted upload suffixes — pandas infers compression from the extension
UPLOAD_SUFFIXES = (".csv", ".txt", ".csv.gz", ".csv.bz2", ".csv.xz", ".csv.zip",
                   ".gz", ".bz2", ".xz", ".zip")
__CTRMON_EOF__
w 'backend/app/jobs.py' <<'__CTRMON_EOF__'
"""Run queue: one dispatcher thread launches worker subprocesses (max N at a time)."""
import logging
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path

from . import config, store

log = logging.getLogger("ctr.jobs")
BACKEND_DIR = Path(__file__).resolve().parents[1]


class Dispatcher:
    def __init__(self):
        self.procs = {}
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self._started = False

    # ── lifecycle ──────────────────────────────────────────────────────────
    def start(self):
        with self.lock:
            if self._started:
                return
            self._started = True
        config.RUNS_DIR.mkdir(parents=True, exist_ok=True)
        for m in store.list_runs():
            if m.get("status") == "running":
                store.update_meta(m["id"], status="failed", finished=store.now_iso(),
                                  error="interrupted — the server restarted while this run was in progress")
        threading.Thread(target=self._loop, name="ctr-dispatcher", daemon=True).start()
        self.wake.set()

    def submit(self, run_id):
        self.wake.set()

    def cancel(self, run_id):
        with self.lock:
            meta = store.read_meta(run_id) or {}
            if meta.get("status") not in store.ACTIVE:
                return False
            store.update_meta(run_id, status="cancelled", finished=store.now_iso(), error="cancelled by user")
            p = self.procs.get(run_id)
            if p and p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            return True

    # ── loop ───────────────────────────────────────────────────────────────
    def _loop(self):
        idle = 0
        while True:
            woke = self.wake.wait(0.5)
            self.wake.clear()
            idle = 0 if woke else idle + 1
            try:
                self._reap()
                if woke or idle % 10 == 0:
                    self._launch_queued()
            except Exception:  # keep the dispatcher alive no matter what
                log.exception("dispatcher tick failed")

    def _reap(self):
        with self.lock:
            for rid, p in list(self.procs.items()):
                rc = p.poll()
                if rc is None:
                    continue
                del self.procs[rid]
                self._finalize(rid, rc)
                self.wake.set()  # a slot freed up

    def _launch_queued(self):
        with self.lock:
            free = config.MAX_CONCURRENT_RUNS - len(self.procs)
            if free <= 0:
                return
            queued = sorted((m for m in store.list_runs() if m.get("status") == "queued"),
                            key=lambda m: m.get("created", ""))
            for m in queued[:free]:
                self._launch(m["id"])

    def _launch(self, rid):
        d = store.run_dir(rid)
        logf = open(d / "run.log", "ab")
        try:
            p = subprocess.Popen(
                [sys.executable, "-u", "-m", "app.worker", str(d)], cwd=BACKEND_DIR,
                stdout=logf, stderr=subprocess.STDOUT, start_new_session=True,
                env={**os.environ, "MPLBACKEND": "Agg", "PYTHONUNBUFFERED": "1"})
        finally:
            logf.close()
        self.procs[rid] = p
        store.update_meta(rid, status="running", started=store.now_iso(), pid=p.pid)
        log.info("run %s started (pid %s)", rid, p.pid)

    def _finalize(self, rid, rc):
        d = store.run_dir(rid)
        meta = store.read_meta(rid) or {}
        if meta.get("status") == "cancelled":
            return
        result = store.read_json(d / "result.json")
        if rc == 0 and result:
            checks = result.get("checks") or {}
            store.update_meta(rid, status="ok", finished=store.now_iso(), tally=checks.get("tally"),
                              primary=checks.get("primary"), mode=result.get("mode"), headline=_headline(result))
            log.info("run %s finished", rid)
            return
        err = store.read_json(d / "error.json") or {}
        msg = err.get("message") or describe_exit(d, rc)
        store.update_meta(rid, status="failed", finished=store.now_iso(), exit_code=rc,
                          error=f"{err.get('type', 'Error')}: {msg}" if err else msg)
        log.warning("run %s failed: %s", rid, msg)


def describe_exit(d, rc):
    """Why a worker died without writing error.json (i.e. it was killed, not a Python exception)."""
    prog = store.read_json(d / "progress.json") or {}
    stage = next((s["label"] for s in prog.get("stages", []) if s["key"] == prog.get("current")), prog.get("current"))
    where = f" during “{stage}”" if stage else ""
    peak = prog.get("peak_gb")
    seen = f" (worker had reached {peak:.1f} GB)" if isinstance(peak, (int, float)) else ""
    if rc == -9:
        return (f"Out of memory: the worker was killed by the system (SIGKILL){where}{seen}. "
                "Give Docker more memory (Docker Desktop → Settings → Resources) and re-run.")
    if rc is not None and rc < 0:
        return f"The worker was terminated by signal {-rc}{where}."
    text, _ = store.tail(d / "run.log", 4000)
    last = (text.strip().splitlines() or [""])[-1]
    return f"The worker exited with code {rc}{where}" + (f": {last}" if last and not last.startswith("──") else ".")


def _headline(result):
    try:
        reg, ds = result["regression"], result["dataset"]
        return {"b_within": reg["within"]["b"], "p_within": reg["within"]["p"],
                "b_total": reg["total"]["b"], "p_total": reg["total"]["p"],
                "n_final": ds["n_final"], "n_campaigns": ds["n_campaigns"], "date_range": ds["date_range"]}
    except (KeyError, TypeError):
        return None


dispatcher = Dispatcher()
__CTRMON_EOF__
w 'backend/app/jsonsafe.py' <<'__CTRMON_EOF__'
import math
from datetime import date, datetime

import numpy as np
import pandas as pd


def clean(x):
    """Recursively convert numpy/pandas values to strict-JSON-safe Python (NaN/inf → None)."""
    if isinstance(x, dict):
        return {str(k): clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple, set)):
        return [clean(v) for v in x]
    if isinstance(x, pd.DataFrame):
        return clean(x.to_dict("records"))
    if isinstance(x, pd.Series):
        return clean(x.to_dict())
    if isinstance(x, np.ndarray):
        return clean(x.tolist())
    if isinstance(x, (pd.Timestamp, datetime, date)):
        return None if pd.isna(x) else x.isoformat()
    if isinstance(x, (np.bool_, bool)):
        return bool(x)
    if isinstance(x, (np.integer,)):
        return int(x)
    if isinstance(x, (np.floating, float)):
        f = float(x)
        return f if math.isfinite(f) else None
    if x is None or x is pd.NA or x is pd.NaT:
        return None
    if isinstance(x, (str, int)):
        return x
    try:
        if pd.isna(x):
            return None
    except (TypeError, ValueError):
        pass
    return str(x)


def fnum(x):
    """float or None."""
    try:
        f = float(x)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None
__CTRMON_EOF__
w 'backend/app/memfix.py' <<'__CTRMON_EOF__'
"""Memory fixes applied in the worker process only — ctr_analysis.py itself is untouched.

statsmodels' GLM IRLS builds a whitened copy of the design matrix every iteration
(`_MinimalWLS.wexog`). The per-iteration result is a `Bunch`, a dict whose `__dict__`
is itself — a reference cycle that also holds the model and so that copy. Cycles are
freed only when Python's cycle collector runs, which it rarely does during a few huge
allocations, so every iteration's copy stays alive until the fit ends. With campaign
dummies that is (rows × campaigns × 8 bytes) per iteration: ~1.4 GB × 28 for n1985.

A full collection once per IRLS iteration frees them as soon as they are unreachable
(milliseconds per call against minutes per fit). Estimates are unchanged (pure memory management).
"""
import gc
import resource
import sys


def free_irls_garbage():
    from statsmodels.genmod import generalized_linear_model as glm

    original = glm.GLM._update_history
    if getattr(original, "_ctr_memfix", False):
        return

    def _update_history(self, tmp_result, mu, history):
        # full collection: the previous iteration's Bunch was still reachable at the last pass, so it has
        # been promoted to the oldest generation, which a partial collect(0/1) never looks at
        gc.collect()
        return original(self, tmp_result, mu, history)

    _update_history._ctr_memfix = True
    glm.GLM._update_history = _update_history


def peak_rss_gb():
    """Peak resident memory of this process so far, in GB (ru_maxrss is KB on Linux, bytes on macOS)."""
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return round(r / (1024 ** 3 if sys.platform == "darwin" else 1024 ** 2), 2)
__CTRMON_EOF__
w 'backend/app/narrative.py' <<'__CTRMON_EOF__'
"""Plain-language 3–5 sentence reading of a structured result.

Fixed rules over the run's numbers — no model, nothing invented. Every claim maps to a
number in result.json; sentences whose inputs are missing are dropped. Kept deliberately
light on statistics: the exact estimates sit right below it in results_summary.txt.
"""
import math
import re
from datetime import date

ALPHA = 0.05
MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()


def _num(*xs):
    return all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in xs)


def _sig(b, p):
    if not _num(b, p):
        return None
    return "null" if p >= ALPHA else ("neg" if b < 0 else "pos")


def _big(n):
    if n >= 1e9:
        return f"{n / 1e9:.1f} billion"
    if n >= 1e6:
        return f"{n / 1e6:.0f} million" if n >= 1e7 else f"{n / 1e6:.1f} million"
    return f"{n:,.0f}"


def _round_volume(v):
    mag = 10 ** max(0, int(math.floor(math.log10(v))) - 1)
    return f"{round(v / mag) * mag:,.0f}"


def _dates(ds):
    try:
        a, b = (date.fromisoformat(str(ds[k])[:10]) for k in ("date_min", "date_max"))
    except (KeyError, TypeError, ValueError):
        return ds.get("date_range", "")
    if a.year == b.year:
        return f"{a.day} {MONTHS[a.month - 1]} – {b.day} {MONTHS[b.month - 1]} {b.year}"
    return f"{a.day} {MONTHS[a.month - 1]} {a.year} – {b.day} {MONTHS[b.month - 1]} {b.year}"


def _ctr_change(beta, base):
    """Relative CTR change for a doubling of hourly impressions implied by a logit slope, at baseline CTR `base`."""
    odds = math.exp(beta * math.log(2))
    return (odds / (1 - base + base * odds) - 1) * 100


def narrate(res):
    if not res or res.get("mode") != "structured":
        return None
    ds, reg = res["dataset"], res["regression"]
    w, tot, ols, q = reg["within"], reg["total"], reg["ols"]["m1"], reg["quadratic"]
    tz = ds.get("totals") or {}
    base = tz["clicks"] / tz["impr"] if tz.get("impr") else None
    s = []

    # 1 — what was analysed
    if _num(ds.get("n_final"), base):
        s.append(f"We looked at {ds['n_final']:,} campaign-hours from {ds['n_campaigns']} campaigns ({_dates(ds)}), "
                 f"with {_big(tz['impr'])} impressions and an average CTR of {base * 100:.2f}%.")

    # 2 — the main answer: does more volume change a campaign's own CTR?
    kind = _sig(w.get("b"), w.get("p"))
    headline, hyp = "Result not computable", None
    if kind and base is not None:
        r = abs(_ctr_change(w["b"], base))
        if kind == "null":
            t = ("The main finding: when a campaign serves more impressions in an hour, its CTR does not measurably "
                 f"change — doubling hourly volume moves CTR by only about {r:.0f}%, well within the range of chance")
            headline, hyp = "No sign that more volume lowers a campaign's CTR", "H4"
        elif kind == "neg":
            t = ("The main finding: when a campaign serves more impressions in an hour, its CTR goes down — doubling "
                 f"hourly volume lowers CTR by about {r:.0f}%, a statistically reliable drop consistent with ad fatigue")
            headline, hyp = "CTR falls as a campaign's hourly volume rises", "H1"
        else:
            t = ("The main finding: when a campaign serves more impressions in an hour, its CTR goes up — doubling "
                 f"hourly volume raises CTR by about {r:.0f}%, a statistically reliable increase")
            headline, hyp = "CTR rises with a campaign's hourly volume", "H3"
        b1, b2 = q["b1"].get("b"), q["b2"].get("b")
        if str(q.get("supports", "")).startswith("H2") and _num(b1, b2) and b2 < 0:
            t += (f"; looked at more closely, the curve is an inverted U, with CTR peaking around "
                  f"{_round_volume(math.exp(-b1 / (2 * b2)))} impressions per hour")
            headline, hyp = "CTR peaks at moderate hourly volume (inverted U)", "H2"
        s.append(t + ".")

    # 3 — between campaigns vs within (composition)
    bc = res.get("between", {}).get("stats", {})
    rho, prho = bc.get("spearman_rho"), bc.get("spearman_p")
    if reg.get("decomposition", {}).get("expected"):
        s.append("The overall drop in CTR you see when all campaigns are pooled comes from the campaign mix — "
                 "high-volume campaigns simply have lower CTR — not from volume hurting any single campaign.")
    elif _num(rho, prho) and prho < ALPHA:
        t = f"Campaigns that run at higher volume do tend to have {'lower' if rho < 0 else 'higher'} CTR than smaller ones"
        s.append(t + (", but that reflects differences between the campaigns themselves, not an effect of volume."
                      if kind == "null" else "."))
    elif _num(rho, prho):
        s.append("Across campaigns, size and CTR are not clearly related.")

    # 4 — the naive model, only when it points somewhere the GLM does not
    ok_ = _sig(ols.get("b"), ols.get("p"))
    if ok_ in ("neg", "pos") and kind and ok_ != kind:
        t = f"A simpler, unweighted model would suggest CTR {'falls' if ok_ == 'neg' else 'rises'} with volume"
        thr = [x for x in res["robustness"].get("threshold", []) if re.fullmatch(r"impr >= \d+", str(x.get("Filter")))]
        last = max(thr, key=lambda x: int(re.search(r"\d+", x["Filter"]).group())) if thr else None
        if last and _sig(last.get("OLS-logit β₁"), last.get("OLS p")) != ok_:
            t += ", but that signal disappears once hours with very few impressions are left out, so it shouldn't be trusted."
        else:
            t += ", but the more appropriate impression-weighted model doesn't confirm it."
        s.append(t)

    # 5 — robustness across segments (GLM re-estimates on subsets)
    rows = (res["robustness"].get("size", []) + res["robustness"].get("temporal", [])
            + res["robustness"].get("threshold", []))
    cls = [k for k in (_sig(x.get("GLM β₁"), x.get("GLM p")) for x in rows) if k]
    if cls and kind:
        n, neg, pos = len(cls), cls.count("neg"), cls.count("pos")
        if kind == "null" and not neg and not pos:
            s.append("The main finding holds across campaign-size groups, both halves of the period and stricter volume cut-offs.")
        elif kind == "null":
            if neg and pos:
                s.append(f"Splitting the data by campaign size, time period or volume cut-off gives mixed results "
                         f"({neg} of {n} slices show a decline, {pos} an increase), so there's no consistent pattern.")
            else:
                s.append(f"A few slices of the data ({neg or pos} of {n}, by campaign size, time period or volume cut-off) "
                         f"do show {'a decline' if neg else 'an increase'}, so it can't be ruled out for some campaigns.")
        elif cls.count(kind) == n:
            s.append("The main finding holds across campaign-size groups, both halves of the period and stricter volume cut-offs.")
        elif cls.count(kind) >= 0.75 * n:
            s.append(f"The main finding holds in most slices of the data ({cls.count(kind)} of {n}, by campaign size, "
                     "time period or volume cut-off).")
        else:
            s.append(f"The main finding is not uniform, though: only {cls.count(kind)} of {n} slices of the data "
                     "(by campaign size, time period or volume cut-off) show it clearly.")

    return {"headline": headline, "hyp": hyp, "sentences": s, "text": " ".join(s),
            "note": "Generated by fixed rules from this run's numbers, not by ctr_analysis.py. CTR changes are "
                    "relative (e.g. 2.0% → 2.1% is +5%), evaluated at the average CTR."}
__CTRMON_EOF__
w 'backend/app/pipeline.py' <<'__CTRMON_EOF__'
"""Structured wrapper around the drop-in ctr_analysis.py.

Mirrors the script's main() step for step — same function calls, same output
files in out/ — but keeps the in-memory results so the web UI can render them
natively. The script itself is never modified; its `save` and `_caption` hooks
are wrapped to also emit PNG previews and record figure captions.
"""
import importlib.util
import re
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import numpy as np
import pandas as pd

from . import config
from .checks import build_checks
from .jsonsafe import clean, fnum
from .memfix import peak_rss_gb
from .store import write_json

STAGES = [
    ("load", "Loading & cleaning"),
    ("descriptive", "Descriptive statistics"),
    ("trend", "Trend tests"),
    ("regression", "Regression (GLM primary + total + naive OLS)"),
    ("curves", "Curve fitting"),
    ("robustness", "Robustness checks"),
    ("between", "Between-campaign analysis"),
    ("figures", "Generating figures"),
    ("summary", "Writing results summary"),
    ("webdata", "Preparing web views"),
]
LEGACY_STAGES = [("legacy", "Running script main() (legacy mode)"), ("webdata", "Collecting outputs")]


def load_script(path):
    spec = importlib.util.spec_from_file_location("ctr_analysis", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ctr_analysis"] = mod
    spec.loader.exec_module(mod)
    return mod


class Progress:
    def __init__(self, run_dir, stages):
        self.path, self.stages, self.times, self.current = Path(run_dir) / "progress.json", stages, {}, None
        self.mem = {}   # peak resident memory (GB) of the worker after each stage
        self._lock = threading.Lock()
        self._written_peak = None
        self._write()
        # keep peak memory current during long stages (and right up to an out-of-memory kill)
        threading.Thread(target=self._watch_memory, name="progress-mem", daemon=True).start()

    def _watch_memory(self):
        while True:
            time.sleep(3)
            if self._written_peak is None or peak_rss_gb() - self._written_peak >= 0.1:
                self._write()

    def _write(self):
        keys = [k for k, _ in self.stages]
        with self._lock:
            self._written_peak = peak_rss_gb()
            write_json(self.path, {"stages": [{"key": k, "label": l} for k, l in self.stages],
                                   "current": self.current,
                                   "index": keys.index(self.current) if self.current in keys else len(self.times),
                                   "times": dict(self.times), "mem": dict(self.mem), "peak_gb": self._written_peak})

    @contextmanager
    def stage(self, key):
        label = dict(self.stages)[key]
        print(f"\n── {label} " + "─" * max(3, 58 - len(label)), flush=True)
        self.current = key
        self._write()
        t0 = time.perf_counter()
        yield
        self.times[key] = round(time.perf_counter() - t0, 3)
        self.mem[key] = peak_rss_gb()
        self.current = None
        self._write()


# ═════════════════════════════════════════════════════════════════════════════
# helpers
# ═════════════════════════════════════════════════════════════════════════════

def camp_key(x):
    """Campaign ids come back as float after the left merge (1234.0) — show them as ints."""
    if isinstance(x, (float, np.floating)) and np.isfinite(x) and float(x).is_integer():
        return str(int(x))
    return str(x)


def parse_ci(s):
    nums = re.findall(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|nan", str(s))
    if len(nums) < 2:
        return None, None
    return fnum(nums[0]), fnum(nums[1])


def coef(ca, m, name="log_v"):
    b, lo, hi, p = ca.coef_summary(m, name)
    return {"b": fnum(b), "lo": fnum(lo), "hi": fnum(hi), "p": fnum(p)}


def dbl(b):
    return fnum(np.exp(b * np.log(2))) if fnum(b) is not None else None


def table_records(df):
    return clean(df.to_dict("records"))


# ═════════════════════════════════════════════════════════════════════════════
# structured run
# ═════════════════════════════════════════════════════════════════════════════

def run_structured(ca, run_dir, mapping, events, min_impr, dpi):
    run_dir = Path(run_dir)
    out = run_dir / "out"
    out.mkdir(parents=True, exist_ok=True)
    pg = Progress(run_dir, STAGES)

    ca.MIN_IMPRESSIONS = int(min_impr)          # main() does the same via `global`
    figures, fig_errors = [], {}
    _save, _caption = ca.save, getattr(ca, "_caption", lambda note: print(f"     ↳ {note}"))

    def save(fig, path, dpi_):
        path = Path(path)
        png = path.with_suffix(".png")
        try:
            fig.savefig(png, dpi=config.WEB_DPI, bbox_inches="tight")
        except Exception as e:  # preview only — never fail the run over it
            print(f"  [WARN] PNG preview failed for {path.name}: {e}")
        _save(fig, path, dpi_)
        figures.append({"name": path.stem, "file": path.name,
                        "png": png.name if png.exists() else None, "caption": None})

    def caption(note):
        if figures:
            figures[-1]["caption"] = note
        _caption(note)

    ca.save, ca._caption = save, caption

    with pg.stage("load"):
        df, df_pre, log = ca.load_and_clean(str(mapping), str(events))
        print(f"  {log['n_final']:,} records | {log['n_campaigns']:,} campaigns | {log['date_range']}")
        if log["n_final"] == 0:
            raise RuntimeError("no rows left after cleaning — check the input files and --min-impr")

    with pg.stage("descriptive"):
        desc = ca.descriptive_stats(df)
        desc.to_csv(out / "table2_descriptive.csv", index=False)

    with pg.stage("trend"):
        ca_t, sp = ca.cochran_armitage(df), ca.spearman_test(df)
        pd.DataFrame([{**{f"CA_{k}": v for k, v in ca_t.items()}, **{f"Sp_{k}": v for k, v in sp.items()}}]
                     ).to_csv(out / "table3_trend_tests.csv", index=False)

    with pg.stage("regression"):
        reg = ca.run_regression(df)
        for tag, m in (("table4_glm_within_linear.csv", reg["m1"]), ("table4b_glm_within_quadratic.csv", reg["m2"]),
                       ("table4t_glm_total_linear.csv", reg["m_total"]),
                       ("table4c_ols_logit_linear.csv", reg["ols_m1"]), ("table4d_ols_logit_quadratic.csv", reg["ols_m2"])):
            pd.DataFrame({"predictor": m.params.index, "coef": m.params.values, "ci_lo": m.conf_int()[0].values,
                          "ci_hi": m.conf_int()[1].values, "p": m.pvalues.values}).to_csv(out / tag, index=False)

    with pg.stage("curves"):
        curve_tbl, bkt_df = ca.fit_curves(df)
        curve_tbl.to_csv(out / "table5_curve_fitting.csv", index=False)

    with pg.stage("robustness"):
        rb_size = ca.robustness_by_size(df)
        rb_spec = ca.robustness_specifications(df, reg)
        rb_time = ca.robustness_temporal(df)
        sens = ca.robustness_threshold_sensitivity(df_pre)
        rb_size.to_csv(out / "table6_robustness_size.csv", index=False)
        rb_spec.to_csv(out / "table7_robustness_spec.csv", index=False)
        rb_time.to_csv(out / "table8_robustness_time.csv", index=False)
        sens.to_csv(out / "table11_threshold_sensitivity.csv", index=False)

    with pg.stage("between"):
        camp, bc = ca.between_campaign_analysis(df)
        camp.to_csv(out / "table12_campaign_level.csv", index=False)
        pd.DataFrame([bc]).to_csv(out / "table12b_between_campaign_fit.csv", index=False)

    with pg.stage("figures"):
        for name, fn in (("fig1_boxplots", lambda: ca.fig1_boxplots(df, out, dpi)),
                         ("fig2_mean_ctr_ci", lambda: ca.fig2_mean_ci(df, out, dpi)),
                         ("fig3_hourly_pattern", lambda: ca.fig3_hourly(df, out, dpi)),
                         ("fig4_marginal_effect", lambda: ca.fig4_marginal(df, reg, out, dpi)),
                         ("fig5_curve_fitting", lambda: ca.fig5_curves(df, curve_tbl, bkt_df, out, dpi)),
                         ("fig6_between_campaign", lambda: ca.fig6_between_campaign(camp, bc, reg, out, dpi)),
                         ("fig7_threshold_sensitivity", lambda: ca.fig7_threshold_sensitivity(sens, out, dpi))):
            try:
                fn()
            except Exception as e:
                fig_errors[name] = f"{type(e).__name__}: {e}"
                print(f"  [WARN] {name} failed: {fig_errors[name]}")
            finally:
                import matplotlib.pyplot as plt
                plt.close("all")

    with pg.stage("summary"):
        ca.write_summary(out / "results_summary.txt", log, desc, ca_t, sp, reg, curve_tbl,
                         rb_size, rb_spec, rb_time, sens, bc)

    with pg.stage("webdata"):
        res = build_results(ca, df, df_pre, log, desc, ca_t, sp, reg, curve_tbl, bkt_df,
                            rb_size, rb_spec, rb_time, sens, camp, bc)
        res["figures"] = figures
        res["files"] = list_outputs(out)
        save_panel(run_dir, df_pre)
        res["figure_errors"] = fig_errors
        res["checks"] = build_checks(res, pg.times, fig_errors)
        res["mode"] = "structured"
        res["stage_times"] = pg.times
        write_json(run_dir / "result.json", clean(res))
    print(f"\n✅  Done. Results saved to: {out}\n", flush=True)


def run_legacy(ca, run_dir, mapping, events, min_impr, dpi):
    """Script lacks the functions the structured wrapper needs → run its own main()."""
    run_dir = Path(run_dir)
    out = run_dir / "out"
    out.mkdir(parents=True, exist_ok=True)
    pg = Progress(run_dir, LEGACY_STAGES)
    figures = []
    if hasattr(ca, "save"):
        _save = ca.save

        def save(fig, path, dpi_):
            path = Path(path)
            try:
                fig.savefig(path.with_suffix(".png"), dpi=config.WEB_DPI, bbox_inches="tight")
            except Exception:
                pass
            _save(fig, path, dpi_)
            figures.append({"name": path.stem, "file": path.name, "png": path.with_suffix(".png").name, "caption": None})

        ca.save = save
    with pg.stage("legacy"):
        sys.argv = ["ctr_analysis.py", "--mapping", str(mapping), "--events", str(events),
                    "--out", str(out), "--dpi", str(dpi), "--min-impr", str(min_impr)]
        ca.main()
    with pg.stage("webdata"):
        write_json(run_dir / "result.json", clean({"mode": "legacy", "figures": figures,
                                                   "files": list_outputs(out), "stage_times": pg.times}))


def list_outputs(out):
    files = []
    for p in sorted(Path(out).iterdir()):
        if p.is_file():
            kind = {".csv": "table", ".pdf": "figure", ".png": "preview", ".txt": "summary"}.get(p.suffix, "other")
            files.append({"name": p.name, "kind": kind, "size": p.stat().st_size})
    return files


def save_panel(run_dir, df_pre):
    """Hourly campaign panel for the MRTG graphs (after hard exclusions, before the min-impr filter)."""
    p = df_pre[["campaign", "hour", "impr", "clicks"]].copy()
    p["campaign"] = p["campaign"].map(camp_key)
    p["impr"] = p["impr"].astype("int64")
    p["clicks"] = p["clicks"].astype("int64")
    p.to_pickle(Path(run_dir) / "panel.pkl")


# ═════════════════════════════════════════════════════════════════════════════
# structured results for the UI
# ═════════════════════════════════════════════════════════════════════════════

def build_results(ca, df, df_pre, log, desc, ca_t, sp, reg, curve_tbl, bkt_df,
                  rb_size, rb_spec, rb_time, sens, camp, bc):
    m1, m2, mt = reg["m1"], reg["m2"], reg["m_total"]
    s1, s2, st = reg["m1_stats"], reg["m2_stats"], reg["m_total_stats"]
    w, tot = coef(ca, m1), coef(ca, mt)
    expected = (tot["p"] is not None and w["p"] is not None and tot["p"] < 0.05 and tot["b"] < 0 and w["p"] >= 0.05)

    dataset = {
        "n_raw": log["n_raw"], "n_banners": log["n_banners"], "n_campaigns": log["n_campaigns"],
        "n_after_agg": log["n_after_agg"], "n_final": log["n_final"], "date_range": log["date_range"],
        "date_min": df["hour"].min(), "date_max": df["hour"].max(),
        "zero_click_share": log["zero_click_share"], "dead_campaigns": log.get("dead_campaigns"),
        "n_unmatched_banners": log.get("n_unmatched_banners"),
        "n_ctr_outliers": int(df["ctr_outlier"].sum()) if "ctr_outlier" in df else None,
        "exclusions": [{"label": k, "n": int(v)} for k, v in log["exclusions"].items()],
        "impr_stats": log["impr_stats"].to_dict(), "ctr_stats": log["ctr_stats"].to_dict(),
        "min_impr": ca.MIN_IMPRESSIONS,
        "totals": {"impr": int(df["impr"].sum()), "clicks": int(df["clicks"].sum())},
    }

    regression = {
        "phi": s2["phi"],
        "within": {**w, "or_doubling": [dbl(w["b"]), dbl(w["lo"]), dbl(w["hi"])],
                   "pseudo_r2": s1["pseudo_r2"], "qaic": s1["qaic"], "aic": s1["aic"],
                   "nobs": int(m1.nobs), "k": s1["k"], "supports": reg["m1_supports"]},
        "quadratic": {"b1": coef(ca, m2), "b2": coef(ca, m2, "log_v_sq"), "pseudo_r2": s2["pseudo_r2"],
                      "qaic": s2["qaic"], "aic": s2["aic"], "dqaic": s2["qaic"] - s1["qaic"],
                      "daic": s2["aic"] - s1["aic"], "supports": reg["m2_supports"]},
        "total": {**tot, "or_doubling": [dbl(tot["b"]), dbl(tot["lo"]), dbl(tot["hi"])],
                  "pseudo_r2": st["pseudo_r2"], "phi": st["phi"], "nobs": int(mt.nobs)},
        "ols": {"m1": {**coef(ca, reg["ols_m1"]), "r2": float(reg["ols_m1"].rsquared),
                       "supports": reg["ols_m1_supports"]},
                "m2": {"b1": coef(ca, reg["ols_m2"]), "b2": coef(ca, reg["ols_m2"], "log_v_sq")}},
        "decomposition": {
            "b_total": tot["b"], "p_total": tot["p"], "b_within": w["b"], "p_within": w["p"],
            "diff": (tot["b"] - w["b"]) if tot["b"] is not None and w["b"] is not None else None,
            "expected": bool(expected),
            # verbatim from the script's §4.7 block
            "message": ("Aggregate decline is a between-campaign composition effect; within-campaign association is null."
                        if expected else "Check: pattern differs from the expected (β_total<0 sig., β_within≈0)."),
        },
    }

    # curve fits → model rows + smooth lines for the chart
    labels = {getattr(ca, "H1_LABEL", "H1"): ("H1", ca.h1_decay), getattr(ca, "H2_LABEL", "H2"): ("H2", ca.h2_inverted_u),
              getattr(ca, "H3_LABEL", "H3"): ("H3", ca.h3_saturating), getattr(ca, "H4_LABEL", "H4"): ("H4", ca.h4_null)}
    V = bkt_df["mean_logv"].values.astype(float)
    V_s = np.linspace(V.min(), V.max(), 120)
    models = []
    for _, r in curve_tbl.iterrows():
        key, fn = labels.get(r["Model"], (str(r["Model"])[:2], None))
        failed = r["Params"] == "failed"
        line = None
        if not failed and fn is not None:
            popt = [float(x) for x in str(r["Params"]).split(", ")]
            line = np.column_stack([V_s, fn(V_s, *popt)]).round(6).tolist()
        models.append({"key": key, "model": r["Model"], "params": r["Params"], "k": r.get("k"),
                       "r2": fnum(r.get("R²")), "rmse": fnum(r.get("RMSE")), "aic": fnum(r.get("AIC")),
                       "bic": fnum(r.get("BIC")), "best": bool(r.get("Best fit")), "failed": bool(failed),
                       "line": line})
    buckets = [{"bucket": int(b), "mean_logv": float(v), "mean_ctr": float(c) * 100}
               for b, v, c in zip(bkt_df["bucket_int"], bkt_df["mean_logv"], bkt_df["mean_ctr"])]

    # robustness tables + numeric CIs for the forest plot
    def with_ci(tbl, cols):
        recs = table_records(tbl)
        for r in recs:
            for src, lo_k, hi_k in cols:
                if src in r:
                    r[lo_k], r[hi_k] = parse_ci(r[src])
        return recs
    glm_ols = [("GLM 95% CI", "glm_ci_lo", "glm_ci_hi"), ("OLS 95% CI", "ols_ci_lo", "ols_ci_hi")]
    robustness = {"size": with_ci(rb_size, glm_ols), "temporal": with_ci(rb_time, glm_ols),
                  "threshold": with_ci(sens, glm_ols), "spec": with_ci(rb_spec, [("95% CI", "ci_lo", "ci_hi")])}

    return {
        "dataset": dataset,
        "descriptive": table_records(desc),
        "trend": {"cochran_armitage": ca_t, "spearman": sp},
        "regression": regression,
        "curves": {"models": models, "buckets": buckets},
        "robustness": robustness,
        "between": {"stats": bc, "campaigns": campaign_rows(camp, df)},
        "charts": chart_data(ca, df, reg, camp),
    }


def campaign_rows(camp, df):
    g = df.groupby("campaign")
    extra = pd.DataFrame({
        "first": g["hour"].min(), "last": g["hour"].max(),
        "outlier_hours": g["ctr_outlier"].sum() if "ctr_outlier" in df else 0,
        "zero_click_share": g["clicks"].apply(lambda s: float((s == 0).mean())),
        "median_impr": g["impr"].median(),
    })
    daily = (df.assign(day=df["hour"].dt.floor("D")).groupby(["campaign", "day"])[["clicks", "impr"]].sum())
    daily["ctr"] = daily["clicks"] / daily["impr"] * 100
    days = pd.date_range(df["hour"].min().floor("D"), df["hour"].max().floor("D"), freq="D")
    rows = []
    for _, r in camp.iterrows():
        c = r["campaign"]
        e = extra.loc[c]
        try:
            spark = daily.loc[c]["ctr"].reindex(days)
        except KeyError:
            spark = pd.Series(index=days, dtype=float)
        rows.append({"campaign": camp_key(c), "clicks": int(r["clicks"]), "impr": int(r["impr"]),
                     "n_obs": int(r["n_obs"]), "mean_logv": fnum(r["mean_logv"]), "ctr": fnum(r["ctr"] * 100),
                     "first": e["first"], "last": e["last"], "outlier_hours": int(e["outlier_hours"]),
                     "zero_click_share": fnum(e["zero_click_share"]), "median_impr": fnum(e["median_impr"]),
                     "spark": [fnum(v) for v in spark.values]})
    rows.sort(key=lambda r: -r["impr"])
    return rows


def chart_data(ca, df, reg, camp):
    labels = ["B1", "B2", "B3", "B4", "B5"]
    thresholds = list(getattr(ca, "BUCKET_THRESHOLDS", [0, 500, 2000, 10000, 50000, np.inf]))
    ranges = [[fnum(thresholds[i]), fnum(thresholds[i + 1])] for i in range(len(labels))]

    # fig1 — boxplots, y capped at the 99th percentile exactly like the script
    ctr_pct = df["ctr"].dropna() * 100
    cap = float(np.percentile(ctr_pct, 99))
    box = []
    for i, b in enumerate(labels):
        s = df.loc[df["bucket"] == b]
        v = np.clip(s["ctr"].dropna().values * 100, 0, cap)
        if len(v) == 0:
            box.append({"bucket": b, "n": 0, "range": ranges[i]})
            continue
        q1, med, q3 = np.percentile(v, [25, 50, 75])
        iqr = q3 - q1
        lo_w = v[v >= q1 - 1.5 * iqr].min()
        hi_w = v[v <= q3 + 1.5 * iqr].max()
        box.append({"bucket": b, "range": ranges[i], "n": int(len(v)), "q1": q1, "median": med, "q3": q3,
                    "whisker_lo": lo_w, "whisker_hi": hi_w, "n_fliers": int(((v < lo_w) | (v > hi_w)).sum()),
                    "mean": float(s["ctr"].mean() * 100), "zero_click_share": float((s["clicks"] == 0).mean()),
                    "impr": int(s["impr"].sum()), "clicks": int(s["clicks"].sum())})

    # fig2 — mean ± 1.96·SEM
    from scipy import stats as _st
    g = df.groupby("bucket", observed=True)["ctr"].agg(["mean", _st.sem, "count"]).reset_index()
    mean_ci = [{"bucket": str(r["bucket"]), "mean": r["mean"] * 100, "sem": r["sem"] * 100,
                "lo": (r["mean"] - 1.96 * r["sem"]) * 100, "hi": (r["mean"] + 1.96 * r["sem"]) * 100,
                "n": int(r["count"])} for _, r in g.iterrows()]

    # fig3 — hour-of-day profile
    h = df.groupby("hour_of_day").agg(mean_ctr=("ctr", "mean"), mean_impr=("impr", "mean"),
                                      clicks=("clicks", "sum"), impr=("impr", "sum")).reset_index()
    hourly = [{"hour": int(r["hour_of_day"]), "mean_ctr": r["mean_ctr"] * 100, "mean_impr": r["mean_impr"],
               "pooled_ctr": r["clicks"] / r["impr"] * 100 if r["impr"] else None} for _, r in h.iterrows()]

    # fig4 — marginal effect bands at the grand means (same construction as the script)
    ml, mlv = df["logit_ctr"].mean(), df["log_v"].mean()
    lv = np.linspace(df["log_v"].min(), df["log_v"].max(), 120)

    def band(m):
        b = m.params["log_v"]
        ci = m.conf_int().loc["log_v"].values
        p, lo, hi = (ca.inv_logit(ml + c * (lv - mlv)) * 100 for c in (b, ci[0], ci[1]))
        return {"p": p.round(5).tolist(), "lo": np.minimum(lo, hi).round(5).tolist(),
                "hi": np.maximum(lo, hi).round(5).tolist(), "beta": float(b)}
    glm_b, ols_b = band(reg["m1"]), band(reg["ols_m1"])
    ymax = min(30.0, float(np.nanmax(ols_b["hi"])) * 1.05)
    samp = df[["log_v", "ctr"]].dropna()
    if len(samp) > config.SCATTER_SAMPLE:
        samp = samp.sample(config.SCATTER_SAMPLE, random_state=0)
    marginal = {"lv": lv.round(5).tolist(), "glm": glm_b, "ols": ols_b, "ymax": ymax,
                "points": np.column_stack([samp["log_v"].values, samp["ctr"].values * 100]).round(4).tolist(),
                "n_points": int(len(df)), "n_shown": int(len(samp))}

    # fig6 — campaigns + total vs within slope
    b_w, b_t = float(reg["m1"].params["log_v"]), float(reg["m_total"].params["log_v"])
    x = camp["mean_logv"].values.astype(float)
    gm_logit, gm_x = float(camp["logit_ctr"].mean()), float(x.mean())
    xl = np.linspace(x.min(), x.max(), 100)
    between = {"b_within": b_w, "b_total": b_t,
               "total": np.column_stack([xl, ca.inv_logit(gm_logit + b_t * (xl - gm_x)) * 100]).round(5).tolist(),
               "within": np.column_stack([xl, ca.inv_logit(gm_logit + b_w * (xl - gm_x)) * 100]).round(5).tolist()}

    return {"box": {"cap": cap, "n_above": int((ctr_pct > cap).sum()), "buckets": box},
            "mean_ci": mean_ci, "hourly": hourly, "marginal": marginal, "between": between}
__CTRMON_EOF__
w 'backend/app/script_info.py' <<'__CTRMON_EOF__'
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
__CTRMON_EOF__
w 'backend/app/series.py' <<'__CTRMON_EOF__'
"""MRTG-style traffic windows from the hourly campaign panel."""
import threading
from collections import OrderedDict

import pandas as pd

from . import store
from .jsonsafe import fnum

# key, title, averaging label, span (None = whole range), bin
WINDOWS = [
    ("daily",   "`Daily' Graph",      "1 Hour Average", pd.Timedelta(hours=48), "1h"),
    ("weekly",  "`Weekly' Graph",     "2 Hour Average", pd.Timedelta(days=8),   "2h"),
    ("monthly", "`Monthly' Graph",    "6 Hour Average", pd.Timedelta(days=35),  "6h"),
    ("full",    "`Full Range' Graph", "1 Day Average",  None,                   "1D"),
]

_cache, _lock = OrderedDict(), threading.Lock()


def load_panel(run_id):
    p = store.run_dir(run_id) / "panel.pkl"
    key = (run_id, p.stat().st_mtime)
    with _lock:
        if key in _cache:
            _cache.move_to_end(key)
            return _cache[key]
    df = pd.read_pickle(p)
    with _lock:
        _cache[key] = df
        while len(_cache) > 4:
            _cache.popitem(last=False)
    return df


def mrtg(run_id, campaign=None):
    df = load_panel(run_id)
    t0, t1 = df["hour"].min(), df["hour"].max()
    if campaign:
        df = df[df["campaign"] == campaign]
        if df.empty:
            raise KeyError(campaign)
    # event logs only have rows for active hours → a missing campaign-hour is zero traffic
    idx = pd.date_range(t0, t1, freq="h")
    s = df.groupby("hour")[["impr", "clicks"]].sum().reindex(idx, fill_value=0)
    end = t1 + pd.Timedelta(hours=1)

    windows = []
    for key, title, avg, span, freq in WINDOWS:
        start = max(t0, end - span) if span is not None else t0
        sub = s[(s.index >= start) & (s.index < end)]
        g = sub.resample(freq).agg(["sum", "count"])
        impr, clicks, hours = g[("impr", "sum")], g[("clicks", "sum")], g[("impr", "count")]
        pts = []
        for t, i, c, h in zip(g.index, impr.values, clicks.values, hours.values):
            if h == 0:
                continue
            pts.append([int(t.value // 1_000_000), float(i) / h, float(c) / h,
                        float(c) / float(i) * 100 if i > 0 else None])
        tot_i, tot_c, tot_h = float(impr.sum()), float(clicks.sum()), float(hours.sum())
        ctrs = [p[3] for p in pts if p[3] is not None]
        windows.append({
            "key": key, "title": title, "avg": avg, "bin": freq,
            "start": int(pd.Timestamp(start).value // 1_000_000), "end": int(end.value // 1_000_000),
            "points": pts,
            "stats": {
                "impr": {"max": max((p[1] for p in pts), default=None),
                         "avg": tot_i / tot_h if tot_h else None, "cur": pts[-1][1] if pts else None},
                "clicks": {"max": max((p[2] for p in pts), default=None),
                           "avg": tot_c / tot_h if tot_h else None, "cur": pts[-1][2] if pts else None},
                "ctr": {"max": max(ctrs, default=None), "avg": tot_c / tot_i * 100 if tot_i else None,
                        "cur": pts[-1][3] if pts else None},
            },
        })

    prof = s.groupby(s.index.hour).agg({"impr": "mean", "clicks": "mean"})
    tot = s.groupby(s.index.hour).sum()
    profile = [{"hour": int(h), "impr_h": fnum(prof.loc[h, "impr"]),
                "ctr": fnum(tot.loc[h, "clicks"] / tot.loc[h, "impr"] * 100) if tot.loc[h, "impr"] else None}
               for h in prof.index]
    active = s[s["impr"] > 0]
    return {
        "campaign": campaign, "windows": windows, "profile": profile,
        "range": [int(t0.value // 1_000_000), int(end.value // 1_000_000)],
        "totals": {"impr": int(s["impr"].sum()), "clicks": int(s["clicks"].sum()),
                   "active_hours": int(len(active)), "hours": int(len(s)),
                   "first": active.index.min().isoformat() if len(active) else None,
                   "last": active.index.max().isoformat() if len(active) else None},
    }
__CTRMON_EOF__
w 'backend/app/store.py' <<'__CTRMON_EOF__'
"""Run directory layout and small JSON helpers.

    data/runs/<id>/
        meta.json       dispatcher-owned: status, params, timestamps, inputs, script info
        progress.json   worker-owned: current stage + per-stage timings
        result.json     worker output (structured results, checks, chart data)
        error.json      worker traceback on failure
        run.log         worker stdout/stderr (the script's own console output)
        input/          mapping.csv[.gz|...], events.csv[.gz|...]
        out/            the script's tables (csv), figures (pdf + png), results_summary.txt
        panel.pkl       hourly campaign panel for the MRTG graphs
"""
import json
import os
import re
import secrets
import shutil
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from . import config

RUN_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")
ACTIVE = ("queued", "running")


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def new_run_id():
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)


def run_dir(run_id):
    if not RUN_ID_RE.match(run_id or ""):
        raise KeyError(run_id)
    return config.RUNS_DIR / run_id


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path, obj):
    """Atomic write — readers never see a half-written file."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def read_meta(run_id):
    return read_json(run_dir(run_id) / "meta.json")


def update_meta(run_id, **fields):
    p = run_dir(run_id) / "meta.json"
    meta = read_json(p, {})
    meta.update(fields)
    write_json(p, meta)
    return meta


def list_runs():
    if not config.RUNS_DIR.exists():
        return []
    out = []
    for d in config.RUNS_DIR.iterdir():
        if d.is_dir() and RUN_ID_RE.match(d.name):
            m = read_json(d / "meta.json")
            if m:
                out.append(m)
    out.sort(key=lambda m: m.get("created", ""), reverse=True)
    return out


def delete_run(run_id):
    shutil.rmtree(run_dir(run_id), ignore_errors=True)


def tail(path, max_bytes=64_000):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read().decode("utf-8", errors="replace")
        if size > max_bytes:
            data = data.split("\n", 1)[-1]
        return data, size
    except FileNotFoundError:
        return "", 0
__CTRMON_EOF__
w 'backend/app/worker.py' <<'__CTRMON_EOF__'
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
__CTRMON_EOF__
w 'backend/requirements.txt' <<'__CTRMON_EOF__'
# analysis stack — pinned to the versions the v10 results were produced with
numpy==2.3.2
pandas==3.0.1
scipy==1.16.1
statsmodels==0.14.6
matplotlib==3.10.5
# web
flask==3.1.0
gunicorn==23.0.0
__CTRMON_EOF__
w 'backend/wsgi.py' <<'__CTRMON_EOF__'
import os

from app import create_app

app = create_app()

if __name__ == "__main__":  # dev: python wsgi.py  (no reloader — it would start a second dispatcher)
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", 5000)), debug=False, use_reloader=False, threaded=True)
__CTRMON_EOF__
w 'docker-compose.yml' <<'__CTRMON_EOF__'
services:
  ctr-monitor:
    build: .
    image: ctr-monitor:latest
    container_name: ctr-monitor
    restart: unless-stopped
    ports:
      # localhost only — uploaded data is client data and the app has no auth.
      # To share on a network, put it behind an authenticating proxy first.
      - "127.0.0.1:8080:8080"
    environment:
      CTR_MAX_CONCURRENT_RUNS: "1"   # parallel analysis runs (each is CPU + RAM heavy)
      CTR_MAX_UPLOAD_MB: "2048"
    volumes:
      - ctr-data:/data                                  # runs: inputs, outputs, logs
      - ./ctr_analysis.py:/app/ctr_analysis.py:ro       # drop in a new script version → next run uses it

volumes:
  ctr-data:
__CTRMON_EOF__
w 'frontend/index.html' <<'__CTRMON_EOF__'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="color-scheme" content="dark light" />
    <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%231a1a19'/%3E%3Cpath d='M5 23 L11 17 L15 20 L21 11 L27 14' fill='none' stroke='%233987e5' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'/%3E%3Ccircle cx='27' cy='14' r='2.6' fill='%230ca30c'/%3E%3C/svg%3E" />
    <title>CTR Monitor</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
__CTRMON_EOF__
w 'frontend/package-lock.json' <<'__CTRMON_EOF__'
{
  "name": "ctr-monitor-ui",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "ctr-monitor-ui",
      "version": "1.0.0",
      "dependencies": {
        "react": "18.3.1",
        "react-dom": "18.3.1"
      },
      "devDependencies": {
        "@vitejs/plugin-react": "4.3.4",
        "vite": "5.4.11"
      }
    },
    "node_modules/@babel/code-frame": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/code-frame/-/code-frame-7.29.7.tgz",
      "integrity": "sha1-8vu/6ofESiFZDsUVt3iywm2IZuc=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/helper-validator-identifier": "^7.29.7",
        "js-tokens": "^4.0.0",
        "picocolors": "^1.1.1"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/compat-data": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/compat-data/-/compat-data-7.29.7.tgz",
      "integrity": "sha1-bwI38PNtLlHAVwpjb67Z0tDv5ik=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/core": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/core/-/core-7.29.7.tgz",
      "integrity": "sha1-gMELFySAgpaLV6hXuRZAlx8gcPc=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/code-frame": "^7.29.7",
        "@babel/generator": "^7.29.7",
        "@babel/helper-compilation-targets": "^7.29.7",
        "@babel/helper-module-transforms": "^7.29.7",
        "@babel/helpers": "^7.29.7",
        "@babel/parser": "^7.29.7",
        "@babel/template": "^7.29.7",
        "@babel/traverse": "^7.29.7",
        "@babel/types": "^7.29.7",
        "@jridgewell/remapping": "^2.3.5",
        "convert-source-map": "^2.0.0",
        "debug": "^4.1.0",
        "gensync": "^1.0.0-beta.2",
        "json5": "^2.2.3",
        "semver": "^6.3.1"
      },
      "engines": {
        "node": ">=6.9.0"
      },
      "funding": {
        "type": "opencollective",
        "url": "https://opencollective.com/babel"
      }
    },
    "node_modules/@babel/generator": {
      "version": "7.29.8",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/generator/-/generator-7.29.8.tgz",
      "integrity": "sha1-SwuIeIVCJkMzngkCIUikxOuqSXk=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/parser": "^7.29.8",
        "@babel/types": "^7.29.8",
        "@jridgewell/gen-mapping": "^0.3.12",
        "@jridgewell/trace-mapping": "^0.3.28",
        "jsesc": "^3.0.2"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-compilation-targets": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-compilation-targets/-/helper-compilation-targets-7.29.7.tgz",
      "integrity": "sha1-eh3vcEMCQBxH9k+oVYnpdK4hcEI=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/compat-data": "^7.29.7",
        "@babel/helper-validator-option": "^7.29.7",
        "browserslist": "^4.24.0",
        "lru-cache": "^5.1.1",
        "semver": "^6.3.1"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-globals": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-globals/-/helper-globals-7.29.7.tgz",
      "integrity": "sha1-8EqW+9hHMkGxB5JD9bPwOjAQq3s=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-module-imports": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-module-imports/-/helper-module-imports-7.29.7.tgz",
      "integrity": "sha1-7yUEilGOgo1zk/rFiC3dc5Idc5Y=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/traverse": "^7.29.7",
        "@babel/types": "^7.29.7"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-module-transforms": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-module-transforms/-/helper-module-transforms-7.29.7.tgz",
      "integrity": "sha1-sGJ0elmXuhOGNyATKLv/d5YFdK4=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/helper-module-imports": "^7.29.7",
        "@babel/helper-validator-identifier": "^7.29.7",
        "@babel/traverse": "^7.29.7"
      },
      "engines": {
        "node": ">=6.9.0"
      },
      "peerDependencies": {
        "@babel/core": "^7.0.0"
      }
    },
    "node_modules/@babel/helper-plugin-utils": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-plugin-utils/-/helper-plugin-utils-7.29.7.tgz",
      "integrity": "sha1-wKB2bxoTYX2KF0B9erj51IYiXqQ=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-string-parser": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-string-parser/-/helper-string-parser-7.29.7.tgz",
      "integrity": "sha1-fwhx2Zgk0jE31g+G/PYTD9WhtR8=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-validator-identifier": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-validator-identifier/-/helper-validator-identifier-7.29.7.tgz",
      "integrity": "sha1-vYcITO0MeW7Ea9pJLeboPSnon8I=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helper-validator-option": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helper-validator-option/-/helper-validator-option-7.29.7.tgz",
      "integrity": "sha1-zzFb6UAhOzVOtKvMC9Aevj9zvCo=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/helpers": {
      "version": "7.29.10",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/helpers/-/helpers-7.29.10.tgz",
      "integrity": "sha1-1mK0otZsxs8CvFDorO0CP7yGSek=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/template": "^7.29.7",
        "@babel/types": "^7.29.8"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/parser": {
      "version": "7.29.9",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/parser/-/parser-7.29.9.tgz",
      "integrity": "sha1-5+4KJPdSxSlsZFWFXMtyZi5n6pY=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/types": "^7.29.8"
      },
      "bin": {
        "parser": "bin/babel-parser.js"
      },
      "engines": {
        "node": ">=6.0.0"
      }
    },
    "node_modules/@babel/plugin-transform-react-jsx-self": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/plugin-transform-react-jsx-self/-/plugin-transform-react-jsx-self-7.29.7.tgz",
      "integrity": "sha1-wkQkUnhYIgYk/Vmlseq0+kE8gDo=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/helper-plugin-utils": "^7.29.7"
      },
      "engines": {
        "node": ">=6.9.0"
      },
      "peerDependencies": {
        "@babel/core": "^7.0.0-0"
      }
    },
    "node_modules/@babel/plugin-transform-react-jsx-source": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/plugin-transform-react-jsx-source/-/plugin-transform-react-jsx-source-7.29.7.tgz",
      "integrity": "sha1-XPJaNomQa1ji8KLys3R4nmYnsV8=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/helper-plugin-utils": "^7.29.7"
      },
      "engines": {
        "node": ">=6.9.0"
      },
      "peerDependencies": {
        "@babel/core": "^7.0.0-0"
      }
    },
    "node_modules/@babel/template": {
      "version": "7.29.7",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/template/-/template-7.29.7.tgz",
      "integrity": "sha1-TZ1ABPZFzdME3pWMclFieE7KxwA=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/code-frame": "^7.29.7",
        "@babel/parser": "^7.29.7",
        "@babel/types": "^7.29.7"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/traverse": {
      "version": "7.29.10",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/traverse/-/traverse-7.29.10.tgz",
      "integrity": "sha1-CKs4djm0pnMEURJZx9ps8jqC6Rw=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/code-frame": "^7.29.7",
        "@babel/generator": "^7.29.8",
        "@babel/helper-globals": "^7.29.7",
        "@babel/parser": "^7.29.9",
        "@babel/template": "^7.29.7",
        "@babel/types": "^7.29.8",
        "debug": "^4.3.1"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@babel/types": {
      "version": "7.29.8",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@babel/types/-/types-7.29.8.tgz",
      "integrity": "sha1-Einu8x2FFW1w+j9M2Fk3bQ6vaGM=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/helper-string-parser": "^7.29.7",
        "@babel/helper-validator-identifier": "^7.29.7"
      },
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/@esbuild/aix-ppc64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/aix-ppc64/-/aix-ppc64-0.21.5.tgz",
      "integrity": "sha1-xxhKMmUz/N8bjuBzPiHHE7l1V18=",
      "cpu": [
        "ppc64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "aix"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/android-arm": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/android-arm/-/android-arm-0.21.5.tgz",
      "integrity": "sha1-mwQ4T7dxkm36bXrQQyTssqubLig=",
      "cpu": [
        "arm"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "android"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/android-arm64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/android-arm64/-/android-arm64-0.21.5.tgz",
      "integrity": "sha1-Cdm0NXeA2p6jp9+4M6Hx/0ObQFI=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "android"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/android-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/android-x64/-/android-x64-0.21.5.tgz",
      "integrity": "sha1-KZGOwtt1TO3LbBsE3ozWVHr2Rh4=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "android"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/darwin-arm64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/darwin-arm64/-/darwin-arm64-0.21.5.tgz",
      "integrity": "sha1-5JW1OWYOUWkPOSivUKdvsKbM/yo=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "darwin"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/darwin-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/darwin-x64/-/darwin-x64-0.21.5.tgz",
      "integrity": "sha1-wTg4+lc3KDmr3dyR1xVCzuouHiI=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "darwin"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/freebsd-arm64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/freebsd-arm64/-/freebsd-arm64-0.21.5.tgz",
      "integrity": "sha1-ZGuYmqIL+J/Qcd1dv61po1QuVQ4=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "freebsd"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/freebsd-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/freebsd-x64/-/freebsd-x64-0.21.5.tgz",
      "integrity": "sha1-qmFc/ICvlU00WJBuOMoiwYz1wmE=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "freebsd"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-arm": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-arm/-/linux-arm-0.21.5.tgz",
      "integrity": "sha1-/G/RGorKVsH284lPK+oEefj2Jrk=",
      "cpu": [
        "arm"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-arm64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-arm64/-/linux-arm64-0.21.5.tgz",
      "integrity": "sha1-cKxvoU9ct+H3+Ie8/7aArQmSK1s=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-ia32": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-ia32/-/linux-ia32-0.21.5.tgz",
      "integrity": "sha1-MnH1Oz+T49CT1RjRZJ1taNNG7eI=",
      "cpu": [
        "ia32"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-loong64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-loong64/-/linux-loong64-0.21.5.tgz",
      "integrity": "sha1-7WLgQjjFcCauqDHFoTC3PA+fJt8=",
      "cpu": [
        "loong64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-mips64el": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-mips64el/-/linux-mips64el-0.21.5.tgz",
      "integrity": "sha1-55uOtIvzsQb63sGsgkD7l7TmTL4=",
      "cpu": [
        "mips64el"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-ppc64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-ppc64/-/linux-ppc64-0.21.5.tgz",
      "integrity": "sha1-XyIDhgoUO5kZ04PvdXNSH7FUw+Q=",
      "cpu": [
        "ppc64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-riscv64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-riscv64/-/linux-riscv64-0.21.5.tgz",
      "integrity": "sha1-B7yv2ZMi1a9i9hjLnmqbf0u4Jdw=",
      "cpu": [
        "riscv64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-s390x": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-s390x/-/linux-s390x-0.21.5.tgz",
      "integrity": "sha1-t8z2hnUdaj5EuGJ6uryL4+9i2N4=",
      "cpu": [
        "s390x"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/linux-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/linux-x64/-/linux-x64-0.21.5.tgz",
      "integrity": "sha1-bY8Mdo4HDmQwmvgAS7lOaKsrs7A=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/netbsd-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/netbsd-x64/-/netbsd-x64-0.21.5.tgz",
      "integrity": "sha1-u+Qw9g03jsuI3sshnGAmZzh6YEc=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "netbsd"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/openbsd-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/openbsd-x64/-/openbsd-x64-0.21.5.tgz",
      "integrity": "sha1-mdHPKTcnlWDSEEgh9czOIgyyr3A=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "openbsd"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/sunos-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/sunos-x64/-/sunos-x64-0.21.5.tgz",
      "integrity": "sha1-CHQVEsENUpVmurqDe0/gUsjzSHs=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "sunos"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/win32-arm64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/win32-arm64/-/win32-arm64-0.21.5.tgz",
      "integrity": "sha1-Z1tzhTmEESQHNQFhRKsumaYPx10=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/win32-ia32": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/win32-ia32/-/win32-ia32-0.21.5.tgz",
      "integrity": "sha1-G/w86YqmypoJaeTSr3IUTFnBGTs=",
      "cpu": [
        "ia32"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@esbuild/win32-x64": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@esbuild/win32-x64/-/win32-x64-0.21.5.tgz",
      "integrity": "sha1-rK01HVgtFXuxRVNdsqb/U91RS1w=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ],
      "engines": {
        "node": ">=12"
      }
    },
    "node_modules/@jridgewell/gen-mapping": {
      "version": "0.3.13",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@jridgewell/gen-mapping/-/gen-mapping-0.3.13.tgz",
      "integrity": "sha1-Y0Khn0Q0dRjJPkOxrGnes8Rlah8=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@jridgewell/sourcemap-codec": "^1.5.0",
        "@jridgewell/trace-mapping": "^0.3.24"
      }
    },
    "node_modules/@jridgewell/remapping": {
      "version": "2.3.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@jridgewell/remapping/-/remapping-2.3.5.tgz",
      "integrity": "sha1-N1xHbRlylHhRuh4Vro8SMEdEWqE=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@jridgewell/gen-mapping": "^0.3.5",
        "@jridgewell/trace-mapping": "^0.3.24"
      }
    },
    "node_modules/@jridgewell/resolve-uri": {
      "version": "3.1.2",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@jridgewell/resolve-uri/-/resolve-uri-3.1.2.tgz",
      "integrity": "sha1-eg7mAfYPmaIMfHxf8MgDiMEYm9Y=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.0.0"
      }
    },
    "node_modules/@jridgewell/sourcemap-codec": {
      "version": "1.6.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@jridgewell/sourcemap-codec/-/sourcemap-codec-1.6.0.tgz",
      "integrity": "sha1-9MZj6GLwbcmMpNRThixGkCeJoY0=",
      "dev": true,
      "license": "MIT"
    },
    "node_modules/@jridgewell/trace-mapping": {
      "version": "0.3.31",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@jridgewell/trace-mapping/-/trace-mapping-0.3.31.tgz",
      "integrity": "sha1-2xXWeByTHzolGj2sOVAcmKYIL9A=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@jridgewell/resolve-uri": "^3.1.0",
        "@jridgewell/sourcemap-codec": "^1.4.14"
      }
    },
    "node_modules/@napi-rs/lzma-linux-x64-gnu": {
      "version": "1.5.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@napi-rs/lzma-linux-x64-gnu/-/lzma-linux-x64-gnu-1.5.1.tgz",
      "integrity": "sha1-5X1DBpZgeGYgOAlPs465FG3Drqk=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ],
      "engines": {
        "node": "^22.20 || ^24.12 || >=25"
      }
    },
    "node_modules/@rollup/rollup-android-arm-eabi": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-android-arm-eabi/-/rollup-android-arm-eabi-4.64.5.tgz",
      "integrity": "sha1-nVuR7azzXfMxqg2v3MO7OZQOKVI=",
      "cpu": [
        "arm"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "android"
      ]
    },
    "node_modules/@rollup/rollup-android-arm64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-android-arm64/-/rollup-android-arm64-4.64.5.tgz",
      "integrity": "sha1-orrkWHGSmOuRppW/AWPmE+Opmus=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "android"
      ]
    },
    "node_modules/@rollup/rollup-darwin-arm64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-darwin-arm64/-/rollup-darwin-arm64-4.64.5.tgz",
      "integrity": "sha1-8Q8IMmW2aZTSfVzGiNKEb0H+UMQ=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "darwin"
      ]
    },
    "node_modules/@rollup/rollup-darwin-x64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-darwin-x64/-/rollup-darwin-x64-4.64.5.tgz",
      "integrity": "sha1-aqed4buDbAxTm5BsVFy0UIviNDk=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "darwin"
      ]
    },
    "node_modules/@rollup/rollup-freebsd-arm64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-freebsd-arm64/-/rollup-freebsd-arm64-4.64.5.tgz",
      "integrity": "sha1-B+sd4lyhT83pv8gjrDCO1PutHOA=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "freebsd"
      ]
    },
    "node_modules/@rollup/rollup-freebsd-x64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-freebsd-x64/-/rollup-freebsd-x64-4.64.5.tgz",
      "integrity": "sha1-xDA9XjnEmdb18yIV9fBWrN3xphc=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "freebsd"
      ]
    },
    "node_modules/@rollup/rollup-linux-arm-gnueabihf": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-arm-gnueabihf/-/rollup-linux-arm-gnueabihf-4.64.5.tgz",
      "integrity": "sha1-4jtJfxaLm5iSu77id07e3C0FE6E=",
      "cpu": [
        "arm"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-arm-musleabihf": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-arm-musleabihf/-/rollup-linux-arm-musleabihf-4.64.5.tgz",
      "integrity": "sha1-5XOVn8SMQhQT3KcCaEx960rIgx4=",
      "cpu": [
        "arm"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-arm64-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-arm64-gnu/-/rollup-linux-arm64-gnu-4.64.5.tgz",
      "integrity": "sha1-/BNhV+iWuEmyJm3XIcZQCD9WvJs=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-arm64-musl": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-arm64-musl/-/rollup-linux-arm64-musl-4.64.5.tgz",
      "integrity": "sha1-yMTSULU8sx14bkCQa1ZwUqgoNN0=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-loong64-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-loong64-gnu/-/rollup-linux-loong64-gnu-4.64.5.tgz",
      "integrity": "sha1-dVOF4ois76Jitc+wV0BX4HYnKbc=",
      "cpu": [
        "loong64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-loong64-musl": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-loong64-musl/-/rollup-linux-loong64-musl-4.64.5.tgz",
      "integrity": "sha1-BOPBIUb/oN0qC/tVxv8QTPZee4s=",
      "cpu": [
        "loong64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-ppc64-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-ppc64-gnu/-/rollup-linux-ppc64-gnu-4.64.5.tgz",
      "integrity": "sha1-7u8iGAbYsy6PqJnz4opS2b2q68k=",
      "cpu": [
        "ppc64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-ppc64-musl": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-ppc64-musl/-/rollup-linux-ppc64-musl-4.64.5.tgz",
      "integrity": "sha1-PRdJLgnC1EzYupud7LPv50Vf6p4=",
      "cpu": [
        "ppc64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-riscv64-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-riscv64-gnu/-/rollup-linux-riscv64-gnu-4.64.5.tgz",
      "integrity": "sha1-6nV51UfkurT7L/d+jnJTX5exfyM=",
      "cpu": [
        "riscv64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-riscv64-musl": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-riscv64-musl/-/rollup-linux-riscv64-musl-4.64.5.tgz",
      "integrity": "sha1-wQZtOkyAZ9EqstNe2q64PTCV3JE=",
      "cpu": [
        "riscv64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-s390x-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-s390x-gnu/-/rollup-linux-s390x-gnu-4.64.5.tgz",
      "integrity": "sha1-W78aZ625x4p3jTcrTOAgCyzaoQw=",
      "cpu": [
        "s390x"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-x64-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-x64-gnu/-/rollup-linux-x64-gnu-4.64.5.tgz",
      "integrity": "sha1-40chqm8Xlmo4G3b0zPmcSS1hjsU=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-linux-x64-musl": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-linux-x64-musl/-/rollup-linux-x64-musl-4.64.5.tgz",
      "integrity": "sha1-JnOfisK4zpangAWt1jcnSKaMQtM=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "linux"
      ]
    },
    "node_modules/@rollup/rollup-openbsd-x64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-openbsd-x64/-/rollup-openbsd-x64-4.64.5.tgz",
      "integrity": "sha1-I2PxRbglV7EQ8i96JjRTALGu3vE=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "openbsd"
      ]
    },
    "node_modules/@rollup/rollup-openharmony-arm64": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-openharmony-arm64/-/rollup-openharmony-arm64-4.64.5.tgz",
      "integrity": "sha1-/IoLe/x2BCoZK78Ip75V0yQ/QOU=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "openharmony"
      ]
    },
    "node_modules/@rollup/rollup-win32-arm64-msvc": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-win32-arm64-msvc/-/rollup-win32-arm64-msvc-4.64.5.tgz",
      "integrity": "sha1-wNn0Kh6kUdlnVnJbs6+Z1z0xvdY=",
      "cpu": [
        "arm64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ]
    },
    "node_modules/@rollup/rollup-win32-ia32-msvc": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-win32-ia32-msvc/-/rollup-win32-ia32-msvc-4.64.5.tgz",
      "integrity": "sha1-Df7zjEmd0+g+AC1awArlbqJK/ug=",
      "cpu": [
        "ia32"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ]
    },
    "node_modules/@rollup/rollup-win32-x64-gnu": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-win32-x64-gnu/-/rollup-win32-x64-gnu-4.64.5.tgz",
      "integrity": "sha1-4/lejEsxb/k13a6fA8tXhFJP7nQ=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ]
    },
    "node_modules/@rollup/rollup-win32-x64-msvc": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@rollup/rollup-win32-x64-msvc/-/rollup-win32-x64-msvc-4.64.5.tgz",
      "integrity": "sha1-J83+NWokToWeg5hILqk6azKh2CM=",
      "cpu": [
        "x64"
      ],
      "dev": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "win32"
      ]
    },
    "node_modules/@types/babel__core": {
      "version": "7.20.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@types/babel__core/-/babel__core-7.20.5.tgz",
      "integrity": "sha1-PfFfJ7qFMZyqB7oI0HIYibs5wBc=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/parser": "^7.20.7",
        "@babel/types": "^7.20.7",
        "@types/babel__generator": "*",
        "@types/babel__template": "*",
        "@types/babel__traverse": "*"
      }
    },
    "node_modules/@types/babel__generator": {
      "version": "7.27.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@types/babel__generator/-/babel__generator-7.27.0.tgz",
      "integrity": "sha1-tYGSlMUReZV6+uw0FEL5NB5BCKk=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/types": "^7.0.0"
      }
    },
    "node_modules/@types/babel__template": {
      "version": "7.4.4",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@types/babel__template/-/babel__template-7.4.4.tgz",
      "integrity": "sha1-VnJRNwHBshmbxtrWNqnXSRWGdm8=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/parser": "^7.1.0",
        "@babel/types": "^7.0.0"
      }
    },
    "node_modules/@types/babel__traverse": {
      "version": "7.28.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@types/babel__traverse/-/babel__traverse-7.28.0.tgz",
      "integrity": "sha1-B9cT1szg0mXJhJ2wy+YtP2Hzb3Q=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/types": "^7.28.2"
      }
    },
    "node_modules/@types/estree": {
      "version": "1.0.9",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@types/estree/-/estree-1.0.9.tgz",
      "integrity": "sha1-zz8Oh2177hWpOrkluCv1cKOQSiQ=",
      "dev": true,
      "license": "MIT"
    },
    "node_modules/@vitejs/plugin-react": {
      "version": "4.3.4",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/@vitejs/plugin-react/-/plugin-react-4.3.4.tgz",
      "integrity": "sha1-xkvhC1TEZAE1pbKKJDIzDoitfCA=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@babel/core": "^7.26.0",
        "@babel/plugin-transform-react-jsx-self": "^7.25.9",
        "@babel/plugin-transform-react-jsx-source": "^7.25.9",
        "@types/babel__core": "^7.20.5",
        "react-refresh": "^0.14.2"
      },
      "engines": {
        "node": "^14.18.0 || >=16.0.0"
      },
      "peerDependencies": {
        "vite": "^4.2.0 || ^5.0.0 || ^6.0.0"
      }
    },
    "node_modules/baseline-browser-mapping": {
      "version": "2.11.28",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/baseline-browser-mapping/-/baseline-browser-mapping-2.11.28.tgz",
      "integrity": "sha1-eE7+wPo5ZcKKC7t1X0BgSs4cnbA=",
      "dev": true,
      "license": "Apache-2.0",
      "bin": {
        "baseline-browser-mapping": "dist/cli.cjs"
      },
      "engines": {
        "node": ">=6.0.0"
      }
    },
    "node_modules/browserslist": {
      "version": "4.29.3",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/browserslist/-/browserslist-4.29.3.tgz",
      "integrity": "sha1-nI2v6WqxyOQOIcEnS9+gWq7kZHY=",
      "dev": true,
      "funding": [
        {
          "type": "opencollective",
          "url": "https://opencollective.com/browserslist"
        },
        {
          "type": "tidelift",
          "url": "https://tidelift.com/funding/github/npm/browserslist"
        },
        {
          "type": "github",
          "url": "https://github.com/sponsors/ai"
        }
      ],
      "license": "MIT",
      "dependencies": {
        "baseline-browser-mapping": "^2.11.26",
        "caniuse-lite": "^1.0.30001813",
        "electron-to-chromium": "^1.5.439",
        "node-releases": "^2.0.57",
        "update-browserslist-db": "^1.3.3"
      },
      "bin": {
        "browserslist": "cli.js"
      },
      "engines": {
        "node": "^6 || ^7 || ^8 || ^9 || ^10 || ^11 || ^12 || >=13.7"
      }
    },
    "node_modules/caniuse-lite": {
      "version": "1.0.30001815",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/caniuse-lite/-/caniuse-lite-1.0.30001815.tgz",
      "integrity": "sha1-fPj6qCyZiwaHOhE+nT2VRPICKsA=",
      "dev": true,
      "funding": [
        {
          "type": "opencollective",
          "url": "https://opencollective.com/browserslist"
        },
        {
          "type": "tidelift",
          "url": "https://tidelift.com/funding/github/npm/caniuse-lite"
        },
        {
          "type": "github",
          "url": "https://github.com/sponsors/ai"
        }
      ],
      "license": "CC-BY-4.0"
    },
    "node_modules/convert-source-map": {
      "version": "2.0.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/convert-source-map/-/convert-source-map-2.0.0.tgz",
      "integrity": "sha1-S1YPZJ/E6RjdCrdc9JYei8iC2Co=",
      "dev": true,
      "license": "MIT"
    },
    "node_modules/debug": {
      "version": "4.4.3",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/debug/-/debug-4.4.3.tgz",
      "integrity": "sha1-xq5DLZvZZiWC/OCHCbA4xY6ePWo=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "ms": "^2.1.3"
      },
      "engines": {
        "node": ">=6.0"
      },
      "peerDependenciesMeta": {
        "supports-color": {
          "optional": true
        }
      }
    },
    "node_modules/electron-to-chromium": {
      "version": "1.5.452",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/electron-to-chromium/-/electron-to-chromium-1.5.452.tgz",
      "integrity": "sha1-60BCAZac78qvjF7oKxobuxnNe4s=",
      "dev": true,
      "license": "ISC"
    },
    "node_modules/esbuild": {
      "version": "0.21.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/esbuild/-/esbuild-0.21.5.tgz",
      "integrity": "sha1-nKMBsSCSKVm3ZjYNisgw2g0CmX0=",
      "dev": true,
      "hasInstallScript": true,
      "license": "MIT",
      "bin": {
        "esbuild": "bin/esbuild"
      },
      "engines": {
        "node": ">=12"
      },
      "optionalDependencies": {
        "@esbuild/aix-ppc64": "0.21.5",
        "@esbuild/android-arm": "0.21.5",
        "@esbuild/android-arm64": "0.21.5",
        "@esbuild/android-x64": "0.21.5",
        "@esbuild/darwin-arm64": "0.21.5",
        "@esbuild/darwin-x64": "0.21.5",
        "@esbuild/freebsd-arm64": "0.21.5",
        "@esbuild/freebsd-x64": "0.21.5",
        "@esbuild/linux-arm": "0.21.5",
        "@esbuild/linux-arm64": "0.21.5",
        "@esbuild/linux-ia32": "0.21.5",
        "@esbuild/linux-loong64": "0.21.5",
        "@esbuild/linux-mips64el": "0.21.5",
        "@esbuild/linux-ppc64": "0.21.5",
        "@esbuild/linux-riscv64": "0.21.5",
        "@esbuild/linux-s390x": "0.21.5",
        "@esbuild/linux-x64": "0.21.5",
        "@esbuild/netbsd-x64": "0.21.5",
        "@esbuild/openbsd-x64": "0.21.5",
        "@esbuild/sunos-x64": "0.21.5",
        "@esbuild/win32-arm64": "0.21.5",
        "@esbuild/win32-ia32": "0.21.5",
        "@esbuild/win32-x64": "0.21.5"
      }
    },
    "node_modules/escalade": {
      "version": "3.2.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/escalade/-/escalade-3.2.0.tgz",
      "integrity": "sha1-ARo/aYVroYnf+n3I/M6Z0qh5A+U=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6"
      }
    },
    "node_modules/fsevents": {
      "version": "2.3.3",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/fsevents/-/fsevents-2.3.3.tgz",
      "integrity": "sha1-ysZAd4XQNnWipeGlMFxpezR9kNY=",
      "dev": true,
      "hasInstallScript": true,
      "license": "MIT",
      "optional": true,
      "os": [
        "darwin"
      ],
      "engines": {
        "node": "^8.16.0 || ^10.6.0 || >=11.0.0"
      }
    },
    "node_modules/gensync": {
      "version": "1.0.0-beta.2",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/gensync/-/gensync-1.0.0-beta.2.tgz",
      "integrity": "sha1-MqbudsPX9S1GsrGuXZP+qFgKJeA=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=6.9.0"
      }
    },
    "node_modules/js-tokens": {
      "version": "4.0.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/js-tokens/-/js-tokens-4.0.0.tgz",
      "integrity": "sha1-GSA/tZmR35jjoocFDUZHzerzJJk=",
      "license": "MIT"
    },
    "node_modules/jsesc": {
      "version": "3.1.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/jsesc/-/jsesc-3.1.0.tgz",
      "integrity": "sha1-dNM1ojT2ftGZB/2t+sfM+dQJgl0=",
      "dev": true,
      "license": "MIT",
      "bin": {
        "jsesc": "bin/jsesc"
      },
      "engines": {
        "node": ">=6"
      }
    },
    "node_modules/json5": {
      "version": "2.2.3",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/json5/-/json5-2.2.3.tgz",
      "integrity": "sha1-eM1vGhm9wStz21rQxh79ZsHikoM=",
      "dev": true,
      "license": "MIT",
      "bin": {
        "json5": "lib/cli.js"
      },
      "engines": {
        "node": ">=6"
      }
    },
    "node_modules/loose-envify": {
      "version": "1.4.0",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/loose-envify/-/loose-envify-1.4.0.tgz",
      "integrity": "sha1-ce5R+nvkyuwaY4OffmgtgTLTDK8=",
      "license": "MIT",
      "dependencies": {
        "js-tokens": "^3.0.0 || ^4.0.0"
      },
      "bin": {
        "loose-envify": "cli.js"
      }
    },
    "node_modules/lru-cache": {
      "version": "5.1.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/lru-cache/-/lru-cache-5.1.1.tgz",
      "integrity": "sha1-HaJ+ZxAnGUdpXa9oSOhH8B2EuSA=",
      "dev": true,
      "license": "ISC",
      "dependencies": {
        "yallist": "^3.0.2"
      }
    },
    "node_modules/ms": {
      "version": "2.1.3",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/ms/-/ms-2.1.3.tgz",
      "integrity": "sha1-V0yBOM4dK1hh8LRFedut1gxmFbI=",
      "dev": true,
      "license": "MIT"
    },
    "node_modules/nanoid": {
      "version": "3.3.20",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/nanoid/-/nanoid-3.3.20.tgz",
      "integrity": "sha1-39RETYWqEBEe9muoXtcuCLoIVdg=",
      "dev": true,
      "funding": [
        {
          "type": "github",
          "url": "https://github.com/sponsors/ai"
        }
      ],
      "license": "MIT",
      "bin": {
        "nanoid": "bin/nanoid.cjs"
      },
      "engines": {
        "node": "^10 || ^12 || ^13.7 || ^14 || >=15.0.1"
      }
    },
    "node_modules/node-releases": {
      "version": "2.0.58",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/node-releases/-/node-releases-2.0.58.tgz",
      "integrity": "sha1-vFhWaUUkiiih1Loqfe7uCnGnP60=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=18"
      }
    },
    "node_modules/picocolors": {
      "version": "1.1.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/picocolors/-/picocolors-1.1.1.tgz",
      "integrity": "sha1-PTIa8+q5ObCDyPkpodEs2oHCa2s=",
      "dev": true,
      "license": "ISC"
    },
    "node_modules/postcss": {
      "version": "8.5.29",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/postcss/-/postcss-8.5.29.tgz",
      "integrity": "sha1-CGoN7SwCV8ce+4xod2tHd3RxS0o=",
      "dev": true,
      "funding": [
        {
          "type": "opencollective",
          "url": "https://opencollective.com/postcss/"
        },
        {
          "type": "tidelift",
          "url": "https://tidelift.com/funding/github/npm/postcss"
        },
        {
          "type": "github",
          "url": "https://github.com/sponsors/ai"
        }
      ],
      "license": "MIT",
      "dependencies": {
        "nanoid": "^3.3.19",
        "picocolors": "^1.1.1",
        "source-map-js": "^1.2.2"
      },
      "engines": {
        "node": "^10 || ^12 || >=14"
      }
    },
    "node_modules/react": {
      "version": "18.3.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/react/-/react-18.3.1.tgz",
      "integrity": "sha1-SauJIAnFOTNiW9FrJTP8dUyrKJE=",
      "license": "MIT",
      "dependencies": {
        "loose-envify": "^1.1.0"
      },
      "engines": {
        "node": ">=0.10.0"
      }
    },
    "node_modules/react-dom": {
      "version": "18.3.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/react-dom/-/react-dom-18.3.1.tgz",
      "integrity": "sha1-wiZdeVEbV9R5s90/36UVNklMXLQ=",
      "license": "MIT",
      "dependencies": {
        "loose-envify": "^1.1.0",
        "scheduler": "^0.23.2"
      },
      "peerDependencies": {
        "react": "^18.3.1"
      }
    },
    "node_modules/react-refresh": {
      "version": "0.14.2",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/react-refresh/-/react-refresh-0.14.2.tgz",
      "integrity": "sha1-ODPaAc4y2kcPH5NrnUd9pccCi/k=",
      "dev": true,
      "license": "MIT",
      "engines": {
        "node": ">=0.10.0"
      }
    },
    "node_modules/rollup": {
      "version": "4.64.5",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/rollup/-/rollup-4.64.5.tgz",
      "integrity": "sha1-ntpnWXf202lEl4qu8MCYdNMMD4Q=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "@types/estree": "1.0.9"
      },
      "bin": {
        "rollup": "dist/bin/rollup"
      },
      "engines": {
        "node": ">=18.0.0",
        "npm": ">=8.0.0"
      },
      "optionalDependencies": {
        "@napi-rs/lzma-linux-x64-gnu": "1.5.1",
        "@rollup/rollup-android-arm-eabi": "4.64.5",
        "@rollup/rollup-android-arm64": "4.64.5",
        "@rollup/rollup-darwin-arm64": "4.64.5",
        "@rollup/rollup-darwin-x64": "4.64.5",
        "@rollup/rollup-freebsd-arm64": "4.64.5",
        "@rollup/rollup-freebsd-x64": "4.64.5",
        "@rollup/rollup-linux-arm-gnueabihf": "4.64.5",
        "@rollup/rollup-linux-arm-musleabihf": "4.64.5",
        "@rollup/rollup-linux-arm64-gnu": "4.64.5",
        "@rollup/rollup-linux-arm64-musl": "4.64.5",
        "@rollup/rollup-linux-loong64-gnu": "4.64.5",
        "@rollup/rollup-linux-loong64-musl": "4.64.5",
        "@rollup/rollup-linux-ppc64-gnu": "4.64.5",
        "@rollup/rollup-linux-ppc64-musl": "4.64.5",
        "@rollup/rollup-linux-riscv64-gnu": "4.64.5",
        "@rollup/rollup-linux-riscv64-musl": "4.64.5",
        "@rollup/rollup-linux-s390x-gnu": "4.64.5",
        "@rollup/rollup-linux-x64-gnu": "4.64.5",
        "@rollup/rollup-linux-x64-musl": "4.64.5",
        "@rollup/rollup-openbsd-x64": "4.64.5",
        "@rollup/rollup-openharmony-arm64": "4.64.5",
        "@rollup/rollup-win32-arm64-msvc": "4.64.5",
        "@rollup/rollup-win32-ia32-msvc": "4.64.5",
        "@rollup/rollup-win32-x64-gnu": "4.64.5",
        "@rollup/rollup-win32-x64-msvc": "4.64.5",
        "fsevents": "~2.3.2"
      }
    },
    "node_modules/scheduler": {
      "version": "0.23.2",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/scheduler/-/scheduler-0.23.2.tgz",
      "integrity": "sha1-QUumSjsoKJLpRM8hCOzAeNEVzcM=",
      "license": "MIT",
      "dependencies": {
        "loose-envify": "^1.1.0"
      }
    },
    "node_modules/semver": {
      "version": "6.3.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/semver/-/semver-6.3.1.tgz",
      "integrity": "sha1-VW0u+GiRRuRtzqS/3QlfNDTf/LQ=",
      "dev": true,
      "license": "ISC",
      "bin": {
        "semver": "bin/semver.js"
      }
    },
    "node_modules/source-map-js": {
      "version": "1.2.2",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/source-map-js/-/source-map-js-1.2.2.tgz",
      "integrity": "sha1-efuI2XU1ohyycWLLBdIRtnrOpKs=",
      "dev": true,
      "license": "BSD-3-Clause",
      "engines": {
        "node": ">=0.10.0"
      }
    },
    "node_modules/update-browserslist-db": {
      "version": "1.3.4",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/update-browserslist-db/-/update-browserslist-db-1.3.4.tgz",
      "integrity": "sha1-6L1FlvaQCAX58SxaUgDIPFnDj68=",
      "dev": true,
      "funding": [
        {
          "type": "opencollective",
          "url": "https://opencollective.com/browserslist"
        },
        {
          "type": "tidelift",
          "url": "https://tidelift.com/funding/github/npm/browserslist"
        },
        {
          "type": "github",
          "url": "https://github.com/sponsors/ai"
        }
      ],
      "license": "MIT",
      "dependencies": {
        "escalade": "^3.2.0",
        "picocolors": "^1.1.1"
      },
      "bin": {
        "update-browserslist-db": "cli.js"
      },
      "peerDependencies": {
        "browserslist": ">= 4.21.0"
      }
    },
    "node_modules/vite": {
      "version": "5.4.11",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/vite/-/vite-5.4.11.tgz",
      "integrity": "sha1-O0Fc1K7XgaNWwd5anrr7g3cV9uU=",
      "dev": true,
      "license": "MIT",
      "dependencies": {
        "esbuild": "^0.21.3",
        "postcss": "^8.4.43",
        "rollup": "^4.20.0"
      },
      "bin": {
        "vite": "bin/vite.js"
      },
      "engines": {
        "node": "^18.0.0 || >=20.0.0"
      },
      "funding": {
        "url": "https://github.com/vitejs/vite?sponsor=1"
      },
      "optionalDependencies": {
        "fsevents": "~2.3.3"
      },
      "peerDependencies": {
        "@types/node": "^18.0.0 || >=20.0.0",
        "less": "*",
        "lightningcss": "^1.21.0",
        "sass": "*",
        "sass-embedded": "*",
        "stylus": "*",
        "sugarss": "*",
        "terser": "^5.4.0"
      },
      "peerDependenciesMeta": {
        "@types/node": {
          "optional": true
        },
        "less": {
          "optional": true
        },
        "lightningcss": {
          "optional": true
        },
        "sass": {
          "optional": true
        },
        "sass-embedded": {
          "optional": true
        },
        "stylus": {
          "optional": true
        },
        "sugarss": {
          "optional": true
        },
        "terser": {
          "optional": true
        }
      }
    },
    "node_modules/yallist": {
      "version": "3.1.1",
      "resolved": "http://af.epom.com/artifactory/api/npm/npm/yallist/-/yallist-3.1.1.tgz",
      "integrity": "sha1-27fa+b/YusmrRev2ArjLrQ1dCP0=",
      "dev": true,
      "license": "ISC"
    }
  }
}
__CTRMON_EOF__
w 'frontend/package.json' <<'__CTRMON_EOF__'
{
  "name": "ctr-monitor-ui",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "18.3.1",
    "react-dom": "18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "4.3.4",
    "vite": "5.4.11"
  }
}
__CTRMON_EOF__
w 'frontend/src/App.jsx' <<'__CTRMON_EOF__'
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import UploadDialog from "./components/UploadDialog";
import EvidenceTally from "./components/EvidenceTally";
import { api } from "./api";
import { go, href, useInterval, useRoute, useStored } from "./hooks";
import { ago, fixed, int, localTime, pval, runDuration, signed, stars } from "./format";
import { Hyp, HYP_INFO, Icon, RunStatus, Seg } from "./components/ui";
import Overview, { UploadPanel } from "./pages/Overview";
import Services from "./pages/Services";
import Graphs from "./pages/Graphs";
import Analysis from "./pages/Analysis";
import Campaigns from "./pages/Campaigns";
import PlainSummary from "./components/PlainSummary";
import QuartileCards from "./components/QuartileCards";
import Summary from "./pages/Summary";
import Files from "./pages/Files";
import Runs from "./pages/Runs";

const Ctx = createContext(null);
export const useApp = () => useContext(Ctx);

const PAGES = {
  overview: { title: "Tactical Overview", C: Overview, strip: true, top: UploadPanel },
  services: { title: "Estimates by Hypothesis", C: Services, strip: true },
  campaigns: { title: "Campaigns", C: Campaigns },
  graphs: { title: "Traffic Graphs", C: Graphs },
  analysis: { title: "Analysis", C: Analysis },
  summary: { title: "Results Summary", C: Summary },
  files: { title: "Figures & Tables", C: Files },
  runs: { title: "Runs", C: Runs },
};

function useTheme() {
  const [theme, setTheme] = useStored("ctr.theme", "auto");
  useEffect(() => {
    const el = document.documentElement;
    if (theme === "auto") el.removeAttribute("data-theme");
    else el.setAttribute("data-theme", theme);
  }, [theme]);
  return [theme, setTheme];
}

export default function App() {
  const route = useRoute();
  const [theme, setTheme] = useTheme();
  const [info, setInfo] = useState(null);
  const [runs, setRuns] = useState(null);
  const [runsErr, setRunsErr] = useState(null);
  const [selected, setSelected] = useStored("ctr.run", null);
  const [result, setResult] = useState({ id: null, data: null, error: null });
  const [menu, setMenu] = useState(false);
  const [uploadOpen, setUploadOpen] = useState(false);
  const openUpload = useCallback(() => setUploadOpen(true), []);

  const refresh = useCallback(() => api.runs().then((r) => { setRuns(r); setRunsErr(null); }, setRunsErr), []);
  useEffect(() => { refresh(); api.info().then(setInfo, () => {}); }, [refresh]);
  const active = (runs || []).filter((r) => r.status === "queued" || r.status === "running");
  useInterval(refresh, active.length ? 2000 : 15000);
  useInterval(() => api.info().then(setInfo, () => {}), 30000);

  const done = (runs || []).filter((r) => r.status === "ok");
  const run = (runs || []).find((r) => r.id === selected && r.status === "ok") || done[0] || null;

  // load the selected run's result
  useEffect(() => {
    if (!run || run.id === result.id) return;
    setResult({ id: run.id, data: null, error: null });
    api.result(run.id).then((data) => setResult({ id: run.id, data, error: null }),
      (error) => setResult({ id: run.id, data: null, error }));
  }, [run?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // a freshly finished run becomes the selection
  const [prevActive, setPrevActive] = useState([]);
  useEffect(() => {
    const ids = active.map((r) => r.id);
    const finished = prevActive.filter((id) => !ids.includes(id));
    const ok = finished.map((id) => (runs || []).find((r) => r.id === id)).find((r) => r?.status === "ok");
    if (ok) setSelected(ok.id);
    if (ids.join() !== prevActive.join()) setPrevActive(ids);
  }, [runs]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { setMenu(false); window.scrollTo(0, 0); }, [route.page]);

  const page = PAGES[route.page] || PAGES.overview;
  const res = result.id === run?.id ? result.data : null;
  const ctx = useMemo(() => ({ info, runs, run, res, resErr: result.error, route, refresh, select: setSelected, openUpload }),
    [info, runs, run, res, result.error, route, refresh, setSelected, openUpload]);
  const C = page.C;

  return (
    <Ctx.Provider value={ctx}>
      <div className="app">
        <Sidebar page={route.page} open={menu} info={info} primary={res?.checks?.primary} active={active} nCampaigns={res?.dataset?.n_campaigns} />
        <div className="main">
          <header className="topbar">
            <button className="btn ghost menu-btn" onClick={() => setMenu((m) => !m)} aria-label="Menu">☰</button>
            <div className="crumb">{page.title}{run && page !== PAGES.runs && <span className="muted"> · {run.label}</span>}</div>
            <div className="spacer" />
            {done.length > 0 && (
              <label className="run-select">
                <span className="muted" style={{ fontSize: 11.5 }}>Run</span>
                <select value={run?.id || ""} onChange={(e) => setSelected(e.target.value)}>
                  {done.map((r) => <option key={r.id} value={r.id}>{r.label} — {localTime(r.finished || r.created)}</option>)}
                </select>
              </label>
            )}
            <Seg value={theme} onChange={setTheme} label="Theme"
                 options={[{ value: "auto", label: "Auto" }, { value: "light", label: "☀" }, { value: "dark", label: "☾" }]} />
            <button type="button" className="btn primary" onClick={openUpload}>⇪ Upload data</button>
          </header>
          {active.map((r) => <RunBar key={r.id} r={r} />)}
          <main className="content">
            {runsErr && <div className="alert err">Backend unreachable: {String(runsErr.message || runsErr)}</div>}
            {page.top && run && <page.top />}
            {/* plain-language summary on every page, compact (headline only) until the viewer clicks Show;
                a run's detail page shows that run's instead */}
            {run && res?.mode === "structured" && !(route.page === "runs" && route.parts[0]) && (
              <PlainSummary runId={run.id} runLabel={run.label} onSummaryPage={route.page === "summary"} collapsible />
            )}
            {/* hypothesis tally on every page, compact (one line) until the viewer clicks Show;
                a run's own detail page shows that run's tally instead (see RunDetail) */}
            {run && res?.checks && !(route.page === "runs" && route.parts[0]) && (
              <div className="tally-row"><EvidenceTally checks={res.checks} showPrimary runLabel={run.label} collapsible /></div>
            )}
            {/* Overview and Estimates: run details + primary specification */}
            {page.strip && run && res?.checks && <StatusStrip run={run} res={res} />}
            {/* size-quartile cards on every page, compact (chips) until the viewer clicks Show; on Campaigns
                they filter the table, elsewhere they link to it */}
            {run && res?.size_quartiles?.length > 0 && !(route.page === "runs" && route.parts[0]) && (
              <QuartileCards quartiles={res.size_quartiles} filters={route.page === "campaigns"} collapsible
                             selected={route.page === "campaigns" ? route.query.get("q") : null}
                             onSelect={(q) => go(q ? `campaigns?q=${q}` : "campaigns")} />
            )}
            <C />
          </main>
        </div>
      </div>
      <UploadDialog open={uploadOpen} onClose={() => setUploadOpen(false)} info={info}
                    onCreated={(r) => { setUploadOpen(false); refresh(); go(`runs/${r.id}`); }} />
    </Ctx.Provider>
  );
}

function Sidebar({ page, open, info, primary, active, nCampaigns }) {
  const link = (key, label, icon, extra) => (
    <a href={href(key)} className={page === key ? "active" : ""}>{icon}{label}{extra}</a>
  );
  const s = info?.script;
  return (
    <aside className={`sidebar${open ? " open" : ""}`}>
      <div className="brand">
        <div className="brand-mark">
          <svg width="20" height="20" viewBox="0 0 32 32" aria-hidden="true">
            <path d="M3 24 L10 16 L15 20 L21 9 L29 13" fill="none" stroke="#3987e5" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
            <circle cx="29" cy="13" r="3" fill="#0ca30c" />
          </svg>
        </div>
        <div>
          <div className="brand-name">ctr<b>·</b>monitor</div>
          <div className="brand-sub">CTR vs impression volume</div>
        </div>
      </div>
      <nav className="nav">
        <div className="nav-h">General</div>
        {link("overview", "Tactical Overview", Icon.overview)}
        <div className="nav-h">Results</div>
        {link("services", "Estimates", Icon.services, primary ? (
          <span className="count" style={{ background: `var(--h${primary[1]})`, color: "#0b0b0b" }} title={`primary result supports ${primary}`}>{primary}</span>) : null)}
        {link("campaigns", "Campaigns", Icon.hosts, nCampaigns ? <span className="count" style={{ background: "#2b2b29" }}>{nCampaigns}</span> : null)}
        {link("graphs", "Traffic Graphs", Icon.graphs)}
        <div className="nav-h">Reports</div>
        {link("analysis", "Analysis", Icon.analysis)}
        {link("summary", "Results Summary", Icon.summary)}
        {link("files", "Figures & Tables", Icon.files)}
        <div className="nav-h">Runs</div>
        {link("runs", "Schedule / History", Icon.runs, active.length ? (
          <span className="count" style={{ background: "#3987e5", color: "#fff" }}>{active.length}</span>) : null)}
      </nav>
      <div className="side-foot">
        {s?.present ? (
          <>
            <div style={{ color: "#c3c2b7" }}>{s.version}</div>
            <div>sha {s.sha256?.slice(0, 12)} · {s.structured ? "structured" : "legacy mode"}</div>
          </>
        ) : s ? <div style={{ color: "#e66767" }}>analysis script missing: {s.path}</div> : "…"}
      </div>
    </aside>
  );
}

function RunBar({ r }) {
  const pr = r.progress;
  const n = pr?.stages?.length || 0;
  const idx = pr?.index ?? 0;
  const cur = pr?.stages?.find((s) => s.key === pr.current);
  return (
    <div className="runbar">
      <RunStatus status={r.status} sm />
      <b>{r.label}</b>
      <span className="muted">{r.status === "queued" ? "waiting for a worker slot" : cur ? `${cur.label} (${idx + 1}/${n})` : "starting…"}</span>
      {n > 0 && <div className="stages">{pr.stages.map((s, i) => <div key={s.key} className={i < idx ? "done" : i === idx && r.status === "running" ? "cur" : ""} />)}</div>}
      <span className="muted">{runDuration(r)}{pr?.peak_gb != null ? ` · peak ${pr.peak_gb.toFixed(1)} GB` : ""}</span>
      <a href={href("runs", r.id)} style={{ marginLeft: "auto" }}>event log →</a>
    </div>
  );
}

function StatusStrip({ run, res }) {
  const { primary } = res.checks;
  const w = res.regression?.within;
  return (
    <div className="strip">
      <div className="panel infobox">
        <div className="title">Current Analysis Status</div>
        <dl className="kv">
          <dt>Last updated</dt><dd>{localTime(run.finished)} <span className="muted">({ago(run.finished)})</span></dd>
          <dt>Run</dt><dd className="mono">{run.id}</dd>
          <dt>Input</dt><dd>{run.inputs?.events?.name} <span className="muted">+ {run.inputs?.mapping?.name}</span></dd>
          <dt>Params</dt><dd className="mono">min-impr={run.params?.min_impr} dpi={run.params?.dpi}</dd>
          <dt>Data</dt><dd>{res.dataset?.date_range} · {int(res.dataset?.n_final)} campaign-hours</dd>
        </dl>
      </div>
      <div className="panel infobox">
        <div className="title">Primary specification {primary && <Hyp h={primary} sm />}</div>
        {w ? (
          <dl className="kv">
            <dt>Model</dt><dd>Binomial GLM, campaign + time FE</dd>
            <dt>β₁ (ln V)</dt><dd className="mono">{signed(w.b)} [{signed(w.lo, 3)}, {signed(w.hi, 3)}]</dd>
            <dt>p</dt><dd className="mono">{pval(w.p)} {stars(w.p)}</dd>
            <dt>Supports</dt><dd>{primary ? `${primary} — ${HYP_INFO[primary].long}` : w.supports}</dd>
            <dt>OR / doubling</dt><dd className="mono">{fixed(w.or_doubling?.[0], 4)} <span className="muted">· pseudo-R² {fixed(w.pseudo_r2, 4)}</span></dd>
          </dl>
        ) : <span className="muted">legacy run — no structured results</span>}
      </div>
    </div>
  );
}
__CTRMON_EOF__
w 'frontend/src/api.js' <<'__CTRMON_EOF__'
async function req(path, opts = {}) {
  const r = await fetch(path, opts);
  if (!r.ok) {
    let msg = `${r.status} ${r.statusText}`;
    try { const j = await r.json(); if (j.error) msg = j.error; } catch { /* not json */ }
    throw new Error(msg);
  }
  if (r.status === 204) return null;
  const ct = r.headers.get("content-type") || "";
  return ct.includes("application/json") ? r.json() : r.text();
}

export const api = {
  info: () => req("/api/info"),
  runs: () => req("/api/runs"),
  run: (id) => req(`/api/runs/${id}`),
  result: (id) => req(`/api/runs/${id}/result`),
  narrative: (id) => req(`/api/runs/${id}/narrative`),
  log: (id, offset) => req(`/api/runs/${id}/log${offset != null ? `?offset=${offset}` : ""}`),
  mrtg: (id, campaign) => req(`/api/runs/${id}/mrtg${campaign ? `?campaign=${encodeURIComponent(campaign)}` : ""}`),
  table: (id, name) => req(`/api/runs/${id}/tables/${encodeURIComponent(name)}`),
  text: (id, name) => req(`/api/runs/${id}/files/${encodeURIComponent(name)}`),
  cancel: (id) => req(`/api/runs/${id}/cancel`, { method: "POST" }),
  remove: (id) => req(`/api/runs/${id}`, { method: "DELETE" }),
  create: (form) => req("/api/runs", { method: "POST", body: form }),
};

export const fileUrl = (id, name, download) =>
  `/api/runs/${id}/files/${encodeURIComponent(name)}${download ? "?download=1" : ""}`;
export const bundleUrl = (id) => `/api/runs/${id}/bundle.zip`;

// XHR for upload progress (fetch has no upload progress events)
export function upload(form, onProgress) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open("POST", "/api/runs");
    x.upload.onprogress = (e) => e.lengthComputable && onProgress?.(e.loaded / e.total);
    x.onload = () => {
      let body = null;
      try { body = JSON.parse(x.responseText); } catch { /* ignore */ }
      if (x.status >= 200 && x.status < 300) resolve(body);
      else reject(new Error(body?.error || `${x.status} ${x.statusText}`));
    };
    x.onerror = () => reject(new Error("network error"));
    x.send(form);
  });
}
__CTRMON_EOF__
w 'frontend/src/charts/Analysis.jsx' <<'__CTRMON_EOF__'
import { useState } from "react";
import Plot, { Legend, TipRow } from "./Plot";
import { bandPath, extent, linePath, nearestIndex, niceDomain } from "./scale";
import { useMeasure } from "../hooks";
import { compact, fixed, int, pct, pval, share, signed, stars } from "../format";

export const EST_COLOR = { GLM: "var(--s1)", OLS: "var(--s2)", WLS: "var(--s3)" };
export const HYP = {
  H1: { color: "var(--s1)", dash: null, name: "Exponential decay (fatigue)" },
  H2: { color: "var(--s2)", dash: "7 4", name: "Inverted-U (novelty → fatigue)" },
  H3: { color: "var(--s3)", dash: "3 3", name: "Saturating growth" },
  H4: { color: "var(--muted)", dash: "1 4", name: "Null (constant)" },
};
const BUCKETS = ["B1", "B2", "B3", "B4", "B5"];
const ring = { stroke: "var(--surface)", strokeWidth: 2 };
const bucketRange = (r) =>
  !r ? "" : r[1] === null ? `≥ ${compact(r[0])}` : `${compact(r[0])} – ${compact(r[1])}`;

/* ── fig1 — distribution of hourly CTR per volume bucket ─────────────────── */
export function BoxChart({ box, height = 260 }) {
  const rows = box.buckets;
  const y = { domain: [0, niceDomain(0, box.cap * 1.05, 5)[1]] };
  const hover = (px, py, { sx }) => {
    const i = Math.max(0, Math.min(4, Math.round(sx.invert(px))));
    const b = rows[i];
    if (!b?.n) return null;
    return {
      x: sx(i), y: py,
      content: (<><div className="t">{b.bucket} · {bucketRange(b.range)} impr/h</div>
        <TipRow label="Campaign-hours" value={int(b.n)} />
        <TipRow label="Median CTR" value={pct(b.median, 3)} />
        <TipRow label="IQR" value={`${pct(b.q1, 2)} – ${pct(b.q3, 2)}`} />
        <TipRow color="var(--s1)" kind="dot" label="Mean CTR" value={pct(b.mean, 3)} />
        <TipRow label="Zero-click hours" value={share(b.zero_click_share)} /></>),
    };
  };
  return (
    <>
      <Plot height={height} x={{ domain: [-0.5, 4.5] }} y={y} xTicks={[0, 1, 2, 3, 4]} xTickFmt={(i) => BUCKETS[i]}
            yTickFmt={(v) => `${v}%`} yTitle="Hourly CTR, %" xTitle="Impression-volume bucket" hover={hover}
            label="Box plots of hourly CTR by volume bucket">
        {({ sx, sy }) => rows.map((b, i) => {
          if (!b.n) return null;
          const cx = sx(i), bw = 24;
          return (
            <g key={b.bucket}>
              <line x1={cx} x2={cx} y1={sy(b.whisker_lo)} y2={sy(b.q1)} style={{ stroke: "var(--ink-2)", strokeWidth: 1 }} />
              <line x1={cx} x2={cx} y1={sy(b.q3)} y2={sy(b.whisker_hi)} style={{ stroke: "var(--ink-2)", strokeWidth: 1 }} />
              {[b.whisker_lo, b.whisker_hi].map((v, k) => (
                <line key={k} x1={cx - 6} x2={cx + 6} y1={sy(v)} y2={sy(v)} style={{ stroke: "var(--ink-2)", strokeWidth: 1 }} />))}
              <rect x={cx - bw / 2} y={sy(b.q3)} width={bw} height={Math.max(1, sy(b.q1) - sy(b.q3))} rx={3}
                    style={{ fill: "var(--s1)", fillOpacity: 0.16, stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <line x1={cx - bw / 2} x2={cx + bw / 2} y1={sy(b.median)} y2={sy(b.median)} style={{ stroke: "var(--ink)", strokeWidth: 2 }} />
              <circle cx={cx} cy={sy(Math.min(b.mean, box.cap))} r={4} style={{ fill: "var(--s1)", ...ring }} />
            </g>
          );
        })}
      </Plot>
      <Legend items={[{ label: "IQR box · median line · whiskers 1.5×IQR", color: "var(--s1)", kind: "area" },
                      { label: "Mean", color: "var(--s1)", kind: "dot" }]} />
      <div className="chart-note">
        y-axis capped at the 99th percentile ({pct(box.cap, 1)}); {int(box.n_above)} observations above it are not shown — same as fig. 1.
      </div>
    </>
  );
}

/* ── fig2 — mean CTR ± 95 % CI per bucket ────────────────────────────────── */
export function MeanCiChart({ rows, height = 260 }) {
  const [lo, hi] = extent(rows.flatMap((r) => [r.lo, r.hi]), 0.15);
  const hover = (px, py, { sx }) => {
    const i = Math.max(0, Math.min(rows.length - 1, Math.round(sx.invert(px))));
    const r = rows[i];
    return r && {
      x: sx(i), y: py,
      content: (<><div className="t">{r.bucket}</div>
        <TipRow color="var(--s1)" kind="dot" label="Mean CTR" value={pct(r.mean, 3)} />
        <TipRow label="95% CI" value={`${pct(r.lo, 3)} – ${pct(r.hi, 3)}`} />
        <TipRow label="N" value={int(r.n)} /></>),
    };
  };
  return (
    <Plot height={height} x={{ domain: [-0.5, rows.length - 0.5] }} y={{ domain: niceDomain(Math.max(0, lo), hi, 5) }}
          xTicks={rows.map((_, i) => i)} xTickFmt={(i) => rows[i]?.bucket} yTickFmt={(v) => `${+v.toFixed(2)}%`}
          yTitle="Mean hourly CTR, %" xTitle="Impression-volume bucket" hover={hover} label="Mean CTR with 95% CI by bucket">
      {({ sx, sy }) => (
        <>
          <path d={linePath(rows.map((r, i) => [sx(i), sy(r.mean)]))} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2 }} />
          {rows.map((r, i) => (
            <g key={r.bucket}>
              <line x1={sx(i)} x2={sx(i)} y1={sy(r.lo)} y2={sy(r.hi)} style={{ stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <line x1={sx(i) - 5} x2={sx(i) + 5} y1={sy(r.lo)} y2={sy(r.lo)} style={{ stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <line x1={sx(i) - 5} x2={sx(i) + 5} y1={sy(r.hi)} y2={sy(r.hi)} style={{ stroke: "var(--s1)", strokeWidth: 1.25 }} />
              <circle cx={sx(i)} cy={sy(r.mean)} r={4.5} style={{ fill: "var(--s1)", ...ring }} />
            </g>
          ))}
        </>
      )}
    </Plot>
  );
}

/* ── fig4 — marginal effect: GLM vs naive OLS ────────────────────────────── */
export function MarginalChart({ m, height = 320 }) {
  const ys = { domain: [0, niceDomain(0, m.ymax, 5)[1]] };
  const xs = { domain: extent(m.lv, 0.02) };
  const hover = (px, py, { sx, sy }) => {
    const i = nearestIndex(m.lv, sx.invert(px));
    const lv = m.lv[i];
    return {
      x: sx(lv), y: py, xLine: sx(lv),
      marks: (<>
        <circle cx={sx(lv)} cy={sy(m.glm.p[i])} r={4} style={{ fill: "var(--s1)", ...ring }} />
        <circle cx={sx(lv)} cy={sy(m.ols.p[i])} r={4} style={{ fill: "var(--s2)", ...ring }} />
      </>),
      content: (<><div className="t">ln V = {fixed(lv, 2)} <span className="muted">(≈ {compact(Math.exp(lv))} impr/h)</span></div>
        <TipRow color="var(--s1)" label="Binomial GLM" value={pct(m.glm.p[i], 3)} />
        <TipRow label="  95% band" value={`${pct(m.glm.lo[i], 2)} – ${pct(m.glm.hi[i], 2)}`} />
        <TipRow color="var(--s2)" label="OLS on logit(CTR)" value={pct(m.ols.p[i], 3)} /></>),
    };
  };
  return (
    <>
      <Plot height={height} x={xs} y={ys} yTickFmt={(v) => `${v}%`} xTitle="ln(impressions per campaign-hour)"
            yTitle="Predicted CTR, %" hover={hover} label="Marginal effect of volume on CTR">
        {({ sx, sy }) => {
          const X = m.lv.map(sx);
          return (
            <>
              <g style={{ fill: "var(--pts)", opacity: 0.32 }}>
                {m.points.map(([x, y], i) => y <= ys.domain[1] && <circle key={i} cx={sx(x)} cy={sy(y)} r={1.6} />)}
              </g>
              <path d={bandPath(X, m.glm.lo.map(sy), m.glm.hi.map(sy))} style={{ fill: "var(--s1)", opacity: 0.16 }} />
              <path d={linePath(X.map((x, i) => [x, sy(m.ols.p[i])]))}
                    style={{ fill: "none", stroke: "var(--s2)", strokeWidth: 2, strokeDasharray: "7 4" }} />
              <path d={linePath(X.map((x, i) => [x, sy(m.glm.p[i])]))} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2 }} />
            </>
          );
        }}
      </Plot>
      <Legend items={[
        { label: `Binomial GLM, 95% band (β₁ ${signed(m.glm.beta, 3)})`, color: "var(--s1)" },
        { label: `OLS on logit(CTR) — naive (β₁ ${signed(m.ols.beta, 3)})`, color: "var(--s2)", kind: "dash", dash: "7 4" },
        { label: `Campaign-hours (${int(m.n_shown)} of ${int(m.n_points)} shown)`, color: "var(--pts)", kind: "dot" },
      ]} />
      <div className="chart-note">Prediction at the grand means of logit(CTR) and ln(V); time covariates at their means — same construction as fig. 4.</div>
    </>
  );
}

/* ── fig5 — curve fits to the five bucket means ──────────────────────────── */
export function CurvesChart({ curves, height = 300 }) {
  const { models, buckets } = curves;
  const ok = models.filter((mm) => mm.line);
  const [x0, x1] = extent(buckets.map((b) => b.mean_logv), 0.04);
  const [y0, y1] = extent([...buckets.map((b) => b.mean_ctr), ...ok.flatMap((mm) => mm.line.map((p) => p[1]))], 0.1);
  const hover = (px, py, { sx, sy }) => {
    const xv = buckets.map((b) => b.mean_logv);
    const i = nearestIndex(xv, sx.invert(px));
    const b = buckets[i];
    if (Math.abs(sx(b.mean_logv) - px) > 28) return null;
    return {
      x: sx(b.mean_logv), y: sy(b.mean_ctr),
      content: (<><div className="t">B{b.bucket} — observed bucket mean</div>
        <TipRow label="mean ln V" value={fixed(b.mean_logv, 3)} />
        <TipRow label="mean CTR" value={pct(b.mean_ctr, 3)} /></>),
    };
  };
  return (
    <>
      <Plot height={height} x={{ domain: [x0, x1] }} y={{ domain: niceDomain(y0, y1, 5) }} yTickFmt={(v) => `${+v.toFixed(2)}%`}
            xTitle="Mean ln(V) in bucket" yTitle="Mean CTR, %" hover={hover} label="Curve fits for hypotheses H1–H4">
        {({ sx, sy }) => (
          <>
            {ok.map((mm) => (
              <path key={mm.key} d={linePath(mm.line.map(([x, y]) => [sx(x), sy(y)]))}
                    style={{ fill: "none", stroke: HYP[mm.key]?.color, strokeWidth: mm.best ? 3 : 1.75,
                             strokeDasharray: HYP[mm.key]?.dash || undefined, strokeLinecap: "round" }} />
            ))}
            {buckets.map((b) => (
              <g key={b.bucket}>
                <rect x={sx(b.mean_logv) - 5} y={sy(b.mean_ctr) - 5} width={10} height={10} transform={`rotate(45 ${sx(b.mean_logv)} ${sy(b.mean_ctr)})`}
                      style={{ fill: "var(--ink)", ...ring }} />
                <text x={sx(b.mean_logv)} y={sy(b.mean_ctr) - 11} textAnchor="middle">B{b.bucket}</text>
              </g>
            ))}
          </>
        )}
      </Plot>
      <Legend items={[
        ...models.map((mm) => ({
          label: `${mm.key} ${HYP[mm.key]?.name || ""}${mm.failed ? " (no valid fit)" : mm.best ? " — best AIC" : ""}`,
          color: HYP[mm.key]?.color, kind: HYP[mm.key]?.dash ? "dash" : "line", dash: HYP[mm.key]?.dash, off: mm.failed,
        })),
        { label: "Observed bucket means", color: "var(--ink)", kind: "dot" },
      ]} />
      <div className="chart-note">Five points, three parameters per curve — illustrative only, as the script notes.</div>
    </>
  );
}

/* ── fig6 — campaigns + total vs within slope ────────────────────────────── */
export function BetweenChart({ campaigns, lines, height = 320, onPick }) {
  const maxObs = Math.max(...campaigns.map((c) => c.n_obs));
  const rOf = (c) => 3 + 8 * Math.sqrt(c.n_obs / maxObs);
  const xs = { domain: extent(campaigns.map((c) => c.mean_logv), 0.05) };
  const ys = { domain: niceDomain(0, Math.max(...campaigns.map((c) => c.ctr), ...lines.total.map((p) => p[1])) * 1.04, 5) };
  const hover = (px, py, { sx, sy }) => {
    let best = null, bd = 24 * 24;
    for (const c of campaigns) {
      const d = (sx(c.mean_logv) - px) ** 2 + (sy(c.ctr) - py) ** 2;
      if (d < Math.max(bd, rOf(c) ** 2)) { bd = d; best = c; }
    }
    if (!best) return null;
    return {
      x: sx(best.mean_logv), y: sy(best.ctr), clickable: true, campaign: best.campaign,
      marks: <circle cx={sx(best.mean_logv)} cy={sy(best.ctr)} r={rOf(best) + 2} style={{ fill: "none", stroke: "var(--ink)", strokeWidth: 1.5 }} />,
      content: (<><div className="t">Campaign {best.campaign}</div>
        <TipRow label="CTR" value={pct(best.ctr, 3)} />
        <TipRow label="mean ln V" value={fixed(best.mean_logv, 2)} />
        <TipRow label="Campaign-hours" value={int(best.n_obs)} />
        <TipRow label="Impressions" value={compact(best.impr)} />
        {onPick && <div className="muted" style={{ marginTop: 3 }}>click → traffic graphs</div>}</>),
    };
  };
  return (
    <>
      <Plot height={height} x={xs} y={ys} yTickFmt={(v) => `${v}%`} xTitle="Campaign mean ln(V)" yTitle="Campaign CTR, %"
            hover={hover} onClick={onPick ? (t) => t.campaign && onPick(t.campaign) : undefined}
            label="Campaign CTR versus mean volume with total and within-campaign slopes">
        {({ sx, sy }) => (
          <>
            {campaigns.map((c) => (
              <circle key={c.campaign} cx={sx(c.mean_logv)} cy={sy(c.ctr)} r={rOf(c)}
                      style={{ fill: "var(--pts)", fillOpacity: 0.55, stroke: "var(--surface)", strokeWidth: 1.5 }} />
            ))}
            <path d={linePath(lines.total.map(([x, y]) => [sx(x), sy(y)]))}
                  style={{ fill: "none", stroke: "var(--s2)", strokeWidth: 2, strokeDasharray: "7 4" }} />
            <path d={linePath(lines.within.map(([x, y]) => [sx(x), sy(y)]))} style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2 }} />
          </>
        )}
      </Plot>
      <Legend items={[
        { label: `Total slope, no campaign FE (β ${signed(lines.b_total, 3)})`, color: "var(--s2)", kind: "dash", dash: "7 4" },
        { label: `Within-campaign slope (β₁ ${signed(lines.b_within, 3)})`, color: "var(--s1)" },
        { label: "Campaigns (area ∝ √hours)", color: "var(--pts)", kind: "dot" },
      ]} />
    </>
  );
}

/* ── fig7 — threshold sensitivity (β₁ ± CI) + zero-click share, as two charts ── */
export function ThresholdChart({ rows, height = 250 }) {
  const d = rows.filter((r) => /^impr >= \d+$/.test(r.Filter)).map((r) => ({ ...r, thr: +r.Filter.match(/\d+/)[0] }));
  if (!d.length) return <div className="empty">no threshold rows</div>;
  const vals = d.flatMap((r) => [r.glm_ci_lo, r.glm_ci_hi, r.ols_ci_lo, r.ols_ci_hi, 0]);
  const ys = { domain: niceDomain(...extent(vals, 0.08), 5) };
  const xs = { domain: [-0.5, d.length - 0.5] };
  const xt = d.map((_, i) => i);
  const fx = (i) => (d[i] ? `≥ ${d[i].thr}` : "");
  const hover = (px, py, { sx }) => {
    const i = Math.max(0, Math.min(d.length - 1, Math.round(sx.invert(px))));
    const r = d[i];
    return {
      x: sx(i), y: py,
      content: (<><div className="t">impressions ≥ {r.thr} per hour</div>
        <TipRow color="var(--s1)" kind="dot" label="GLM β₁" value={`${signed(r["GLM β₁"])} ${stars(r["GLM p"])}`} />
        <TipRow color="var(--s2)" kind="dot" label="OLS β₁" value={`${signed(r["OLS-logit β₁"])} ${stars(r["OLS p"])}`} />
        <TipRow label="Zero-click hours" value={share(r["Zero-click share (all)"])} />
        <TipRow label="N obs" value={int(r["N obs"])} /></>),
    };
  };
  const series = [["GLM", "GLM β₁", "glm_ci_lo", "glm_ci_hi", -7, "var(--s1)"], ["OLS", "OLS-logit β₁", "ols_ci_lo", "ols_ci_hi", 7, "var(--s2)"]];
  return (
    <>
      <Plot height={height} x={xs} y={ys} xTicks={xt} xTickFmt={fx} yTickFmt={(v) => fixed(v, 2)} yTitle="β₁ on ln(V)"
            hover={hover} label="Slope estimates by minimum-impression threshold">
        {({ sx, sy }) => (
          <>
            <line className="zero" x1={0} x2={sx(d.length - 0.5)} y1={sy(0)} y2={sy(0)} />
            {series.map(([k, b, lo, hi, off, col]) => (
              <g key={k}>
                <path d={linePath(d.map((r, i) => [sx(i) + off, sy(r[b])]))} style={{ fill: "none", stroke: col, strokeWidth: 1.5, opacity: 0.6, strokeDasharray: k === "OLS" ? "5 3" : undefined }} />
                {d.map((r, i) => (
                  <g key={i}>
                    <line x1={sx(i) + off} x2={sx(i) + off} y1={sy(r[lo])} y2={sy(r[hi])} style={{ stroke: col, strokeWidth: 1.5 }} />
                    <circle cx={sx(i) + off} cy={sy(r[b])} r={4.5} style={{ fill: k === "OLS" ? "var(--surface)" : col, stroke: col, strokeWidth: 2 }} />
                  </g>
                ))}
              </g>
            ))}
          </>
        )}
      </Plot>
      <Legend items={[{ label: "Binomial GLM, 95% CI", color: "var(--s1)", kind: "dot" },
                      { label: "OLS on logit(CTR), 95% CI", color: "var(--s2)", kind: "dash", dash: "5 3" }]} />
      <div className="chart-note" style={{ margin: "10px 0 4px" }}>Share of zero-click hours remaining at each threshold</div>
      <Plot height={120} x={xs} y={{ domain: niceDomain(0, Math.max(...d.map((r) => r["Zero-click share (all)"] * 100)), 3) }}
            xTicks={xt} xTickFmt={fx} yTickFmt={(v) => `${v}%`} hover={hover} label="Zero-click share by threshold">
        {({ sx, sy }) => d.map((r, i) => {
          const v = r["Zero-click share (all)"] * 100, bw = 24, x0 = sx(i) - bw / 2, y = sy(v), y0 = sy(0);
          const rad = Math.min(4, (y0 - y) / 2);
          return <path key={i} style={{ fill: "var(--muted)", opacity: 0.7 }}
            d={`M${x0},${y0}V${y + rad}Q${x0},${y} ${x0 + rad},${y}H${x0 + bw - rad}Q${x0 + bw},${y} ${x0 + bw},${y + rad}V${y0}Z`} />;
        })}
      </Plot>
    </>
  );
}

/* ── forest plot of every robustness estimate ────────────────────────────── */
export function ForestChart({ groups, hypOf }) {
  const [ref, width] = useMeasure();
  const [hov, setHov] = useState(null);
  const rows = groups.flatMap((g) => [{ header: g.title }, ...g.rows]);
  const est = rows.filter((r) => !r.header);
  const [lo, hi] = extent(est.flatMap((r) => [r.lo, r.hi, 0]), 0.06);
  const labelW = Math.min(300, Math.max(150, width * 0.36)), valW = 128, rowH = 24;
  const plotW = Math.max(80, width - labelW - valW - 10);
  const sx = (v) => labelW + ((v - lo) / (hi - lo)) * plotW;
  const H = rows.length * rowH + 26;
  const xt = (() => { const s = (hi - lo) / 4; return [lo + s * 0.5, 0, hi - s * 0.5].filter((v, i, a) => i === 1 || Math.abs(v) > s * 0.6); })();
  return (
    <div className="chart" ref={ref} style={{ height: H }}>
      {width > 0 && (
        <svg width={width} height={H} role="img" aria-label="Forest plot of robustness estimates" onPointerLeave={() => setHov(null)}>
          <line className="zero" x1={sx(0)} x2={sx(0)} y1={0} y2={rows.length * rowH} />
          {xt.map((t) => <text key={t} x={sx(t)} y={rows.length * rowH + 16} textAnchor="middle">{fixed(t, 2)}</text>)}
          {rows.map((r, i) => {
            const y = i * rowH + rowH / 2;
            if (r.header) {
              return <text key={i} x={0} y={y + 4} style={{ fill: "var(--ink)", fontWeight: 650, fontSize: 11 }}>{r.header}</text>;
            }
            const hy = hypOf?.(r);
            const col = hy ? `var(--h${hy[1]})` : "var(--ink-2)";
            return (
              <g key={i} onPointerEnter={() => setHov(i)}>
                <rect x={0} y={i * rowH} width={width} height={rowH} style={{ fill: hov === i ? "var(--hover)" : "transparent" }} />
                <text x={4} y={y + 4} style={{ fill: "var(--ink-2)", fontSize: 11 }}>
                  {r.label.length > labelW / 6.2 ? `${r.label.slice(0, Math.floor(labelW / 6.2) - 1)}…` : r.label}
                  <title>{r.full || r.label}</title>
                </text>
                {r.lo !== null && r.hi !== null && (
                  <line x1={sx(r.lo)} x2={sx(r.hi)} y1={y} y2={y} style={{ stroke: col, strokeWidth: 2, strokeLinecap: "round" }} />
                )}
                {r.b !== null && (r.est === "WLS"
                  ? <rect x={sx(r.b) - 4.5} y={y - 4.5} width={9} height={9} rx={1.5} style={{ fill: col, stroke: "var(--surface)", strokeWidth: 1.5 }} />
                  : <circle cx={sx(r.b)} cy={y} r={4.5} style={{ fill: r.est === "OLS" ? "var(--surface)" : col, stroke: col, strokeWidth: 2 }} />)}
                <text x={width - 4} y={y + 4} textAnchor="end" style={{ fontFamily: "var(--font-mono)", fontSize: 10.5, fill: "var(--ink-2)" }}>
                  {signed(r.b, 3)} {stars(r.p)}
                </text>
              </g>
            );
          })}
        </svg>
      )}
      {hov !== null && !rows[hov]?.header && (
        <div className="tip" style={{ top: hov * rowH + 26, left: Math.min(width - 260, labelW * 0.4) }}>
          <div className="t">{rows[hov].full || rows[hov].label}</div>
          <TipRow label={`${rows[hov].est} β₁`} value={signed(rows[hov].b)} />
          <TipRow label="95% CI" value={`${signed(rows[hov].lo)} … ${signed(rows[hov].hi)}`} />
          <TipRow label="p" value={`${pval(rows[hov].p)} ${stars(rows[hov].p)}`} />
          <TipRow label="supports" value={hypOf?.(rows[hov]) || "—"} />
        </div>
      )}
    </div>
  );
}
__CTRMON_EOF__
w 'frontend/src/charts/Mrtg.jsx' <<'__CTRMON_EOF__'
import Plot, { TipRow } from "./Plot";
import { areaPath, linePath, nearestIndex, niceDomain } from "./scale";
import { compact, dataTime, pct } from "../format";

const BIN_MS = { "1h": 36e5, "2h": 72e5, "6h": 216e5, "1D": 864e5 };

function stepPts(points, idx, bin, sx, sy) {
  const out = [];
  for (const p of points) {
    const v = p[idx];
    const y = v === null || v === undefined ? null : sy(v);
    out.push([sx(p[0]), y], [sx(p[0] + bin), y]);
  }
  return out;
}

function tipFor(points, bin, metric) {
  return (px, py, { sx }) => {
    if (!points.length) return null;
    const t = sx.invert(px);
    const i = nearestIndex(points.map((p) => p[0] + bin / 2), t);
    const p = points[i];
    return {
      x: sx(p[0] + bin / 2), y: py, xLine: sx(p[0] + bin / 2),
      content: (
        <>
          <div className="t">{dataTime(p[0], "short")}{bin > 36e5 ? ` – ${dataTime(p[0] + bin, "short").slice(-5)}` : ""}</div>
          <TipRow color="var(--s3)" kind="area" label="Impressions / h" value={compact(p[1])} />
          <TipRow label="Clicks / h" value={compact(p[2])} />
          <TipRow color="var(--s1)" label="CTR" value={pct(p[3], 3)} />
          {metric === "ctr" && p[1] === 0 && <div className="muted">no impressions</div>}
        </>
      ),
    };
  };
}

/** One MRTG block: title, impressions graph (area), CTR graph (line), Max/Average/Current legend. */
export function MrtgWindow({ w, compactMode = false }) {
  const bin = BIN_MS[w.bin] || 36e5;
  const pts = w.points;
  const x = { type: "time", domain: [w.start, w.end] };
  const imax = Math.max(1, ...pts.map((p) => p[1] || 0));
  const cvals = pts.map((p) => p[3]).filter((v) => v !== null);
  const cmax = Math.max(0.01, ...cvals);
  const yi = { domain: niceDomain(0, imax * 1.05, 4) };
  const yc = { domain: niceDomain(0, cmax * 1.1, 4) };
  const h1 = compactMode ? 120 : 150, h2 = compactMode ? 96 : 118;
  const s = w.stats;

  return (
    <div className="mrtg">
      <div className="mrtg-title">
        <span>{w.title} <span className="muted">({w.avg})</span></span>
        <span className="muted" style={{ fontSize: 11 }}>{dataTime(w.start, "short")} → {dataTime(w.end, "short")}</span>
      </div>
      <Plot height={h1} x={x} y={yi} vgrid yTickFmt={(v) => compact(v)} yTitle="impr / h" watermark="CTR·MON"
            label={`${w.title}: impressions per hour`} hover={tipFor(pts, bin, "impr")} margin={{ bottom: 22 }}>
        {({ sx, sy }) => {
          const sp = stepPts(pts, 1, bin, sx, sy);
          return (
            <>
              <path d={areaPath(sp, sy(0))} style={{ fill: "var(--s3)", opacity: 0.16 }} />
              <path d={linePath(sp)} style={{ fill: "none", stroke: "var(--s3)", strokeWidth: 2, strokeLinejoin: "round" }} />
            </>
          );
        }}
      </Plot>
      <Plot height={h2} x={x} y={yc} vgrid yTickFmt={(v) => `${+v.toFixed(2)}%`} yTitle="CTR" watermark="CTR·MON"
            label={`${w.title}: click-through rate`} hover={tipFor(pts, bin, "ctr")} margin={{ bottom: 22 }}>
        {({ sx, sy }) => (
          <path d={linePath(stepPts(pts, 3, bin, sx, sy))}
                style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2, strokeLinejoin: "round" }} />
        )}
      </Plot>
      <table className="mrtg-legend">
        <thead><tr><th>&nbsp;</th><th>Max</th><th>Average</th><th>Current</th></tr></thead>
        <tbody>
          <tr><td><i className="key area" style={{ background: "var(--s3)" }} />Impressions / h</td>
            <td>{compact(s.impr.max)}</td><td>{compact(s.impr.avg)}</td><td>{compact(s.impr.cur)}</td></tr>
          <tr><td><i className="key" style={{ background: "transparent" }} />Clicks / h</td>
            <td>{compact(s.clicks.max)}</td><td>{compact(s.clicks.avg)}</td><td>{compact(s.clicks.cur)}</td></tr>
          <tr><td><i className="key" style={{ background: "var(--s1)" }} />CTR</td>
            <td>{pct(s.ctr.max, 3)}</td><td>{pct(s.ctr.avg, 3)}</td><td>{pct(s.ctr.cur, 3)}</td></tr>
        </tbody>
      </table>
    </div>
  );
}

/** Hour-of-day profile as two small multiples (never a dual axis). */
export function HourProfile({ rows, imprKey = "impr_h", ctrKey = "ctr", ctrLabel = "CTR", height = 150 }) {
  const x = { domain: [-0.5, 23.5] };
  const xt = [0, 3, 6, 9, 12, 15, 18, 21];
  const imax = Math.max(1, ...rows.map((r) => r[imprKey] || 0));
  const cvals = rows.map((r) => r[ctrKey]).filter((v) => v !== null && v !== undefined);
  const [c0, c1] = [Math.min(...cvals), Math.max(...cvals)];
  const pad = (c1 - c0) * 0.25 || c1 * 0.1 || 0.1;
  const hover = (px, py, { sx }) => {
    const h = Math.max(0, Math.min(23, Math.round(sx.invert(px))));
    const r = rows.find((d) => d.hour === h);
    if (!r) return null;
    return {
      x: sx(h), y: py, xLine: sx(h),
      content: (<><div className="t">{String(h).padStart(2, "0")}:00 – {String(h).padStart(2, "0")}:59</div>
        <TipRow color="var(--s3)" kind="area" label="Mean impressions / h" value={compact(r[imprKey])} />
        <TipRow color="var(--s1)" label={ctrLabel} value={pct(r[ctrKey], 3)} /></>),
    };
  };
  return (
    <div className="grid g2">
      <div>
        <div className="chart-note" style={{ margin: "0 0 4px" }}>Mean impressions per hour, by hour of day</div>
        <Plot height={height} x={x} y={{ domain: niceDomain(0, imax, 4) }} xTicks={xt} yTickFmt={(v) => compact(v)}
              xTickFmt={(v) => `${String(v).padStart(2, "0")}h`} hover={hover} label="Impressions by hour of day">
          {({ sx, sy }) => {
            const bw = Math.min(16, Math.max(3, sx(1) - sx(0) - 2));
            return rows.map((r) => {
              const x0 = sx(r.hour) - bw / 2, y = sy(r[imprKey] || 0), y0 = sy(0);
              const rad = Math.min(3, bw / 2, (y0 - y) / 2);
              return <path key={r.hour} style={{ fill: "var(--s3)" }}
                d={`M${x0},${y0}V${y + rad}Q${x0},${y} ${x0 + rad},${y}H${x0 + bw - rad}Q${x0 + bw},${y} ${x0 + bw},${y + rad}V${y0}Z`} />;
            });
          }}
        </Plot>
      </div>
      <div>
        <div className="chart-note" style={{ margin: "0 0 4px" }}>{ctrLabel}, by hour of day</div>
        <Plot height={height} x={x} y={{ domain: niceDomain(Math.max(0, c0 - pad), c1 + pad, 4) }} xTicks={xt}
              yTickFmt={(v) => `${+v.toFixed(2)}%`} xTickFmt={(v) => `${String(v).padStart(2, "0")}h`} hover={hover}
              label="CTR by hour of day">
          {({ sx, sy }) => (
            <>
              <path d={linePath(rows.map((r) => [sx(r.hour), r[ctrKey] == null ? null : sy(r[ctrKey])]))}
                    style={{ fill: "none", stroke: "var(--s1)", strokeWidth: 2, strokeLinejoin: "round" }} />
              {rows.map((r) => r[ctrKey] != null && (
                <circle key={r.hour} cx={sx(r.hour)} cy={sy(r[ctrKey])} r={3}
                        style={{ fill: "var(--s1)", stroke: "var(--surface)", strokeWidth: 1.5 }} />))}
            </>
          )}
        </Plot>
      </div>
    </div>
  );
}

export function Sparkline({ values, width = 96, height = 22 }) {
  const v = values.map((x) => (x === null || x === undefined ? null : x));
  const def = v.filter((x) => x !== null);
  if (def.length < 2) return <span className="muted">—</span>;
  const lo = Math.min(...def), hi = Math.max(...def);
  const sx = (i) => 1 + (i / (v.length - 1)) * (width - 2);
  const sy = (x) => height - 3 - ((x - lo) / (hi - lo || 1)) * (height - 6);
  const last = v.length - 1 - [...v].reverse().findIndex((x) => x !== null);
  return (
    <svg width={width} height={height} aria-hidden="true" style={{ display: "block" }}>
      <path d={linePath(v.map((x, i) => [sx(i), x === null ? null : sy(x)]))}
            style={{ fill: "none", stroke: "var(--muted)", strokeWidth: 1.5, strokeLinejoin: "round" }} />
      <circle cx={sx(last)} cy={sy(v[last])} r={2.5} style={{ fill: "var(--s1)" }} />
    </svg>
  );
}
__CTRMON_EOF__
w 'frontend/src/charts/Plot.jsx' <<'__CTRMON_EOF__'
import { useMemo, useRef, useState } from "react";
import { useMeasure } from "../hooks";
import { linear, logScale, ticks as mkTicks, timeTicks } from "./scale";
import { tickTime } from "../format";

/**
 * Chart frame: measures its width, builds scales, draws the recessive grid and
 * axes, then hands {sx, sy, iw, ih} to `children`. Hover is generic:
 * `hover(px, py, ctx)` returns {x, y, content, xLine?, marks?} or null.
 */
export default function Plot({
  height = 220, margin: m0, x, y, xTickFmt, yTickFmt, xTitle, yTitle, yTicks: yTicksIn, xTicks: xTicksIn,
  vgrid = false, hover, onClick, children, watermark, label, minWidth = 260,
}) {
  const [ref, width] = useMeasure();
  const [tip, setTip] = useState(null);
  const svgRef = useRef(null);
  const m = { top: 10, right: watermark ? 22 : 12, bottom: xTitle ? 40 : 26, left: yTitle ? 58 : 46, ...m0 };
  const w = Math.max(width, minWidth);
  const iw = Math.max(10, w - m.left - m.right), ih = Math.max(10, height - m.top - m.bottom);

  const ctx = useMemo(() => {
    const sx = x.type === "log" ? logScale(x.domain, [0, iw]) : linear(x.domain, [0, iw]);
    const sy = y.type === "log" ? logScale(y.domain, [ih, 0]) : linear(y.domain, [ih, 0]);
    let xt = xTicksIn, xStep = null;
    if (!xt) {
      if (x.type === "time") { const t = timeTicks(x.domain[0], x.domain[1], Math.max(2, Math.floor(iw / 90))); xt = t.ticks; xStep = t.step; }
      else xt = mkTicks(x.domain[0], x.domain[1], Math.max(2, Math.floor(iw / 80)));
    }
    const yt = yTicksIn || mkTicks(y.domain[0], y.domain[1], Math.max(3, Math.floor(ih / 36)));
    return { sx, sy, iw, ih, xt, yt, xStep };
  }, [x.type, x.domain[0], x.domain[1], y.type, y.domain[0], y.domain[1], iw, ih, xTicksIn, yTicksIn]);

  const fx = xTickFmt || (x.type === "time" ? (v) => tickTime(v, ctx.xStep) : (v) => String(v));
  const fy = yTickFmt || ((v) => String(v));

  function move(e) {
    if (!hover || !svgRef.current) return;
    const r = svgRef.current.getBoundingClientRect();
    const px = e.clientX - r.left - m.left, py = e.clientY - r.top - m.top;
    if (px < -4 || px > iw + 4 || py < -4 || py > ih + 4) { setTip(null); return; }
    setTip(hover(Math.min(Math.max(px, 0), iw), py, ctx));
  }

  let tipStyle = null;
  if (tip) {
    const left = m.left + tip.x, top = m.top + (tip.y ?? 0);
    const flip = left > w * 0.6;
    tipStyle = { top: Math.max(0, top - 10), ...(flip ? { right: w - left + 14 } : { left: left + 14 }) };
  }

  return (
    <div className="chart" ref={ref} style={{ height }}>
      {width > 0 && (
        <svg ref={svgRef} width={w} height={height} role="img" aria-label={label}
             onPointerMove={move} onPointerLeave={() => setTip(null)}
             onClick={onClick && tip ? () => onClick(tip) : undefined}
             style={{ cursor: onClick && tip?.clickable ? "pointer" : undefined }}>
          <g transform={`translate(${m.left},${m.top})`}>
            {ctx.yt.map((t) => (
              <g key={`y${t}`}>
                <line className="gridline" x1={0} x2={iw} y1={Math.round(ctx.sy(t)) + 0.5} y2={Math.round(ctx.sy(t)) + 0.5} />
                <text x={-7} y={ctx.sy(t)} dy="0.32em" textAnchor="end">{fy(t)}</text>
              </g>
            ))}
            {ctx.xt.map((t) => (
              <g key={`x${t}`}>
                {vgrid && <line className="gridline" x1={Math.round(ctx.sx(t)) + 0.5} x2={Math.round(ctx.sx(t)) + 0.5} y1={0} y2={ih} />}
                <text x={ctx.sx(t)} y={ih + 15} textAnchor="middle">{fx(t)}</text>
              </g>
            ))}
            <line className="baseline" x1={0} x2={iw} y1={ih + 0.5} y2={ih + 0.5} />
            {yTitle && <text className="axis-title" transform={`translate(${-m.left + 12},${ih / 2}) rotate(-90)`} textAnchor="middle">{yTitle}</text>}
            {xTitle && <text className="axis-title" x={iw / 2} y={ih + 33} textAnchor="middle">{xTitle}</text>}
            {children(ctx)}
            {tip?.xLine !== undefined && <line className="xhair" x1={tip.xLine} x2={tip.xLine} y1={0} y2={ih} />}
            {tip?.marks}
            {watermark && (
              <text className="watermark" transform={`translate(${iw + 14},${ih / 2}) rotate(90)`} textAnchor="middle">{watermark}</text>
            )}
          </g>
        </svg>
      )}
      {tip && <div className="tip" style={tipStyle}>{tip.content}</div>}
    </div>
  );
}

export function TipRow({ color, kind = "line", label, value }) {
  return (
    <div className="r">
      <span>{color && <i className={`key ${kind}`} style={{ background: color }} />}{label}</span>
      <b>{value}</b>
    </div>
  );
}

export function Legend({ items }) {
  return (
    <div className="legend">
      {items.map((it) => (
        <span key={it.label} className={it.off ? "off" : undefined}>
          {it.kind === "dash" ? (
            <svg width="18" height="6" aria-hidden="true"><line x1="0" x2="18" y1="3" y2="3" stroke={it.color} strokeWidth="2" strokeDasharray={it.dash || "5 3"} /></svg>
          ) : (
            <i className={`key ${it.kind || "line"}`} style={{ background: it.color }} />
          )}
          {it.label}
        </span>
      ))}
    </div>
  );
}
__CTRMON_EOF__
w 'frontend/src/charts/scale.js' <<'__CTRMON_EOF__'
export function linear([d0, d1], [r0, r1]) {
  const k = (r1 - r0) / (d1 - d0 || 1);
  const f = (v) => r0 + (v - d0) * k;
  f.invert = (p) => d0 + (p - r0) / k;
  return f;
}

export function logScale([d0, d1], [r0, r1]) {
  const l0 = Math.log10(d0), l1 = Math.log10(d1);
  const k = (r1 - r0) / (l1 - l0 || 1);
  const f = (v) => r0 + (Math.log10(v) - l0) * k;
  f.invert = (p) => 10 ** (l0 + (p - r0) / k);
  return f;
}

function step(span, count) {
  const raw = span / Math.max(1, count);
  const mag = 10 ** Math.floor(Math.log10(raw));
  const n = raw / mag;
  return (n >= 7.5 ? 10 : n >= 3.5 ? 5 : n >= 1.5 ? 2 : 1) * mag;
}

export function niceDomain(lo, hi, count = 5, { zero = false } = {}) {
  if (zero) { lo = Math.min(0, lo); hi = Math.max(0, hi); }
  if (!(hi > lo)) { const pad = Math.abs(lo) * 0.1 || 1; lo -= pad; hi += pad; }
  const s = step(hi - lo, count);
  return [Math.floor(lo / s + 1e-9) * s, Math.ceil(hi / s - 1e-9) * s];
}

export function ticks(lo, hi, count = 5) {
  const s = step(hi - lo, count);
  const out = [];
  for (let v = Math.ceil(lo / s - 1e-9) * s; v <= hi + s * 1e-9; v += s) out.push(+v.toPrecision(12));
  return out;
}

const H = 3600e3;
const TIME_STEPS = [H, 2 * H, 3 * H, 6 * H, 12 * H, 24 * H, 48 * H, 7 * 24 * H, 14 * 24 * H];
export function timeTicks(t0, t1, count = 6) {
  const span = t1 - t0;
  const st = TIME_STEPS.find((s) => span / s <= count) || TIME_STEPS[TIME_STEPS.length - 1];
  const out = [];
  for (let t = Math.ceil(t0 / st) * st; t <= t1; t += st) out.push(t);
  return { ticks: out, step: st };
}

export function extent(values, pad = 0) {
  let lo = Infinity, hi = -Infinity;
  for (const v of values) if (v !== null && v !== undefined && Number.isFinite(v)) { if (v < lo) lo = v; if (v > hi) hi = v; }
  if (lo === Infinity) return [0, 1];
  const p = (hi - lo) * pad;
  return [lo - p, hi + p];
}

// SVG path through [x,y] px points; null y breaks the line
export function linePath(pts) {
  let d = "", pen = false;
  for (const [x, y] of pts) {
    if (y === null || y === undefined || !Number.isFinite(y)) { pen = false; continue; }
    d += `${pen ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`;
    pen = true;
  }
  return d;
}

export function areaPath(pts, y0) {
  // split into runs of defined points, close each run to the baseline
  let d = "", run = [];
  const flush = () => {
    if (run.length) {
      d += `M${run[0][0].toFixed(1)},${y0.toFixed(1)}` + run.map(([x, y]) => `L${x.toFixed(1)},${y.toFixed(1)}`).join("")
        + `L${run[run.length - 1][0].toFixed(1)},${y0.toFixed(1)}Z`;
    }
    run = [];
  };
  for (const p of pts) (p[1] === null || p[1] === undefined || !Number.isFinite(p[1])) ? flush() : run.push(p);
  flush();
  return d;
}

export function bandPath(xs, lo, hi) {
  if (!xs.length) return "";
  const top = xs.map((x, i) => `${i ? "L" : "M"}${x.toFixed(1)},${hi[i].toFixed(1)}`).join("");
  const bot = xs.slice().reverse().map((x, i) => `L${x.toFixed(1)},${lo[xs.length - 1 - i].toFixed(1)}`).join("");
  return `${top}${bot}Z`;
}

export function nearestIndex(sorted, v) {
  let lo = 0, hi = sorted.length - 1;
  if (hi < 0) return -1;
  while (hi - lo > 1) { const m = (lo + hi) >> 1; if (sorted[m] < v) lo = m; else hi = m; }
  return Math.abs(sorted[lo] - v) <= Math.abs(sorted[hi] - v) ? lo : hi;
}
__CTRMON_EOF__
w 'frontend/src/components/EvidenceTally.jsx' <<'__CTRMON_EOF__'
import { href, useStored } from "../hooks";
import { Hyp, HYP_INFO } from "./ui";

/**
 * How many estimates support each hypothesis, plus how many disagree with the primary result.
 * Cells link to the matching Estimates filter. `collapsible` adds a Hide/Show toggle; the short form
 * is a one-line bar of the same counts and is the default; the choice is remembered per viewer under
 * `storageKey` — one shared setting for every page by default.
 */
export default function EvidenceTally({ checks, showPrimary = false, runLabel, collapsible = false,
                                        storageKey = "ctr.tally.open.compact", defaultOpen = false }) {
  const [openPref, setOpen] = useStored(storageKey, defaultOpen);
  const open = !collapsible || openPref;
  const { tally, primary } = checks;
  const disagree = checks.services.filter((x) => x.kind === "hypothesis" && x.supported && x.hyp && x.hyp !== primary).length;
  const link = { color: "inherit", textDecoration: "none", display: "block" };
  const toggle = collapsible && (
    <button type="button" className="btn sm ghost" onClick={() => setOpen(!openPref)} aria-expanded={open} style={{ marginLeft: "auto" }}>
      {open ? "Hide ▴" : "Show ▾"}
    </button>
  );

  if (!open) {
    return (
      <div className="panel tally-compact">
        <b>Evidence by hypothesis</b>
        {["H1", "H2", "H3", "H4"].map((h) => (
          <a key={h} href={`${href("services")}?filter=${h}`} title={`${HYP_INFO[h].long}: ${HYP_INFO[h].desc}`}
             className={`tc h${h[1]}${tally[h] ? "" : " zero"}${h === primary ? " lead" : ""}`}>
            <i /><span className="mono">{h}</span><b>{tally[h]}</b>
          </a>
        ))}
        <a href={`${href("services")}?filter=disagree`} className={`tc${disagree ? "" : " zero"}`}
           title="estimates that support a different hypothesis than the primary specification">
          <b>{disagree}</b> disagree with {primary || "primary"}
        </a>
        {toggle}
      </div>
    );
  }

  const cell = (h) => (
    <div key={h} className={`${tally[h] ? `on-h${h[1]}` : ""} ${h === primary ? "lead" : ""}`}>
      <a href={`${href("services")}?filter=${h}`} style={link} title={`${HYP_INFO[h].long}: ${HYP_INFO[h].desc}`}>
        <div className="lbl">{h}</div>
        <div className={`val ${tally[h] ? "" : "zero"}`}>{tally[h]}</div>
        <div className="nm">{HYP_INFO[h].short}</div>
      </a>
    </div>
  );
  return (
    <div className="panel infobox">
      <div className="title">
        Evidence by hypothesis
        {runLabel && <span className="muted" style={{ fontWeight: 400, fontSize: 12 }}>· {runLabel}</span>}
        {showPrimary && primary && <><span className="muted" style={{ fontWeight: 400, fontSize: 12 }}>· primary result</span> <Hyp h={primary} sm /></>}
        {toggle}
      </div>
      <div className="totals">
        {["H1", "H2", "H3", "H4"].map(cell)}
        <div>
          <a href={`${href("services")}?filter=disagree`} style={link} title="estimates that support a different hypothesis than the primary specification">
            <div className="lbl">Disagree</div>
            <div className={`val ${disagree ? "" : "zero"}`}>{disagree}</div>
            <div className="nm">with {primary || "primary"}</div>
          </a>
        </div>
      </div>
      <div className="muted" style={{ marginTop: 8, fontSize: 11 }}>
        number of estimates supporting each hypothesis · {checks.n_hypothesis} estimates, {tally.info} info rows
      </div>
    </div>
  );
}
__CTRMON_EOF__
w 'frontend/src/components/PlainSummary.jsx' <<'__CTRMON_EOF__'
import { useState } from "react";
import { api } from "../api";
import { href, useAsync, useStored } from "../hooks";
import { Empty, Panel } from "./ui";

/**
 * "In plain words" panel — rule-based narrative for one run (see backend/app/narrative.py).
 * `collapsible` adds a Hide/Show toggle; it starts as the one-line headline and the choice is
 * remembered per viewer under `storageKey` — one shared setting for every page by default.
 */
export default function PlainSummary({ runId, runLabel, onSummaryPage = false, onFull, collapsible = false,
                                       storageKey = "ctr.plain.open.compact", defaultOpen = false }) {
  const n = useAsync(() => api.narrative(runId), [runId]);
  const [copied, setCopied] = useState(false);
  const [openPref, setOpen] = useStored(storageKey, defaultOpen);
  if (n.error) return null;  // legacy runs have no narrative — just leave it out
  const nd = n.data;
  const open = !collapsible || openPref;
  const copy = () => navigator.clipboard?.writeText(`${nd.headline}\n\n${nd.text}`).then(
    () => { setCopied(true); setTimeout(() => setCopied(false), 1500); }, () => {});
  return (
    <Panel title="In plain words" className={open ? "" : "collapsed"}
           sub={open ? `what ${runLabel ? `“${runLabel}”` : "this run"} found`
             : nd && <span className={`plain-inline hyp-${nd.hyp || "none"}`}>{nd.headline}</span>}
           tools={<>
             {nd && open && <button className="btn sm" onClick={copy}>{copied ? "Copied" : "Copy"}</button>}
             {!onSummaryPage && (onFull
               ? <button type="button" className="btn sm" onClick={onFull}>Full summary</button>
               : <a className="btn sm" href={href("summary")}>Full summary</a>)}
             {collapsible && (
               <button type="button" className="btn sm ghost" onClick={() => setOpen(!openPref)} aria-expanded={open}>
                 {open ? "Hide ▴" : "Show ▾"}
               </button>
             )}
           </>}>
      {!nd ? <Empty title="Loading…" /> : (
        <div className="plain">
          <div className={`plain-head hyp-${nd.hyp || "none"}`}>{nd.headline}</div>
          <p>{nd.text}</p>
          <div className="plain-note">
            {nd.note} {onSummaryPage ? "Exact estimates are in the full summary below." : "Exact estimates are in the full results summary."}
          </div>
        </div>
      )}
    </Panel>
  );
}
__CTRMON_EOF__
w 'frontend/src/components/QuartileCards.jsx' <<'__CTRMON_EOF__'
import { compact, int, pval, signed, stars } from "../format";
import { useStored } from "../hooks";
import { Hyp, Panel, TallyDots, Weight } from "./ui";

/**
 * Campaign size quartiles (§4.6a): one card per quartile with the hypothesis its GLM slope supports.
 * `onSelect(short|null)` is called on click — the Campaigns page filters its table, other pages
 * navigate there. `collapsible` adds a Hide/Show toggle; it starts as a row of chips and the choice is
 * remembered per viewer under `storageKey` — one shared setting for every page by default.
 */
export default function QuartileCards({ quartiles, selected, onSelect, collapsible = false, filters = false, runLabel,
                                        storageKey = "ctr.quart.open.compact", defaultOpen = false }) {
  const [openPref, setOpen] = useStored(storageKey, defaultOpen);
  const open = !collapsible || openPref;
  const tally = {};
  for (const q of quartiles) if (q.hyp) tally[q.hyp] = (tally[q.hyp] || 0) + 1;
  const perGroup = Math.round(quartiles.reduce((n, q) => n + q.n_campaigns, 0) / Math.max(1, quartiles.length));

  return (
    <Panel title="By campaign size quartile" flush className={open ? "" : "collapsed"}
           sub={open
             ? <>§4.6a — within-campaign GLM slope per size group{runLabel ? ` · “${runLabel}”` : ""} · quartiles: <TallyDots tally={tally} /></>
             : <span className="q-inline">
                 {quartiles.map((q) => (
                   <button key={q.short} type="button" className={`q-chip${selected === q.short ? " on" : ""}`}
                           onClick={() => onSelect?.(filters && selected === q.short ? null : q.short)}
                           aria-pressed={filters ? selected === q.short : undefined}
                           title={filters ? (selected === q.short ? "show all campaigns" : `show only ${q.label} campaigns (${q.n_campaigns})`)
                             : `${q.label}: ${q.n_campaigns} campaigns — open in Campaigns`}>
                     <span className="mono">{q.short}</span>{q.tested ? <Hyp h={q.hyp} sm /> : <span className="muted">—</span>}
                   </button>
                 ))}
               </span>}
           tools={<>
             {open && <Weight w="few clusters" />}
             {collapsible && (
               <button type="button" className="btn sm ghost" onClick={() => setOpen(!openPref)} aria-expanded={open}>
                 {open ? "Hide ▴" : "Show ▾"}
               </button>
             )}
           </>}>
      <div className="qcards">
        {quartiles.map((q) => (
          <button key={q.short} type="button" className={`qcard${selected === q.short ? " on" : ""}`}
                  onClick={() => onSelect?.(filters && selected === q.short ? null : q.short)}
                  aria-pressed={filters ? selected === q.short : undefined}
                  title={filters ? (selected === q.short ? "show all campaigns" : `show only ${q.label} campaigns`)
                    : `open the ${q.label} campaigns`}>
            <div className="qcard-h">
              <b>{q.label}</b>
              <span className="muted">{q.n_campaigns} campaigns</span>
            </div>
            {q.tested ? (
              <>
                <Hyp h={q.hyp} />
                <div className="mono qcard-num">β₁ {signed(q.glm.b, 3)} · p {pval(q.glm.p)} {stars(q.glm.p)}</div>
                <div className="qcard-sub">median {compact(q.median_impr)} impr/h · {int(q.n_obs)} hours</div>
                <div className="qcard-sub">naive OLS: <Hyp h={q.ols_hyp} sm /></div>
              </>
            ) : <div className="muted" style={{ fontSize: 12 }}>not estimated — fewer than 30 campaign-hours</div>}
          </button>
        ))}
      </div>
      <div className="chart-note" style={{ padding: "0 14px 12px", margin: 0 }}>
        Quartiles split campaigns by their median impressions per hour (same rule as the script). Each card is one GLM fit on
        that group's campaign-hours; with ~{perGroup} campaigns per group the script flags these p-values as approximate.{" "}
        {filters ? "Click a card to filter the table." : "Click a card to see its campaigns."}
      </div>
    </Panel>
  );
}
__CTRMON_EOF__
w 'frontend/src/components/UploadDialog.jsx' <<'__CTRMON_EOF__'
import { useEffect, useRef } from "react";
import UploadForm from "./UploadForm";

/** Native <dialog>: Esc, focus trapping and the backdrop come for free. */
export default function UploadDialog({ open, onClose, info, onCreated }) {
  const ref = useRef(null);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);
  return (
    <dialog ref={ref} className="modal" onClose={onClose} onCancel={onClose}
            onClick={(e) => { if (e.target === ref.current) onClose(); }} aria-labelledby="upload-title">
      {open && (
        <div className="modal-body">
          <div className="panel-h">
            <h2 id="upload-title">Upload data &amp; run analysis</h2>
            <span className="sub">{info?.script?.version}</span>
            <div className="tools"><button type="button" className="btn sm ghost" onClick={onClose} aria-label="Close">✕</button></div>
          </div>
          <div className="panel-b"><UploadForm info={info} onCreated={onCreated} autoFocus /></div>
        </div>
      )}
    </dialog>
  );
}
__CTRMON_EOF__
w 'frontend/src/components/UploadForm.jsx' <<'__CTRMON_EOF__'
import { useEffect, useId, useRef, useState } from "react";
import { upload } from "../api";
import { bytes } from "../format";

const ACCEPT = ".csv,.txt,.gz,.bz2,.xz,.zip";
const SPEC = {
  mapping: { title: "Mapping file", cols: 2, columns: "banner_id, campaign_id", example: "10234,517" },
  events: { title: "Events file", cols: 5, columns: "date, hour, banner_id, impressions, clicks", example: "2026-02-27,0,10234,1840,37" },
};
const isCompressed = (name) => /\.(gz|bz2|xz|zip)$/i.test(name);

/** Peek at the first lines of an uncompressed CSV — catches swapped files and header rows before upload. */
async function sniff(file) {
  if (isCompressed(file.name)) return { compressed: true };
  const text = await file.slice(0, 16384).text();
  const lines = text.split(/\r?\n/).filter((l) => l.trim()).slice(0, 3);
  const cols = lines.length ? lines[0].split(",").length : 0;
  return { compressed: false, lines, cols };
}

function problems(role, info) {
  if (!info || info.compressed) return [];
  const out = [];
  const want = SPEC[role].cols;
  if (!info.lines.length) out.push("file looks empty");
  else if (info.cols !== want) {
    const other = role === "mapping" ? "events" : "mapping";
    out.push(`expected ${want} columns, found ${info.cols}${info.cols === SPEC[other].cols ? ` — this looks like the ${other} file` : ""}`);
  } else if (role === "events" && !/^\d{4}-\d{2}-\d{2}$/.test(info.lines[0].split(",")[0].trim())) {
    out.push("first row doesn't start with a YYYY-MM-DD date — the script expects no header row");
  }
  return out;
}

function FileField({ role, file, info, onFile, onClear }) {
  const id = useId();
  const input = useRef(null);
  const [over, setOver] = useState(false);
  const spec = SPEC[role];
  const warn = problems(role, info);
  return (
    <div className={`drop${over ? " over" : ""}${file ? (warn.length ? " bad" : " has") : ""}`}
         onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)}
         onDrop={(e) => { e.preventDefault(); setOver(false); if (e.dataTransfer.files[0]) onFile(e.dataTransfer.files[0]); }}>
      <label htmlFor={id} className="drop-title">{spec.title} <span className="req">required</span></label>
      <div className="drop-cols mono">{spec.columns}</div>
      <input id={id} ref={input} type="file" accept={ACCEPT} className="sr-only"
             onChange={(e) => { if (e.target.files[0]) onFile(e.target.files[0]); e.target.value = ""; }} />
      {file ? (
        <div className="drop-file">
          <span className="fn">{file.name}</span>
          <span className="muted">{bytes(file.size)}{info?.compressed ? " · compressed" : info?.cols ? ` · ${info.cols} columns` : ""}</span>
          <span className="drop-acts">
            <button type="button" className="btn sm" onClick={() => input.current?.click()}>Change…</button>
            <button type="button" className="btn sm ghost" onClick={onClear} aria-label={`Remove ${spec.title}`}>✕</button>
          </span>
        </div>
      ) : (
        <div className="drop-pick">
          <button type="button" className="btn" onClick={() => input.current?.click()}>Choose file…</button>
          <span className="muted">or drop it here</span>
        </div>
      )}
      {info?.lines?.length > 0 && (
        <pre className="drop-preview">{info.lines.join("\n")}</pre>
      )}
      {warn.map((w) => <div key={w} className="drop-warn">⚠ {w}</div>)}
      {!file && <div className="drop-hint">CSV without header, e.g. <span className="mono">{spec.example}</span> · .gz/.bz2/.xz/.zip ok</div>}
    </div>
  );
}

/**
 * Upload the two input files (or reuse a previous run's inputs) and queue an analysis run.
 * `compact` drops the explanatory text for use at the top of a results page.
 */
export default function UploadForm({ info, fromRun, clearFrom, onCreated, compact = false, autoFocus = false }) {
  const [files, setFiles] = useState({ mapping: null, events: null });
  const [sniffs, setSniffs] = useState({ mapping: null, events: null });
  const [label, setLabel] = useState("");
  const [minImpr, setMinImpr] = useState("");
  const [dpi, setDpi] = useState("300");
  const [busy, setBusy] = useState(null);
  const [err, setErr] = useState(null);
  const firstBtn = useRef(null);
  const def = info?.script?.default_min_impr ?? 10;
  const s = info?.script;

  useEffect(() => {
    if (fromRun) { setMinImpr(String(fromRun.params?.min_impr ?? def)); setDpi(String(fromRun.params?.dpi ?? 300)); setLabel(""); }
  }, [fromRun]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (autoFocus) firstBtn.current?.querySelector("button")?.focus(); }, [autoFocus]);

  async function setFile(role, file) {
    setErr(null);
    setFiles((f) => ({ ...f, [role]: file }));
    setSniffs((x) => ({ ...x, [role]: null }));
    if (file) {
      const info2 = await sniff(file).catch(() => null);
      setSniffs((x) => ({ ...x, [role]: info2 }));
    }
  }
  const swap = () => { setFiles((f) => ({ mapping: f.events, events: f.mapping })); setSniffs((x) => ({ mapping: x.events, events: x.mapping })); };
  const swapped = sniffs.mapping?.cols === SPEC.events.cols && sniffs.events?.cols === SPEC.mapping.cols;
  const blocking = !fromRun && (problems("mapping", sniffs.mapping).length > 0 || problems("events", sniffs.events).length > 0);
  const ready = fromRun || (files.mapping && files.events);

  async function submit(e) {
    e.preventDefault();
    if (!ready) { setErr("Choose both files first."); return; }
    setErr(null);
    const f = new FormData();
    if (fromRun) f.append("from_run", fromRun.id);
    else { f.append("mapping", files.mapping); f.append("events", files.events); }
    f.append("label", label);
    f.append("min_impr", minImpr || String(def));
    f.append("dpi", dpi || "300");
    setBusy(0);
    try {
      const r = await upload(f, (p) => setBusy(p));
      setFiles({ mapping: null, events: null }); setSniffs({ mapping: null, events: null }); setLabel("");
      clearFrom?.();
      onCreated?.(r);
    } catch (e2) { setErr(e2.message); } finally { setBusy(null); }
  }

  return (
    <form onSubmit={submit} className="upload-form" noValidate>
      {s && !s.present && <div className="alert err">Analysis script not found at <span className="mono">{s.path}</span>.</div>}
      {s?.present && !s.structured && (
        <div className="alert info">This script lacks {s.missing_api.join(", ")} — runs use its own <span className="mono">main()</span> (summary &amp; files only).</div>
      )}

      {fromRun ? (
        <div className="alert info" style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
          Re-using the input files of <b>{fromRun.label}</b>
          <span className="muted">({fromRun.inputs?.events?.name}, {fromRun.inputs?.mapping?.name})</span>
          <button type="button" className="btn sm" onClick={clearFrom} style={{ marginLeft: "auto" }}>Upload new files instead</button>
        </div>
      ) : (
        <>
          <div className="grid g2" ref={firstBtn}>
            <FileField role="mapping" file={files.mapping} info={sniffs.mapping} onFile={(f) => setFile("mapping", f)} onClear={() => setFile("mapping", null)} />
            <FileField role="events" file={files.events} info={sniffs.events} onFile={(f) => setFile("events", f)} onClear={() => setFile("events", null)} />
          </div>
          {swapped && (
            <div className="alert info" style={{ display: "flex", gap: 10, alignItems: "center" }}>
              The two files look swapped.<button type="button" className="btn sm" onClick={swap}>Swap them</button>
            </div>
          )}
        </>
      )}

      <div className="form-row">
        <div className="field"><label htmlFor="up-label">Label <span className="muted">(optional)</span></label>
          <input id="up-label" type="text" placeholder={fromRun ? fromRun.label : files.events?.name || "e.g. network 2615, March"}
                 value={label} onChange={(e) => setLabel(e.target.value)} maxLength={80} /></div>
        <div className="field"><label htmlFor="up-min">Min impressions per hour</label>
          <input id="up-min" type="number" min={1} placeholder={String(def)} value={minImpr} onChange={(e) => setMinImpr(e.target.value)} /></div>
        <div className="field"><label htmlFor="up-dpi">Figure DPI</label>
          <input id="up-dpi" type="number" min={50} max={1200} value={dpi} onChange={(e) => setDpi(e.target.value)} /></div>
        <div className="field" style={{ display: "flex", alignItems: "flex-end" }}>
          <button className="btn primary lg" type="submit" disabled={busy !== null || (s && !s.present)}
                  title={blocking ? "check the file warnings above" : undefined}>
            {busy !== null ? <><span className="spin" /> {busy < 1 ? `Uploading ${Math.round(busy * 100)}%` : "Queuing…"}</> : "Upload & run analysis"}
          </button>
        </div>
      </div>
      {busy !== null && busy < 1 && <div className="progress"><div style={{ width: `${Math.round(busy * 100)}%` }} /></div>}
      {err && <div className="alert err">{err}</div>}
      {blocking && !err && <div className="drop-warn">⚠ Check the file warnings above — the run will likely fail or produce nonsense with these files.</div>}
      {!compact && (
        <div className="muted" style={{ fontSize: 11.5 }}>
          Same inputs as <span className="mono">ctr_analysis.py --mapping … --events …</span>. Files are kept with the run on this
          server so it can be re-run with other parameters. Max upload {info?.config?.max_upload_mb ?? "…"} MB.
        </div>
      )}
    </form>
  );
}
__CTRMON_EOF__
w 'frontend/src/components/ui.jsx' <<'__CTRMON_EOF__'
import { useMemo, useState } from "react";

const RUN_LABEL = { queued: "PENDING", running: "RUNNING", ok: "DONE", failed: "FAILED", cancelled: "CANCELLED" };

// The paper's four hypotheses (§3.3). Colours are categorical identity, shared with the curve-fit chart.
export const HYP_INFO = {
  H1: { short: "fatigue", long: "Exponential decay (fatigue)", desc: "CTR falls as volume rises" },
  H2: { short: "inverted-U", long: "Inverted-U (novelty → fatigue)", desc: "CTR rises, then falls" },
  H3: { short: "growth", long: "Saturating growth", desc: "CTR rises with volume" },
  H4: { short: "null", long: "Null (constant)", desc: "no detectable volume effect" },
};
export const HYP_ORDER = { H1: 0, H2: 1, H3: 2, H4: 3 };

/** Which hypothesis an estimate supports — e.g. "● H1 fatigue". `supported=false` → "H2 not supported". */
export function Hyp({ h, supported = true, sm, title }) {
  if (!h) return <span className={`hyp-badge none${sm ? " sm" : ""}`}>—</span>;
  const i = HYP_INFO[h];
  return (
    <span className={`hyp-badge h${h[1]}${supported ? "" : " rejected"}${sm ? " sm" : ""}`}
          title={title || (supported ? `${h} — ${i.long}: ${i.desc}` : `${h} (${i.long}) not supported`)}>
      <i aria-hidden="true" /><b>{h}</b>{supported ? i.short : "not supported"}
    </span>
  );
}

/** How much weight the script gives an estimate (primary, naive, descriptive, …), or "info" for non-tests. */
export function Weight({ w }) {
  if (!w) return null;
  return <span className={`wtag${w === "primary" ? " primary" : w === "info" ? " info" : ""}`}>{w}</span>;
}

/** Compact "H1×2 H3×1" counts with hypothesis-coloured dots. */
export function TallyDots({ tally }) {
  return (
    <span className="tally-dots">
      {["H1", "H2", "H3", "H4"].filter((h) => tally?.[h]).map((h) => (
        <span key={h} title={`${tally[h]} estimate(s) support ${h} (${HYP_INFO[h].short})`}>
          <i style={{ background: `var(--h${h[1]})` }} />{h}×{tally[h]}
        </span>
      ))}
    </span>
  );
}

/** Badge for one check row: hypothesis it supports, or a neutral info tag. */
export function CheckLabel({ s, sm }) {
  return s.kind === "info" ? <Weight w="info" /> : <Hyp h={s.hyp} supported={s.supported} sm={sm} />;
}

export function RunStatus({ status, sm }) {
  const s = status === "ok" ? "ok" : status;
  return (
    <span className={`st ${s}${sm ? " sm" : ""}`}>
      {status === "running" && <span className="spin" style={{ width: 9, height: 9, borderWidth: 1.5 }} />}
      {RUN_LABEL[status] || status}
    </span>
  );
}

export function Panel({ title, sub, tools, children, flush, id, className = "" }) {
  return (
    <section className={`panel ${className}`} id={id}>
      {(title || tools) && (
        <div className="panel-h">
          {title && <h2>{title}</h2>}
          {sub && <span className="sub">{sub}</span>}
          {tools && <div className="tools">{tools}</div>}
        </div>
      )}
      <div className={`panel-b${flush ? " flush" : ""}`}>{children}</div>
    </section>
  );
}

export function Seg({ value, options, onChange, label }) {
  return (
    <div className="seg" role="group" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" className={value === o.value ? "on" : ""} aria-pressed={value === o.value}
                onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

/** Chart with a table-view twin (every value reachable without hover). */
export function ChartCard({ title, sub, chart, table, tools, id }) {
  const [view, setView] = useState("chart");
  return (
    <Panel id={id} title={title} sub={sub} tools={<>{tools}
      {table && <Seg value={view} onChange={setView} label="View" options={[{ value: "chart", label: "Chart" }, { value: "table", label: "Table" }]} />}</>}
      flush={view === "table"}>
      {view === "chart" ? chart : table}
    </Panel>
  );
}

/**
 * Sortable table. columns: [{key, label, num, fmt(v,row), render(row), sort:false, sortKey(row), title}]
 */
export function DataTable({ columns, rows, initialSort, onRowClick, rowClass, maxHeight, empty = "no rows", dense }) {
  const [sort, setSort] = useState(initialSort || null);
  const sorted = useMemo(() => {
    if (!sort) return rows;
    const col = columns.find((c) => c.key === sort.key);
    if (!col) return rows;
    const get = col.sortKey || ((r) => r[col.key]);
    const dir = sort.dir === "asc" ? 1 : -1;
    return [...rows].sort((a, b) => {
      const x = get(a), y = get(b);
      if (x === y) return 0;
      if (x === null || x === undefined) return 1;
      if (y === null || y === undefined) return -1;
      return (x > y ? 1 : -1) * dir;
    });
  }, [rows, sort, columns]);
  const click = (c) => {
    if (c.sort === false) return;
    setSort((s) => (s?.key === c.key ? { key: c.key, dir: s.dir === "asc" ? "desc" : "asc" } : { key: c.key, dir: c.num ? "desc" : "asc" }));
  };
  return (
    <div className="tbl-wrap" style={maxHeight ? { maxHeight, overflowY: "auto" } : undefined}>
      <table className="tbl" style={dense ? { fontSize: 12 } : undefined}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={`${c.sort === false ? "" : "sortable"} ${c.num ? "num" : ""}`} title={c.title}
                  onClick={() => click(c)} aria-sort={sort?.key === c.key ? (sort.dir === "asc" ? "ascending" : "descending") : undefined}>
                {c.label}{sort?.key === c.key && <span className="arrow">{sort.dir === "asc" ? "▲" : "▼"}</span>}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.length === 0 && <tr><td colSpan={columns.length} className="muted" style={{ textAlign: "center", padding: 18 }}>{empty}</td></tr>}
          {sorted.map((r, i) => (
            <tr key={r.__key ?? i} className={`${onRowClick ? "clickable" : ""} ${rowClass?.(r) || ""}`}
                onClick={onRowClick ? () => onRowClick(r) : undefined}>
              {columns.map((c) => (
                <td key={c.key} className={c.num ? "num" : c.className}>
                  {c.render ? c.render(r) : c.fmt ? c.fmt(r[c.key], r) : r[c.key] ?? "—"}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Generic table for a CSV/records payload: {columns, rows: [[...]]} or records. */
export function RecordsTable({ columns, rows, maxHeight }) {
  const recs = rows.map((r, i) => ({ __key: i, ...(Array.isArray(r) ? Object.fromEntries(columns.map((c, j) => [c, r[j]])) : r) }));
  const isNum = (c) => recs.some((r) => typeof r[c] === "number") && recs.every((r) => r[c] === null || typeof r[c] === "number");
  const fmt = (v) => (typeof v === "number" ? (Number.isInteger(v) ? v.toLocaleString("en-US") : +v.toPrecision(6) + "") : v === null ? "—" : String(v));
  return (
    <DataTable maxHeight={maxHeight} dense rows={recs}
               columns={columns.map((c) => ({ key: c, label: c, num: isNum(c), fmt }))} />
  );
}

export function Empty({ title, children }) {
  return <div className="empty"><h3>{title}</h3>{children}</div>;
}

export function Tile({ label, value, foot, title }) {
  return (
    <div className="tile" title={title}>
      <div className="lbl">{label}</div>
      <div className="val">{value}</div>
      {foot && <div className="foot">{foot}</div>}
    </div>
  );
}

export const Icon = {
  overview: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="1.5" y="1.5" width="5" height="5" rx="1" /><rect x="9.5" y="1.5" width="5" height="5" rx="1" /><rect x="1.5" y="9.5" width="5" height="5" rx="1" /><rect x="9.5" y="9.5" width="5" height="5" rx="1" /></svg>,
  services: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M2 4h12M2 8h12M2 12h12" /><circle cx="4" cy="4" r="0.6" fill="currentColor" /></svg>,
  hosts: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="2" y="2" width="12" height="4.5" rx="1" /><rect x="2" y="9.5" width="12" height="4.5" rx="1" /><circle cx="4.5" cy="4.25" r="0.7" fill="currentColor" /><circle cx="4.5" cy="11.75" r="0.7" fill="currentColor" /></svg>,
  graphs: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M1.5 14.5h13" /><path d="M2 11l3.5-4 3 2.5L14 3" strokeLinejoin="round" /></svg>,
  analysis: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="4" cy="11" r="1.5" /><circle cx="8" cy="6" r="1.5" /><circle cx="12.5" cy="9" r="1.5" /><path d="M1.5 14.5h13" /></svg>,
  summary: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="2.5" y="1.5" width="11" height="13" rx="1.5" /><path d="M5 5h6M5 8h6M5 11h4" /></svg>,
  files: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M2 4.5V13a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H8L6.5 3H3a1 1 0 0 0-1 1.5z" /></svg>,
  runs: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="8" cy="8" r="6.5" /><path d="M6.5 5.5l4 2.5-4 2.5z" fill="currentColor" /></svg>,
  log: <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5" /><path d="M4 6l2 2-2 2M8 10h4" /></svg>,
};
__CTRMON_EOF__
w 'frontend/src/format.js' <<'__CTRMON_EOF__'
const MINUS = "−";
const sign = (s) => s.replace(/^-/, MINUS);
const ok = (v) => v !== null && v !== undefined && Number.isFinite(v);

export const int = (v) => (ok(v) ? Math.round(v).toLocaleString("en-US") : "—");
export const fixed = (v, d = 2) => (ok(v) ? sign(v.toFixed(d)) : "—");
export const signed = (v, d = 4) => (ok(v) ? (v > 0 ? "+" : v < 0 ? MINUS : "") + Math.abs(v).toFixed(d) : "—");
export const pct = (v, d = 2) => (ok(v) ? `${sign(v.toFixed(d))}%` : "—");
export const share = (v, d = 1) => (ok(v) ? `${(v * 100).toFixed(d)}%` : "—");

export function compact(v, d = 1) {
  if (!ok(v)) return "—";
  const a = Math.abs(v);
  const f = (x, s) => `${sign((x).toFixed(x >= 100 || Number.isInteger(x) ? 0 : d))}${s}`;
  if (a >= 1e9) return f(v / 1e9, "B");
  if (a >= 1e6) return f(v / 1e6, "M");
  if (a >= 1e4) return f(v / 1e3, "k");
  if (a >= 100) return sign(Math.round(v).toLocaleString("en-US"));
  return sign(+v.toPrecision(3) + "");
}

export function pval(p) {
  if (!ok(p)) return "—";
  if (p === 0) return "<1e−300";
  if (p < 1e-4) return sign(p.toExponential(1)).replace("e-", "e−");
  return p.toFixed(4);
}
export const stars = (p) => (!ok(p) ? "—" : p < 0.001 ? "***" : p < 0.01 ? "**" : p < 0.05 ? "*" : "n.s.");
export function conclusion(b, p) {
  if (!ok(b) || !ok(p)) return "—";
  if (p >= 0.05) return "H4";
  return b > 0 ? "H3" : "H1";
}

const pad = (n) => String(n).padStart(2, "0");
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
// data timestamps carry no zone — they are shown on the data's own clock (UTC getters)
export function dataTime(ms, mode = "full") {
  if (!ok(ms)) return "—";
  const d = new Date(ms);
  const date = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  const hm = `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
  if (mode === "date") return date;
  if (mode === "short") return `${DOW[d.getUTCDay()]} ${pad(d.getUTCDate())} ${MON[d.getUTCMonth()]} ${hm}`;
  return `${date} ${hm}`;
}
export function tickTime(ms, stepMs) {
  const d = new Date(ms);
  if (stepMs >= 864e5) return `${pad(d.getUTCDate())} ${MON[d.getUTCMonth()]}`;
  if (d.getUTCHours() === 0 && d.getUTCMinutes() === 0) return `${DOW[d.getUTCDay()]} ${pad(d.getUTCDate())}`;
  return `${pad(d.getUTCHours())}:00`;
}

export function localTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
export function ago(iso) {
  if (!iso) return "—";
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${Math.round(s)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
export function duration(sec) {
  if (!ok(sec)) return "—";
  if (sec < 1) return `${Math.round(sec * 1000)}ms`;
  if (sec < 60) return `${sec.toFixed(1)}s`;
  const m = Math.floor(sec / 60);
  return `${m}m ${Math.round(sec - m * 60)}s`;
}
export const runDuration = (r) =>
  r?.started ? duration(((r.finished ? new Date(r.finished) : new Date()) - new Date(r.started)) / 1000) : "—";
export const bytes = (n) =>
  !ok(n) ? "—" : n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`;
__CTRMON_EOF__
w 'frontend/src/hooks.js' <<'__CTRMON_EOF__'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

function parse() {
  const h = window.location.hash.replace(/^#\/?/, "");
  const [path, qs] = h.split("?");
  const parts = path.split("/").filter(Boolean).map(decodeURIComponent);
  return { page: parts[0] || "overview", parts: parts.slice(1), query: new URLSearchParams(qs || "") };
}

export function useRoute() {
  const [route, setRoute] = useState(parse);
  useEffect(() => {
    const on = () => setRoute(parse());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  return route;
}
export const go = (path) => { window.location.hash = `#/${path}`; };
export const href = (...parts) => `#/${parts.filter((p) => p !== undefined && p !== null && p !== "").map(encodeURIComponent).join("/")}`;

export function useInterval(fn, ms, enabled = true) {
  const ref = useRef(fn);
  ref.current = fn;
  useEffect(() => {
    if (!enabled) return undefined;
    const t = setInterval(() => ref.current(), ms);
    return () => clearInterval(t);
  }, [ms, enabled]);
}

export function useMeasure() {
  const ref = useRef(null);
  const [w, setW] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    setW(el.clientWidth);
    const ro = new ResizeObserver(([e]) => setW(Math.floor(e.contentRect.width)));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, w];
}

// per-viewer conveniences only — storage may be unavailable
export function useStored(key, initial) {
  const [v, setV] = useState(() => {
    try { const s = localStorage.getItem(key); return s === null ? initial : JSON.parse(s); } catch { return initial; }
  });
  const set = useCallback((nv) => {
    setV(nv);
    try { localStorage.setItem(key, JSON.stringify(nv)); } catch { /* ignore */ }
  }, [key]);
  return [v, set];
}

export function useAsync(fn, deps) {
  const [state, setState] = useState({ loading: true, data: null, error: null });
  useEffect(() => {
    let live = true;
    setState((s) => ({ ...s, loading: true, error: null }));
    Promise.resolve(fn()).then(
      (data) => live && setState({ loading: false, data, error: null }),
      (error) => live && setState({ loading: false, data: null, error }),
    );
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return state;
}
__CTRMON_EOF__
w 'frontend/src/main.jsx' <<'__CTRMON_EOF__'
import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
__CTRMON_EOF__
w 'frontend/src/pages/Analysis.jsx' <<'__CTRMON_EOF__'
import { useApp } from "../App";
import { go } from "../hooks";
import { compact, fixed, int, pct, pval, share, signed, stars } from "../format";
import { ChartCard, CheckLabel, DataTable, HYP_INFO, Panel, RecordsTable, Seg, Tile, Weight } from "../components/ui";
import { BetweenChart, BoxChart, CurvesChart, ForestChart, MarginalChart, MeanCiChart, ThresholdChart } from "../charts/Analysis";
import { HourProfile } from "../charts/Mrtg";
import { useResult } from "./common";

const TABS = [
  { value: "buckets", label: "Buckets & trend" },
  { value: "marginal", label: "Regression" },
  { value: "curves", label: "Curve fits" },
  { value: "between", label: "Total vs within" },
  { value: "threshold", label: "Threshold" },
  { value: "forest", label: "Robustness" },
];

export default function Analysis() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  if (block) return block;
  if (res.mode === "legacy") return <div className="alert info">Legacy run — open Figures &amp; Tables for the script's own outputs.</div>;
  const tab = TABS.some((t) => t.value === ctx.route.parts[0]) ? ctx.route.parts[0] : "buckets";
  const View = { buckets: Buckets, marginal: Regression, curves: Curves, between: Between, threshold: Threshold, forest: Forest }[tab];
  return (
    <>
      <div className="filters">
        <Seg value={tab} onChange={(v) => go(`analysis/${v}`)} options={TABS} label="Analysis section" />
      </div>
      <View res={res} />
    </>
  );
}

const check = (res, id) => res.checks?.services.find((s) => s.id === id);
const Label = ({ res, id }) => { const c = check(res, id); return c ? <><CheckLabel s={c} sm /> <Weight w={c.weight} /></> : null; };

function Buckets({ res }) {
  const ch = res.charts, t = res.trend;
  const ca = t.cochran_armitage, sp = t.spearman;
  return (
    <>
      <div className="grid g2">
        <ChartCard title="Hourly CTR by impression-volume bucket" sub="fig. 1 · distribution"
          chart={<BoxChart box={ch.box} />}
          table={<DataTable rows={ch.box.buckets} columns={[
            { key: "bucket", label: "Bucket" },
            { key: "range", label: "impr / h", render: (r) => r.range ? `${compact(r.range[0])} – ${r.range[1] === null ? "∞" : compact(r.range[1])}` : "—", sort: false },
            { key: "n", label: "N", num: true, fmt: int },
            { key: "q1", label: "Q1 %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "median", label: "Median %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "q3", label: "Q3 %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "mean", label: "Mean %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "zero_click_share", label: "Zero-click", num: true, fmt: (v) => share(v) },
          ]} />} />
        <ChartCard title="Mean hourly CTR with 95% CI" sub="fig. 2 · ±1.96·SEM"
          chart={<MeanCiChart rows={ch.mean_ci} />}
          table={<DataTable rows={ch.mean_ci} columns={[
            { key: "bucket", label: "Bucket" }, { key: "n", label: "N", num: true, fmt: int },
            { key: "mean", label: "Mean %", num: true, fmt: (v) => fixed(v, 4) },
            { key: "lo", label: "CI lo %", num: true, fmt: (v) => fixed(v, 4) },
            { key: "hi", label: "CI hi %", num: true, fmt: (v) => fixed(v, 4) },
          ]} />} />
      </div>
      <div className="grid g2">
        <Panel title="Trend tests" sub="§4.3 · pooled across campaigns">
          <div className="tiles" style={{ gridTemplateColumns: "repeat(2, minmax(0,1fr))" }}>
            <Tile label="Cochran–Armitage Z" value={<>{fixed(ca.Z_CA, 3)} <Label res={res} id="trend/cochran_armitage" /></>}
                  foot={<>p = {pval(ca.p)} {stars(ca.p)} · {ca.direction} → {ca.supports}<div className="caveat">⚠ {ca.note}</div></>} />
            <Tile label="Spearman ρ (bucket means)" value={<>{fixed(sp.rho, 3)} <Label res={res} id="trend/spearman_buckets" /></>}
                  foot={<>p = {pval(sp.p)} {stars(sp.p)} → {sp.supports}<div className="caveat">⚠ {sp.note}</div></>} />
          </div>
        </Panel>
        <ChartCard title="Descriptive statistics" sub="table 2 · CTR % per bucket" chart={
          <RecordsTable columns={Object.keys(res.descriptive[0] || {})} rows={res.descriptive} />} />
      </div>
      <Panel title="Hour-of-day pattern" sub="fig. 3 · split into two charts (one y-axis each)">
        <HourProfile rows={ch.hourly.map((r) => ({ hour: r.hour, impr_h: r.mean_impr, ctr: r.mean_ctr }))} ctrLabel="Mean hourly CTR" />
      </Panel>
    </>
  );
}

function coefRows(reg) {
  const row = (model, role, e, extra = {}) => ({ model, role, b: e.b, lo: e.lo, hi: e.hi, p: e.p, ...extra });
  return [
    row("M1 linear — within", "primary", reg.within, { qaic: reg.within.qaic, r2: reg.within.pseudo_r2, supports: reg.within.supports }),
    row("M2 quadratic — β₁", "primary", reg.quadratic.b1, { qaic: reg.quadratic.qaic, r2: reg.quadratic.pseudo_r2 }),
    row("M2 quadratic — β₂ (ln V²)", "primary", reg.quadratic.b2, { supports: reg.quadratic.supports }),
    row("MT total — no campaign FE", "pooled", reg.total, { r2: reg.total.pseudo_r2 }),
    row("OLS logit(CTR) — M1", "naive", reg.ols.m1, { r2: reg.ols.m1.r2, supports: reg.ols.m1.supports }),
    row("OLS logit(CTR) — M2 β₂", "naive", reg.ols.m2.b2),
  ];
}

function Regression({ res }) {
  const reg = res.regression;
  const cols = [
    { key: "model", label: "Model" }, { key: "role", label: "Role", render: (r) => <span className="tag">{r.role}</span> },
    { key: "b", label: "β", num: true, fmt: (v) => signed(v) },
    { key: "ci", label: "95% CI", num: true, sort: false, render: (r) => `[${signed(r.lo)}, ${signed(r.hi)}]` },
    { key: "p", label: "p", num: true, fmt: pval }, { key: "sig", label: "", sort: false, render: (r) => stars(r.p) },
    { key: "qaic", label: "QAIC", num: true, fmt: (v) => fixed(v, 1) },
    { key: "r2", label: "(pseudo-)R²", num: true, fmt: (v) => fixed(v, 4) },
    { key: "supports", label: "→", render: (r) => r.supports || "" },
  ];
  return (
    <>
      <ChartCard title="Marginal effect of volume on CTR" sub="fig. 4 · binomial GLM vs naive OLS"
        chart={<MarginalChart m={res.charts.marginal} />}
        table={<DataTable rows={res.charts.marginal.lv.map((lv, i) => ({ lv, glm: res.charts.marginal.glm.p[i], lo: res.charts.marginal.glm.lo[i], hi: res.charts.marginal.glm.hi[i], ols: res.charts.marginal.ols.p[i] })).filter((_, i) => i % 6 === 0)}
          columns={[{ key: "lv", label: "ln V", num: true, fmt: (v) => fixed(v, 2) }, { key: "glm", label: "GLM %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "lo", label: "band lo", num: true, fmt: (v) => fixed(v, 3) }, { key: "hi", label: "band hi", num: true, fmt: (v) => fixed(v, 3) },
            { key: "ols", label: "OLS %", num: true, fmt: (v) => fixed(v, 3) }]} />} />
      <Panel title="Coefficients on ln(V)" sub="§4.4 · clustered SE by campaign" flush>
        <DataTable rows={coefRows(reg)} columns={cols} />
        <div className="chart-note" style={{ padding: "8px 14px 12px" }}>
          Overdispersion φ = {fixed(reg.phi, 2)} — raw AIC is not comparable; ΔQAIC(M2−M1) = {fixed(reg.quadratic.dqaic, 1)}
          {" "}(raw ΔAIC {fixed(reg.quadratic.daic, 1)}). Odds ratio per doubling of impressions (within): {fixed(reg.within.or_doubling[0], 4)}.
        </div>
      </Panel>
    </>
  );
}

function Curves({ res }) {
  const models = res.curves.models;
  return (
    <ChartCard title="Hypothesis curves fitted to the five bucket means" sub="fig. 5 · §4.5"
      chart={<><CurvesChart curves={res.curves} />
        <div style={{ marginTop: 12 }}><DataTable rows={models} columns={[
          { key: "model", label: "Model" }, { key: "params", label: "Params", className: "mono" },
          { key: "k", label: "k", num: true }, { key: "r2", label: "R²", num: true, fmt: (v) => fixed(v, 4) },
          { key: "rmse", label: "RMSE", num: true, fmt: (v) => fixed(v, 5) }, { key: "aic", label: "AIC", num: true, fmt: (v) => fixed(v, 2) },
          { key: "bic", label: "BIC", num: true, fmt: (v) => fixed(v, 2) },
          { key: "best", label: "Best", render: (r) => r.failed ? <span className="tag">failed</span> : r.best ? <span className="tag outline">best AIC</span> : "" },
        ]} /></div></>}
      table={<DataTable rows={res.curves.buckets} columns={[{ key: "bucket", label: "Bucket", fmt: (v) => `B${v}` },
        { key: "mean_logv", label: "mean ln V", num: true, fmt: (v) => fixed(v, 4) }, { key: "mean_ctr", label: "mean CTR %", num: true, fmt: (v) => fixed(v, 4) }]} />} />
  );
}

function Between({ res }) {
  const dec = res.regression.decomposition, bc = res.between.stats;
  return (
    <div className="grid g-side">
      <ChartCard title="Campaign CTR vs mean volume" sub="fig. 6 · click a campaign for its traffic graphs"
        chart={<BetweenChart campaigns={res.between.campaigns} lines={res.charts.between} onPick={(c) => go(`graphs/${encodeURIComponent(c)}`)} />}
        table={<DataTable rows={res.between.campaigns} maxHeight={420} initialSort={{ key: "impr", dir: "desc" }} columns={[
          { key: "campaign", label: "Campaign", className: "mono" }, { key: "n_obs", label: "Hours", num: true, fmt: int },
          { key: "impr", label: "Impr", num: true, fmt: (v) => compact(v) }, { key: "ctr", label: "CTR %", num: true, fmt: (v) => fixed(v, 3) },
          { key: "mean_logv", label: "mean ln V", num: true, fmt: (v) => fixed(v, 3) }]} />} />
      <Panel title="Decomposition" sub="§4.7 — not a hypothesis test; compares pooled and within slopes">
        <dl className="kv" style={{ fontSize: 12.5 }}>
          <dt>β_total</dt><dd className="mono">{signed(dec.b_total)} {stars(dec.p_total)} <span className="muted">p={pval(dec.p_total)}</span></dd>
          <dt>β_within</dt><dd className="mono">{signed(dec.b_within)} {stars(dec.p_within)} <span className="muted">p={pval(dec.p_within)}</span></dd>
          <dt>composition</dt><dd className="mono">{signed(dec.diff)}</dd>
          <dt>Spearman ρ</dt><dd className="mono">{signed(bc.spearman_rho, 3)} <span className="muted">p={pval(bc.spearman_p)}</span></dd>
          <dt>Kendall τ</dt><dd className="mono">{signed(bc.kendall_tau, 3)} <span className="muted">p={pval(bc.kendall_p)}</span></dd>
          <dt>Campaigns</dt><dd className="mono">{int(bc.n_campaigns)}</dd>
        </dl>
        <div className={`verdict ${dec.expected ? "ok" : "warn"}`} style={{ marginTop: 12 }}>{dec.message}</div>
        <div className="chart-note">β_total − β_within is the between-campaign (composition) component, in logit-per-ln(V) units.</div>
      </Panel>
    </div>
  );
}

function Threshold({ res }) {
  const rows = res.robustness.threshold;
  return (
    <ChartCard title="Sensitivity to the minimum-impression threshold" sub="fig. 7 · §4.6d — GLM should stay put, naive OLS should move"
      chart={<ThresholdChart rows={rows} />}
      table={<RecordsTable columns={Object.keys(rows[0] || {}).filter((c) => !c.includes("ci_"))} rows={rows} />} />
  );
}

function Forest({ res }) {
  const rb = res.robustness;
  const both = (r, name) => [
    { label: `${name} · GLM`, est: "GLM", b: r["GLM β₁"], lo: r.glm_ci_lo, hi: r.glm_ci_hi, p: r["GLM p"] },
    { label: `${name} · OLS`, est: "OLS", b: r["OLS-logit β₁"], lo: r.ols_ci_lo, hi: r.ols_ci_hi, p: r["OLS p"] },
  ];
  const groups = [
    { title: "Specification (§4.6b)", rows: rb.spec.map((r) => ({
      label: r.Role, full: r.Specification, est: r.Specification.startsWith("WLS") ? "WLS" : r.Specification.includes("GLM") ? "GLM" : "OLS",
      b: r["β₁"], lo: r.ci_lo, hi: r.ci_hi, p: r.p })) },
    { title: "Campaign size quartiles (§4.6a)", caveat: true, rows: rb.size.flatMap((r) => both(r, r.Quartile)) },
    { title: "Temporal halves (§4.6c)", rows: rb.temporal.flatMap((r) => both(r, r.Period)) },
    { title: "Min-impression threshold (§4.6d)", rows: rb.threshold.flatMap((r) => both(r, r.Filter)) },
  ];
  const hypOf = (r) => (r.b === null || r.p === null ? null : r.p >= 0.05 ? "H4" : r.b > 0 ? "H3" : "H1");
  return (
    <>
      <Panel title="Every β₁ on ln(V) in the robustness battery" sub="point = estimate, line = 95% CI, colour = hypothesis it supports">
        <ForestChart groups={groups} hypOf={hypOf} />
        <div className="legend" style={{ marginTop: 8 }}>
          <span>Colour = hypothesis supported:</span>
          {["H1", "H3", "H4"].map((h) => <span key={h}><i className="key dot" style={{ background: `var(--h${h[1]})` }} />{h} {HYP_INFO[h].short}</span>)}
          <span className="muted">· marker = model: ● GLM, ○ OLS (naive), ■ WLS</span>
        </div>
      </Panel>
      <div className="grid g2">
        <ChartCard title="Campaign size quartiles" sub="table 6" chart={<RecordsTable columns={Object.keys(rb.size[0] || {}).filter((c) => !c.includes("ci_"))} rows={rb.size} />} />
        <ChartCard title="Temporal halves" sub="table 8" chart={<RecordsTable columns={Object.keys(rb.temporal[0] || {}).filter((c) => !c.includes("ci_"))} rows={rb.temporal} />} />
      </div>
      <ChartCard title="Specification variants" sub="table 7" chart={<RecordsTable columns={Object.keys(rb.spec[0] || {}).filter((c) => !c.includes("ci_"))} rows={rb.spec} />} />
    </>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Campaigns.jsx' <<'__CTRMON_EOF__'
import { useState } from "react";
import { useApp } from "../App";
import { go } from "../hooks";
import { compact, fixed, int, share } from "../format";
import { DataTable, Hyp, Panel } from "../components/ui";
import { Sparkline } from "../charts/Mrtg";
import { useResult } from "./common";

const Q_ORDER = { Q1: 1, Q2: 2, Q3: 3, Q4: 4 };

export default function Campaigns() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const [q, setQ] = useState("");
  const quart = ctx.route.query.get("q");   // size-quartile filter lives in the URL (cards are rendered by App)
  if (block) return block;
  const quartiles = res.size_quartiles || [];
  const byQ = Object.fromEntries(quartiles.map((x) => [x.short, x]));
  const n = q.trim().toLowerCase();
  const rows = (res.between?.campaigns || [])
    .filter((c) => (!n || c.campaign.toLowerCase().includes(n)) && (!quart || c.size_q === quart))
    .map((c) => ({ ...c, __key: c.campaign }));
  return (
    <>
      <Panel title="Campaigns" flush
             sub={`${rows.length} campaigns${quart ? ` in ${byQ[quart]?.label}` : " in the analysis dataset"} — click a row for its traffic graphs`}
             tools={<>
               {quart && <button type="button" className="btn sm" onClick={() => go("campaigns")}>{quart} only ✕</button>}
               <input type="search" placeholder="Filter campaign id…" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 180 }} />
             </>}>
        <DataTable rows={rows} initialSort={{ key: "impr", dir: "desc" }} onRowClick={(r) => go(`graphs/${encodeURIComponent(r.campaign)}`)}
          columns={[
            { key: "campaign", label: "Campaign", render: (r) => <span className="mono" style={{ fontWeight: 600 }}>{r.campaign}</span> },
            ...(quartiles.length ? [{
              key: "size_q", label: "Size quartile", sortKey: (r) => Q_ORDER[r.size_q] ?? 9,
              title: "campaign's size group and the hypothesis that group's GLM slope supports (§4.6a)",
              render: (r) => r.size_q ? (
                <span style={{ display: "inline-flex", gap: 6, alignItems: "center", whiteSpace: "nowrap" }}>
                  <span className="mono" style={{ fontSize: 11.5 }}>{r.size_q}</span>
                  {byQ[r.size_q]?.tested && <Hyp h={byQ[r.size_q].hyp} sm />}
                </span>) : <span className="muted">—</span>,
            }] : []),
            { key: "flags", label: "Flags", sortKey: (r) => r.outlier_hours, render: (r) => r.outlier_hours
                ? <span className="wtag" title="hours with CTR > 20% — flagged by the script, not removed">{r.outlier_hours}h CTR&gt;20%</span>
                : <span className="muted">—</span> },
            { key: "n_obs", label: "Hours", num: true, fmt: int },
            { key: "impr", label: "Impressions", num: true, fmt: (v) => compact(v) },
            { key: "clicks", label: "Clicks", num: true, fmt: (v) => compact(v) },
            { key: "ctr", label: "CTR %", num: true, fmt: (v) => fixed(v, 3) },
            { key: "median_impr", label: "Median impr/h", num: true, fmt: (v) => compact(v) },
            { key: "mean_logv", label: "mean ln V", num: true, fmt: (v) => fixed(v, 2) },
            { key: "zero_click_share", label: "Zero-click", num: true, fmt: (v) => share(v) },
            { key: "first", label: "Active", sortKey: (r) => r.first, render: (r) => <span className="mono muted nowrap" style={{ fontSize: 11 }}>{r.first?.slice(5, 16).replace("T", " ")} → {r.last?.slice(5, 16).replace("T", " ")}</span> },
            { key: "spark", label: "Daily CTR", sort: false, render: (r) => <Sparkline values={r.spark} /> },
          ]} />
      </Panel>
    </>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Files.jsx' <<'__CTRMON_EOF__'
import { useState } from "react";
import { useApp } from "../App";
import { api, bundleUrl, fileUrl } from "../api";
import { useAsync } from "../hooks";
import { bytes } from "../format";
import { DataTable, Empty, Panel, RecordsTable } from "../components/ui";
import { useResult } from "./common";

export default function Files() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const [table, setTable] = useState(null);
  const t = useAsync(() => (table && ctx.run ? api.table(ctx.run.id, table) : null), [ctx.run?.id, table]);
  if (block) return block;
  const run = ctx.run;
  const figs = res.figures || [];
  const files = (res.files || []).filter((f) => f.kind !== "preview");
  return (
    <>
      <Panel title="Publication figures" sub="rendered by the script itself (PDF) · PNG previews"
             tools={<a className="btn sm primary" href={bundleUrl(run.id)}>Download all (.zip)</a>}>
        {figs.length === 0 ? <Empty title="No figures" /> : (
          <div className="gallery">
            {figs.map((f) => (
              <div key={f.name} className="panel fig">
                <div className="img">{f.png ? <img src={fileUrl(run.id, f.png)} alt={f.name} loading="lazy" /> : <span className="muted">no preview</span>}</div>
                <div className="cap"><b className="mono" style={{ fontSize: 11.5 }}>{f.name}</b>{f.caption && <div className="muted" style={{ marginTop: 3 }}>↳ {f.caption}</div>}</div>
                <div className="acts">
                  <a className="btn sm" href={fileUrl(run.id, f.file)} target="_blank" rel="noreferrer">Open PDF</a>
                  <a className="btn sm" href={fileUrl(run.id, f.file, true)}>Download</a>
                  {f.png && <a className="btn sm ghost" href={fileUrl(run.id, f.png, true)}>PNG</a>}
                </div>
              </div>
            ))}
          </div>
        )}
      </Panel>
      <div className="grid g-side" style={{ gridTemplateColumns: "minmax(0,380px) minmax(0,1fr)" }}>
        <Panel title="Output files" sub={`${files.length}`} flush>
          <DataTable rows={files.map((f) => ({ ...f, __key: f.name }))} onRowClick={(f) => f.kind === "table" && setTable(f.name)}
            rowClass={(f) => (f.name === table ? "expanded" : "")}
            columns={[
              { key: "name", label: "File", render: (f) => <span className="mono" style={{ fontSize: 11.5 }}>{f.name}</span> },
              { key: "kind", label: "Kind", render: (f) => <span className="tag">{f.kind}</span> },
              { key: "size", label: "Size", num: true, fmt: bytes },
              { key: "dl", label: "", sort: false, render: (f) => <a href={fileUrl(run.id, f.name, true)} onClick={(e) => e.stopPropagation()}>↓</a> },
            ]} />
        </Panel>
        <Panel title={table || "Table viewer"} sub={table ? "click another CSV to switch" : "click a CSV on the left"} flush>
          {!table ? <Empty title="No table selected" /> : t.error ? <div className="alert err" style={{ margin: 14 }}>{t.error.message}</div>
            : !t.data ? <Empty title="Loading…" /> : <RecordsTable columns={t.data.columns} rows={t.data.rows} maxHeight={560} />}
        </Panel>
      </div>
    </>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Graphs.jsx' <<'__CTRMON_EOF__'
import { useMemo, useState } from "react";
import { useApp } from "../App";
import { api } from "../api";
import { href, useAsync } from "../hooks";
import { compact, dataTime, int, pct } from "../format";
import { Empty, Hyp, Panel } from "../components/ui";
import { HourProfile, MrtgWindow, Sparkline } from "../charts/Mrtg";
import { useResult } from "./common";

export default function Graphs() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const campaign = ctx.route.parts[0] || null;
  const [q, setQ] = useState("");
  const m = useAsync(() => (ctx.run ? api.mrtg(ctx.run.id, campaign) : null), [ctx.run?.id, campaign]);
  const list = useMemo(() => {
    const n = q.trim().toLowerCase();
    return (res?.between?.campaigns || []).filter((c) => !n || c.campaign.toLowerCase().includes(n));
  }, [res, q]);
  if (block) return block;
  const info = (res.between?.campaigns || []).find((c) => c.campaign === campaign);
  const d = m.data;

  const quart = info?.size_q && (res.size_quartiles || []).find((x) => x.short === info.size_q);
  return (
    <>
    <div className="g-pick">
      <Panel title="Campaigns" sub={`${list.length}`} flush
             tools={<input type="search" placeholder="Filter…" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 110 }} />}>
        <div className="picker">
          <a href={href("graphs")} className={!campaign ? "active" : ""}>
            <span><b>All campaigns</b><div className="sub">aggregate traffic</div></span>
          </a>
          {list.map((c) => (
            <a key={c.campaign} href={href("graphs", c.campaign)} className={campaign === c.campaign ? "active" : ""}>
              <span style={{ minWidth: 0 }}>
                <span className="mono">{c.campaign}</span>
                <div className="sub">{compact(c.impr)} impr · {pct(c.ctr, 2)}</div>
              </span>
              <Sparkline values={c.spark} width={70} height={20} />
            </a>
          ))}
        </div>
      </Panel>

      <div style={{ display: "flex", flexDirection: "column", gap: 16, minWidth: 0 }}>
        <Panel title={<>Traffic Analysis for <span className="mono">{campaign ? `campaign ${campaign}` : "all campaigns"}</span></>}
               sub="hourly panel after data-quality exclusions, before the min-impression filter"
               tools={campaign && <a className="btn sm" href={href("campaigns")}>campaign table</a>}>
          {m.error ? <div className="alert err">{m.error.message}</div> : !d ? <Empty title="Loading…" /> : (
            <>
              <div className="mrtg-head" style={{ marginBottom: 18 }}>
                <div><span>Run</span><span>{ctx.run.label}</span></div>
                <div><span>Data window</span><span className="mono">{dataTime(d.range[0], "date")} → {dataTime(d.range[1] - 1, "date")}</span></div>
                <div><span>Active hours</span><span className="mono">{int(d.totals.active_hours)} / {int(d.totals.hours)}</span></div>
                <div><span>First active</span><span className="mono">{d.totals.first?.replace("T", " ").slice(0, 16) || "—"}</span></div>
                <div><span>Last active</span><span className="mono">{d.totals.last?.replace("T", " ").slice(0, 16) || "—"}</span></div>
                <div><span>Impressions</span><span className="mono">{int(d.totals.impr)}</span></div>
                <div><span>Clicks</span><span className="mono">{int(d.totals.clicks)}</span></div>
                <div><span>Pooled CTR</span><span className="mono">{pct(d.totals.impr ? d.totals.clicks / d.totals.impr * 100 : null, 3)}</span></div>
                {info && <div><span>Campaign-hours (analysis)</span><span className="mono">{int(info.n_obs)}</span></div>}
                {info && <div><span>Hours with CTR &gt; 20%</span><span className="mono">{int(info.outlier_hours)}</span></div>}
                {quart && (
                  <div title="this campaign's size group and the hypothesis that group's GLM slope supports (§4.6a); not a test of this campaign alone">
                    <span>Size quartile</span>
                    <span style={{ display: "inline-flex", gap: 6, alignItems: "center" }}><span className="mono">{quart.label}</span>{quart.tested && <Hyp h={quart.hyp} sm />}</span>
                  </div>
                )}
              </div>
              <div className="mrtg-grid">
                {d.windows.map((w) => <MrtgWindow key={w.key} w={w} />)}
              </div>
              <div className="chart-note" style={{ marginTop: 12 }}>
                Times are on the data's own clock (no time zone in the source). Hours without an event row count as zero traffic; CTR is undefined where a bin has no impressions.
              </div>
            </>
          )}
        </Panel>
        {d && (
          <Panel title="Hour-of-day profile" sub="pooled over the whole data window">
            <HourProfile rows={d.profile} ctrLabel="Pooled CTR" />
          </Panel>
        )}
      </div>
    </div>
    </>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Overview.jsx' <<'__CTRMON_EOF__'
import { useApp } from "../App";
import { api } from "../api";
import { go, href, useAsync, useStored } from "../hooks";
import { compact, conclusion, fixed, int, pct, pval, share, signed, stars } from "../format";
import { CheckLabel, Empty, Hyp, HYP_ORDER, Panel, Tile, Weight } from "../components/ui";
import UploadForm from "../components/UploadForm";
import { MrtgWindow } from "../charts/Mrtg";
import { HYP } from "../charts/Analysis";
import { NoRun } from "./common";

const EQ = {
  H1: "CTR = a·exp(−b·V) + g", H2: "CTR = a·V^b·exp(−g·V)", H3: "CTR = g − a·exp(−b·V)", H4: "CTR = μ",
};

function evidence(res) {
  const r = res.regression, t = res.trend;
  const first = (s) => (String(s || "").match(/^H\d/) || [null])[0];
  const best = res.curves.models.find((m) => m.best);
  return [
    { h: conclusion(r.within.b, r.within.p), label: "GLM within", kind: "primary", view: "analysis/marginal" },
    { h: r.quadratic.supports?.startsWith("H2") ? "H2" : null, label: "GLM quadratic", kind: "primary", view: "analysis/curves" },
    { h: conclusion(r.total.b, r.total.p), label: "GLM total (pooled)", kind: "pooled", view: "analysis/between" },
    { h: conclusion(r.ols.m1.b, r.ols.m1.p), label: "OLS logit", kind: "naive", view: "analysis/marginal" },
    { h: first(t.cochran_armitage.supports), label: "Cochran–Armitage", kind: "descriptive", view: "analysis/buckets" },
    { h: first(t.spearman.supports), label: "Spearman (5 means)", kind: "low power", view: "analysis/buckets" },
    { h: best?.key, label: "Curve fit (best AIC)", kind: "illustrative", view: "analysis/curves" },
  ].filter((e) => e.h);
}

export function UploadPanel() {
  const { info, refresh } = useApp();
  const [open, setOpen] = useStored("ctr.upload.open", true);
  return (
    <Panel title="Upload data & run analysis" sub={open ? "mapping + hourly events → new run" : "collapsed"}
           tools={<button type="button" className="btn sm ghost" onClick={() => setOpen(!open)} aria-expanded={open}>{open ? "Hide ▴" : "Show ▾"}</button>}
           className={open ? "" : "collapsed"}>
      {open && <UploadForm info={info} compact onCreated={(r) => { refresh(); go(`runs/${r.id}`); }} />}
    </Panel>
  );
}

export default function Overview() {
  const { run, res, resErr, runs } = useApp();
  if (!run) return <NoRun runs={runs} />;
  return <OverviewBody run={run} res={res} resErr={resErr} />;
}

function OverviewBody({ res, resErr }) {
  if (resErr) return <div className="alert err">Could not load results: {resErr.message}</div>;
  if (!res) return <Empty title="Loading results…" />;
  if (res.mode === "legacy") {
    return (
      <Panel title="Legacy run">
        <p>The analysis script in this run did not expose the functions the structured view needs, so only its own
          outputs are available — see <a href={href("summary")}>Results Summary</a> and <a href={href("files")}>Figures &amp; Tables</a>.</p>
      </Panel>
    );
  }

  const ds = res.dataset, reg = res.regression, w = reg.within, dec = reg.decomposition;
  const svc = res.checks.services;
  const primary = res.checks.primary;
  const nHyp = res.checks.n_hypothesis;
  const dissent = svc.filter((s) => s.kind === "hypothesis" && s.supported && s.hyp && s.hyp !== primary)
    .sort((a, b) => HYP_ORDER[a.hyp] - HYP_ORDER[b.hyp]);
  const ev = evidence(res);
  const lead = conclusion(w.b, w.p);
  const pooled = ds.totals ? ds.totals.clicks / ds.totals.impr * 100 : null;

  return (
    <>
      <div className="grid g-side">
        <Panel title="Within-campaign effect of impression volume on CTR" sub="primary specification · §4.4"
               tools={primary && <Hyp h={primary} />}>
          <div className="hero">
            <div>
              <div className="muted" style={{ fontSize: 11.5, marginBottom: 4 }}>β₁ on ln(V), binomial GLM</div>
              <div className="big">{signed(w.b, 3)}<small>{stars(w.p)}</small></div>
              <div className="mono muted" style={{ marginTop: 6 }}>95% CI [{signed(w.lo, 3)}, {signed(w.hi, 3)}] · p = {pval(w.p)}</div>
            </div>
            <dl className="kv" style={{ fontSize: 12.5, marginTop: 4 }}>
              <dt>Verdict</dt><dd><b>{w.supports}</b></dd>
              <dt>Odds ratio per 2× volume</dt><dd className="mono">{fixed(w.or_doubling[0], 4)} [{fixed(w.or_doubling[1], 4)}, {fixed(w.or_doubling[2], 4)}]</dd>
              <dt>Pooled slope (no campaign FE)</dt><dd className="mono">{signed(reg.total.b, 4)} {stars(reg.total.p)}</dd>
              <dt>Naive OLS slope</dt><dd className="mono">{signed(reg.ols.m1.b, 4)} {stars(reg.ols.m1.p)}</dd>
              <dt>H2 (quadratic)</dt><dd>{reg.quadratic.supports}</dd>
              <dt>Fit</dt><dd className="mono">pseudo-R² {fixed(w.pseudo_r2, 4)} · QAIC {fixed(w.qaic, 1)} · N {int(w.nobs)}</dd>
            </dl>
          </div>
          <div className={`verdict ${dec.expected ? "ok" : "warn"}`} style={{ marginTop: 14 }}>
            <b>Total vs within (§4.7):</b> β_total {signed(dec.b_total, 4)} {stars(dec.p_total)} − β_within {signed(dec.b_within, 4)} {stars(dec.p_within)} = {signed(dec.diff, 4)} composition. {dec.message}
          </div>
        </Panel>
        <Panel title="Estimates that disagree" sub={`${dissent.length} of ${nHyp} point away from ${primary || "the primary result"}`} flush
               tools={<a className="btn sm" href={`${href("services")}?filter=disagree`}>details</a>}>
          {dissent.length === 0 ? <Empty title={`All estimates agree on ${primary}`} /> : (
            <div style={{ maxHeight: 330, overflowY: "auto" }}>
              {dissent.map((s) => (
                <a key={s.id} href={`${href("services")}?focus=${encodeURIComponent(s.id)}`}
                   style={{ display: "grid", gridTemplateColumns: "118px minmax(0,1fr)", gap: 10, padding: "8px 14px", borderBottom: "1px solid var(--border)", color: "inherit", textDecoration: "none" }}>
                  <span style={{ display: "flex", flexDirection: "column", gap: 3, alignItems: "flex-start" }}>
                    <CheckLabel s={s} sm /><Weight w={s.weight} />
                  </span>
                  <span style={{ minWidth: 0 }}>
                    <div style={{ fontWeight: 600, fontSize: 12 }}>{s.host} <span className="muted">/</span> {s.service}</div>
                    <div className="mono muted" style={{ fontSize: 11, overflowWrap: "anywhere" }}>{s.output}</div>
                  </span>
                </a>
              ))}
            </div>
          )}
        </Panel>
      </div>

      <div className="tiles">
        <Tile label="Campaign-hours analysed" value={int(ds.n_final)} foot={`${int(ds.n_raw)} raw event rows`} />
        <Tile label="Campaigns" value={int(ds.n_campaigns)} foot={`${int(ds.n_banners)} banners`} />
        <Tile label="Date range" value={<span style={{ fontSize: 14 }}>{ds.date_range}</span>} />
        <Tile label="Impressions" value={compact(ds.totals?.impr)} foot={`${compact(ds.totals?.clicks)} clicks`} />
        <Tile label="Pooled CTR" value={pct(pooled, 3)} />
        <Tile label="Zero-click hours" value={share(ds.zero_click_share)} />
        <Tile label="Overdispersion φ" value={fixed(reg.phi, 2)} foot="Pearson χ²/df" />
        <Tile label="Min impressions / h" value={int(ds.min_impr)} foot="inclusion threshold" />
      </div>

      <Panel title="Hypothesis board" sub="which estimate points where — the primary specification is outlined">
        <div className="hyp">
          {["H1", "H2", "H3", "H4"].map((h) => {
            const items = ev.filter((e) => e.h === h);
            return (
              <div key={h} className={`card${h === lead ? " lead" : ""}`}>
                <h4><span className="k">{h}</span>{HYP[h].name}</h4>
                <div className="eq">{EQ[h]}</div>
                <div className="ev">
                  {items.length === 0 && <span className="muted" style={{ fontSize: 11.5 }}>no support</span>}
                  {items.map((e) => (
                    <a key={e.label} href={href(...e.view.split("/"))} className={`tag ${e.kind === "primary" ? "primary" : ""}`}
                       title={e.kind}>{e.label}{e.kind !== "primary" && <span style={{ opacity: 0.65 }}> · {e.kind}</span>}</a>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </Panel>

      <OverviewTraffic />
    </>
  );
}

function OverviewTraffic() {
  const { run } = useApp();
  const m = useAsync(() => api.mrtg(run.id), [run.id]);
  const w = m.data?.windows?.find((x) => x.key === "weekly");
  return (
    <Panel title="All campaigns — traffic" sub="MRTG view of the hourly panel" tools={<a className="btn sm" href={href("graphs")}>all graphs</a>}>
      {m.error ? <div className="alert err">{m.error.message}</div> : !w ? <Empty title="Loading…" /> : <MrtgWindow w={w} compactMode />}
    </Panel>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Runs.jsx' <<'__CTRMON_EOF__'
import { useEffect, useRef, useState } from "react";
import { useApp } from "../App";
import { api } from "../api";
import { go, href, useAsync, useInterval } from "../hooks";
import { bytes, duration, localTime, runDuration } from "../format";
import { DataTable, Empty, Hyp, Panel, RunStatus, TallyDots } from "../components/ui";
import EvidenceTally from "../components/EvidenceTally";
import QuartileCards from "../components/QuartileCards";
import UploadForm from "../components/UploadForm";
import PlainSummary from "../components/PlainSummary";

export default function Runs() {
  const { route } = useApp();
  return route.parts[0] ? <RunDetail id={route.parts[0]} /> : <RunsHome />;
}

function RunsHome() {
  const { runs, info, refresh, select } = useApp();
  const [fromRun, setFromRun] = useState(null);
  const formRef = useRef(null);
  const rerun = (r) => { setFromRun(r); formRef.current?.scrollIntoView({ behavior: "smooth" }); };
  const act = async (fn) => { try { await fn(); } catch (e) { alert(e.message); } refresh(); };

  return (
    <>
      <div ref={formRef}>
        <Panel title="Upload data & run analysis" sub={info?.script?.version || ""}>
          <UploadForm info={info} fromRun={fromRun} clearFrom={() => setFromRun(null)} onCreated={(r) => { refresh(); go(`runs/${r.id}`); }} />
        </Panel>
      </div>
      <Panel title="Run history" sub={runs ? `${runs.length} runs` : ""} flush>
        <DataTable rows={(runs || []).map((r) => ({ ...r, __key: r.id }))} initialSort={{ key: "created", dir: "desc" }} empty="no runs yet"
          onRowClick={(r) => go(`runs/${r.id}`)}
          columns={[
            { key: "status", label: "Status", render: (r) => <RunStatus status={r.status} sm /> },
            { key: "label", label: "Label", render: (r) => <b style={{ display: "inline-block", minWidth: 110 }}>{r.label}</b> },
            { key: "finding", label: "Finding", sort: false, render: (r) => <Finding id={r.id} status={r.status} /> },
            { key: "created", label: "Created", render: (r) => <span className="nowrap">{localTime(r.created)}</span> },
            { key: "dur", label: "Duration", num: true, sort: false, render: (r) => runDuration(r) },
            { key: "params", label: "Params", sort: false, render: (r) => <span className="mono muted nowrap">min={r.params?.min_impr} dpi={r.params?.dpi}</span> },
            { key: "checks", label: "Evidence", sort: false, render: (r) => r.tally ? <TallyDots tally={r.tally} /> : r.error ? <span className="mono" style={{ color: "var(--crit-text)", fontSize: 11 }}>{String(r.error).slice(0, 80)}</span> : "—" },
            { key: "act", label: "", sort: false, render: (r) => (
              <span style={{ display: "inline-flex", gap: 4 }} onClick={(e) => e.stopPropagation()}>
                {r.status === "ok" && <button className="btn sm" onClick={() => { select(r.id); go("overview"); }}>Results</button>}
                {(r.status === "queued" || r.status === "running") && <button className="btn sm" onClick={() => act(() => api.cancel(r.id))}>Cancel</button>}
                {r.inputs && <button className="btn sm" onClick={() => rerun(r)}>Re-run…</button>}
                <button className="btn sm ghost danger" title="Delete run and its files"
                        onClick={() => window.confirm(`Delete run ${r.id} and all its files?`) && act(() => api.remove(r.id))}>✕</button>
              </span>) },
          ]} />
      </Panel>
    </>
  );
}


/** One-line headline of the run's plain-language summary; hover for the full text. */
function Finding({ id, status }) {
  const n = useAsync(() => (status === "ok" ? api.narrative(id) : null), [id, status]);
  if (status !== "ok" || n.error) return <span className="muted">—</span>;
  if (!n.data) return <span className="muted">…</span>;
  return (
    <span className="finding" title={n.data.text}>
      {n.data.hyp && <Hyp h={n.data.hyp} sm />}<span>{n.data.headline}</span>
    </span>
  );
}

function colorize(text) {
  return text.split("\n").map((ln, i) => {
    const cls = /\[WARN\]|⚠/.test(ln) ? "w" : /✓|✅/.test(ln) ? "ok" : /^── /.test(ln) ? "h" : /Traceback|Error|Exception/.test(ln) ? "e" : null;
    return <span key={i} className={cls || undefined}>{ln}{"\n"}</span>;
  });
}

function RunDetail({ id }) {
  const { refresh, select, runs } = useApp();
  const [run, setRun] = useState(null);
  const [err, setErr] = useState(null);
  const [log, setLog] = useState({ text: "", offset: 0 });
  const box = useRef(null);
  const stick = useRef(true);
  const activeNow = run && (run.status === "queued" || run.status === "running");
  const runRes = useAsync(() => (run?.status === "ok" ? api.result(run.id) : null), [run?.id, run?.status]);

  const off = useRef(0);
  const inflight = useRef(false);
  const load = () => api.run(id).then(setRun, setErr);
  const pull = () => {
    if (inflight.current) return;
    inflight.current = true;
    const at = off.current;
    api.log(id, at).then((r) => {
      if (off.current !== at) return;          // run switched meanwhile
      off.current = r.offset;
      if (r.text) setLog((l) => ({ text: (l.text + r.text).slice(-400_000), offset: r.offset }));
    }, () => {}).finally(() => { inflight.current = false; });
  };
  useEffect(() => { setRun(null); setLog({ text: "", offset: 0 }); off.current = 0; load(); }, [id]); // eslint-disable-line
  useEffect(() => { if (run) pull(); }, [run?.id, run?.status]); // eslint-disable-line
  useInterval(() => { load(); pull(); }, 1500, !!activeNow);
  useEffect(() => { if (stick.current && box.current) box.current.scrollTop = box.current.scrollHeight; }, [log.text]);
  useEffect(() => { refresh(); }, [run?.status]); // eslint-disable-line

  if (err) return <div className="alert err">{err.message} — <a href={href("runs")}>back to runs</a></div>;
  if (!run) return <Empty title="Loading…" />;
  const pr = run.progress;
  const known = (runs || []).some((r) => r.id === id);
  return (
    <>
      <div className="filters"><a className="btn sm" href={href("runs")}>← All runs</a></div>
      {run.status === "ok" && <PlainSummary runId={run.id} runLabel={run.label} collapsible onFull={() => { select(run.id); go("summary"); }} />}
      {runRes.data?.checks && <div className="tally-row"><EvidenceTally checks={runRes.data.checks} showPrimary runLabel={run.label} collapsible /></div>}
      {runRes.data?.size_quartiles?.length > 0 && (
        <QuartileCards quartiles={runRes.data.size_quartiles} collapsible runLabel={run.label}
                       onSelect={(q) => { select(run.id); go(`campaigns?q=${q}`); }} />
      )}
      <div className="grid g-side">
        <Panel title="Event log" sub="worker stdout — the script's own console output" flush
               tools={activeNow && <span className="muted" style={{ fontSize: 11.5 }}><span className="dot running pulse" /> live</span>}>
          <pre className="console" ref={box} onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollTop + el.clientHeight >= el.scrollHeight - 30; }}>
            {log.text ? colorize(log.text) : <span className="muted">{run.status === "queued" ? "waiting for a worker slot…" : "no output yet"}</span>}
          </pre>
        </Panel>
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <Panel title={run.label} tools={<RunStatus status={run.status} />}>
            <dl className="kv">
              <dt>Run id</dt><dd className="mono">{run.id}</dd>
              <dt>Created</dt><dd>{localTime(run.created)}</dd>
              <dt>Started</dt><dd>{localTime(run.started)}</dd>
              <dt>Finished</dt><dd>{localTime(run.finished)}</dd>
              <dt>Duration</dt><dd>{runDuration(run)}</dd>
              <dt>Params</dt><dd className="mono">min-impr={run.params?.min_impr} dpi={run.params?.dpi}</dd>
              <dt>Mapping</dt><dd>{run.inputs?.mapping?.name} <span className="muted">({bytes(run.inputs?.mapping?.size)})</span></dd>
              <dt>Events</dt><dd>{run.inputs?.events?.name} <span className="muted">({bytes(run.inputs?.events?.size)})</span></dd>
              <dt>Script</dt><dd>{run.script?.version} <span className="mono muted">{run.script?.sha256?.slice(0, 10)}</span></dd>
            </dl>
            <div style={{ display: "flex", gap: 6, marginTop: 12, flexWrap: "wrap" }}>
              {run.status === "ok" && <button className="btn primary sm" onClick={() => { select(run.id); go("overview"); }}>Open results</button>}
              {activeNow && <button className="btn sm" onClick={() => api.cancel(run.id).then(load, (e) => alert(e.message))}>Cancel run</button>}
              {!known && <span className="muted">deleted</span>}
            </div>
          </Panel>
          {pr?.stages && (
            <Panel title="Stages" flush sub={pr.peak_gb != null ? `peak memory ${pr.peak_gb.toFixed(1)} GB` : undefined}>
              <table className="tbl"><tbody>
                {pr.stages.map((s, i) => {
                  const t = pr.times?.[s.key];
                  const cur = pr.current === s.key && run.status === "running";
                  return (
                    <tr key={s.key}>
                      <td style={{ width: 22 }}><i className={`dot ${t !== undefined ? "ok" : cur ? "running pulse" : run.status === "failed" && i === pr.index ? "critical" : "pending"}`} /></td>
                      <td>{s.label}</td>
                      <td className="num">{t !== undefined ? duration(t) : cur ? "…" : ""}</td>
                      <td className="num muted" title="worker's peak memory by the end of this stage">
                        {pr.mem?.[s.key] != null ? `${pr.mem[s.key].toFixed(1)} GB` : cur && pr.peak_gb != null ? `${pr.peak_gb.toFixed(1)} GB…` : ""}
                      </td>
                    </tr>
                  );
                })}
              </tbody></table>
            </Panel>
          )}
          {run.status === "failed" && (
            <Panel title="Failure">
              <div className="alert err">{run.error}</div>
              {run.traceback && <pre className="console" style={{ marginTop: 10, borderRadius: 6, maxHeight: 280 }}>{run.traceback}</pre>}
            </Panel>
          )}
        </div>
      </div>
    </>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Services.jsx' <<'__CTRMON_EOF__'
import { Fragment, useEffect, useState } from "react";
import { useApp } from "../App";
import { go, href } from "../hooks";
import { duration } from "../format";
import { CheckLabel, Hyp, HYP_ORDER, Panel, Seg, TallyDots, Weight } from "../components/ui";
import { useResult } from "./common";

const FILTERS = [
  { value: "all", label: "All" }, { value: "disagree", label: "Disagrees with primary" },
  { value: "H1", label: "H1" }, { value: "H2", label: "H2" }, { value: "H3", label: "H3" }, { value: "H4", label: "H4" },
  { value: "info", label: "Info" },
];

export const disagrees = (s, primary) => s.kind === "hypothesis" && s.supported && s.hyp && s.hyp !== primary;

function matches(s, filter, primary) {
  if (filter === "all") return true;
  if (filter === "info") return s.kind === "info";
  if (filter === "disagree") return disagrees(s, primary);
  return s.kind === "hypothesis" && s.hyp === filter && s.supported;
}

export default function Services() {
  const ctx = useApp();
  const { block, res } = useResult(ctx);
  const q = ctx.route.query;
  const filter = q.get("filter") || "all";
  const focus = q.get("focus");
  const [search, setSearch] = useState("");
  const [order, setOrder] = useState("group");
  const [open, setOpen] = useState(() => new Set(focus ? [focus] : []));
  useEffect(() => {
    if (!focus) return;
    setOpen((o) => new Set([...o, focus]));
    setTimeout(() => document.getElementById(`svc-${focus}`)?.scrollIntoView({ block: "center" }), 50);
  }, [focus]);
  if (block) return block;
  if (!res.checks) return <div className="alert info">This run has no structured results (legacy mode).</div>;

  const { primary } = res.checks;
  const groups0 = Object.fromEntries(res.checks.groups.map((g) => [g.id, g]));
  const needle = search.trim().toLowerCase();
  let rows = res.checks.services.filter((s) => matches(s, filter, primary) &&
    (!needle || `${s.host} ${s.service} ${s.output} ${s.hyp || ""} ${s.weight || ""}`.toLowerCase().includes(needle)));
  if (order === "hyp") {
    const key = (s) => (s.kind === "info" ? 9 : (HYP_ORDER[s.hyp] ?? 8) + (s.supported ? 0 : 4));
    rows = [...rows].sort((a, b) => key(a) - key(b));
  }

  const groups = [];
  for (const s of rows) {
    const g = order === "group" ? groups.find((x) => x.host === s.host) : null;
    if (g) g.rows.push(s); else groups.push({ host: s.host, rows: [s] });
  }
  const toggle = (id) => setOpen((o) => { const n = new Set(o); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const setFilter = (v) => go(v === "all" ? "services" : `services?filter=${v}`);

  return (
    <Panel title="Estimates by hypothesis" sub={`${rows.length} rows · primary result: ${primary || "—"}`} flush
           tools={<>
             <input type="search" placeholder="Search…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 160 }} />
             <Seg value={filter} onChange={setFilter} options={FILTERS} label="Filter" />
             <Seg value={order} onChange={setOrder} label="Order" options={[{ value: "group", label: "By section" }, { value: "hyp", label: "By hypothesis" }]} />
           </>}>
      <div className="tbl-wrap">
        <table className="tbl">
          <thead>
            <tr><th>Section</th><th>Estimate</th><th>Supports</th><th>Weight</th><th className="num" title="time spent in the pipeline stage that produced this row">Stage time</th><th>Details</th></tr>
          </thead>
          <tbody>
            {groups.length === 0 && <tr><td colSpan={6} className="muted" style={{ textAlign: "center", padding: 24 }}>Nothing matches.</td></tr>}
            {groups.map((g) => {
              const span = g.rows.reduce((n, s) => n + (open.has(s.id) ? 2 : 1), 0);
              const gi = groups0[g.host];
              return g.rows.map((s, i) => (
                <Fragment key={s.id}>
                  <tr id={`svc-${s.id}`} className={`clickable ${s.primary ? "row-primary" : ""} ${i === 0 ? "grp-start" : ""} ${open.has(s.id) ? "expanded" : ""}`}
                      onClick={() => toggle(s.id)}>
                    {(i === 0 || order !== "group") && (
                      <td className="host" rowSpan={order === "group" ? span : 1} onClick={(e) => e.stopPropagation()}>
                        <div>{gi?.name || g.host}</div>
                        {order === "group" && <div className="hd">{gi?.desc}</div>}
                        {order === "group" && <div style={{ marginTop: 4 }}><TallyDots tally={gi?.tally} /></div>}
                      </td>
                    )}
                    <td className="svc">
                      <span className="muted" style={{ display: "inline-block", width: 12 }}>{open.has(s.id) ? "▾" : "▸"}</span>{s.service}
                    </td>
                    <td><CheckLabel s={s} /></td>
                    <td><Weight w={s.kind === "info" ? null : s.weight} /></td>
                    <td className="num">{duration(s.duration)}</td>
                    <td className="info">{s.output}{s.note && <div className="caveat" style={{ marginTop: 2 }}>⚠ {s.note}</div>}</td>
                  </tr>
                  {open.has(s.id) && (
                    <tr><td colSpan={order === "group" ? 5 : 6} style={{ padding: 0 }}><Detail s={s} /></td></tr>
                  )}
                </Fragment>
              ));
            })}
          </tbody>
        </table>
      </div>
      <Legend />
    </Panel>
  );
}

function Detail({ s }) {
  return (
    <div className="detail">
      <div style={{ display: "flex", gap: 16, flexWrap: "wrap", alignItems: "baseline" }}>
        <span className="mono">{s.id}</span>
        {s.view && <a href={href(...s.view.split("/"))}>open chart →</a>}
      </div>
      {s.note && <div className="caveat" style={{ marginTop: 6 }}>⚠ {s.note}</div>}
      {s.detail?.length > 0 && (
        <dl className="kv" style={{ marginTop: 8, fontSize: 12 }}>
          {s.detail.map(([k, v]) => <Fragment key={k}><dt>{k}</dt><dd className="mono">{v}</dd></Fragment>)}
        </dl>
      )}
      {s.perf && <div className="perf"><span className="muted">perfdata │ </span>{s.perf}</div>}
    </div>
  );
}

function Legend() {
  return (
    <div className="muted" style={{ padding: "10px 14px 12px", fontSize: 11.5, lineHeight: 1.9, borderTop: "1px solid var(--border)" }}>
      <div>
        <Hyp h="H1" sm /> slope β &lt; 0, p &lt; .05 &nbsp;·&nbsp; <Hyp h="H2" sm /> quadratic β₂ &lt; 0 with β₁ &gt; 0, p &lt; .05
        &nbsp;·&nbsp; <Hyp h="H3" sm /> slope β &gt; 0, p &lt; .05 &nbsp;·&nbsp; <Hyp h="H4" sm /> p ≥ .05 — the same rule as the script's <span className="mono">conclusion()</span>.
      </div>
      <div>
        Weight: <Weight w="primary" /> the paper's main specification · <Weight w="pooled" /> no campaign FE ·{" "}
        <Weight w="naive" /> unweighted OLS, kept for comparison · <Weight w="descriptive" /> / <Weight w="low power" /> /{" "}
        <Weight w="few clusters" /> / <Weight w="SE only" /> p-values the script itself flags as approximate ·{" "}
        <Weight w="illustrative" /> five-point curve fit · <Weight w="info" /> not a hypothesis test.
      </div>
    </div>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/Summary.jsx' <<'__CTRMON_EOF__'
import { useState } from "react";
import { useApp } from "../App";
import { api, fileUrl } from "../api";
import { useAsync } from "../hooks";
import { Empty, Panel } from "../components/ui";
import { NoRun } from "./common";

function useCopy() {
  const [copied, setCopied] = useState(null);
  const copy = (key, text) => navigator.clipboard?.writeText(text || "").then(
    () => { setCopied(key); setTimeout(() => setCopied(null), 1500); }, () => {});
  return [copied, copy];
}

export default function Summary() {
  const { run, runs } = useApp();
  const t = useAsync(() => (run ? api.text(run.id, "results_summary.txt") : null), [run?.id]);
  const [copied, copy] = useCopy();
  if (!run) return <NoRun runs={runs} />;
  return (
    <>
      <Panel title="results_summary.txt" sub="verbatim output of write_summary()" flush
             tools={<>
               <button className="btn sm" onClick={() => copy("raw", t.data)} disabled={!t.data}>{copied === "raw" ? "Copied" : "Copy"}</button>
               <a className="btn sm" href={fileUrl(run.id, "results_summary.txt", true)}>Download</a>
             </>}>
        {t.error ? <div className="alert err" style={{ margin: 14 }}>{t.error.message}</div>
          : t.loading ? <Empty title="Loading…" /> : <pre className="summary-pre">{t.data}</pre>}
      </Panel>
    </>
  );
}
__CTRMON_EOF__
w 'frontend/src/pages/common.jsx' <<'__CTRMON_EOF__'
import { useApp } from "../App";
import { go } from "../hooks";
import { Empty, Panel } from "../components/ui";
import UploadForm from "../components/UploadForm";

export function NoRun({ runs }) {
  const { info, refresh } = useApp();
  if (runs === null) return <Empty title="Loading…" />;
  const active = runs.some((r) => r.status === "queued" || r.status === "running");
  if (active) {
    return (
      <Empty title="First run in progress…">
        <p>Results appear here as soon as the run finishes.</p>
        <a className="btn primary" href="#/runs">Watch progress</a>
      </Empty>
    );
  }
  return (
    <Panel title="Upload data & run analysis" sub="no completed analysis yet — start with your two input files">
      <UploadForm info={info} onCreated={(r) => { refresh(); go(`runs/${r.id}`); }} autoFocus />
    </Panel>
  );
}
export function useResult(ctx) {
  const { run, res, resErr } = ctx;
  if (!run) return { block: <NoRun runs={ctx.runs} /> };
  if (resErr) return { block: <div className="alert err">Could not load results: {resErr.message}</div> };
  if (!res) return { block: <Empty title="Loading results…" /> };
  return { res };
}
__CTRMON_EOF__
w 'frontend/src/styles.css' <<'__CTRMON_EOF__'
/* ─────────────────────────────────────────────────────────────────────────
   CTR Monitor — Nagios/MRTG structure, quiet modern skin.
   Light is the fallback; dark follows the OS unless the toggle pins a theme.
   ───────────────────────────────────────────────────────────────────────── */
:root {
  color-scheme: light;
  --font-sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --font-mono: ui-monospace, "SF Mono", "JetBrains Mono", "Cascadia Mono", Menlo, Consolas, monospace;

  --page: #f9f9f7;
  --surface: #fcfcfb;
  --surface-2: #f3f2ee;
  --surface-3: #eae9e4;
  --ink: #0b0b0b;
  --ink-2: #52514e;
  --muted: #898781;
  --grid: #e1e0d9;
  --axis: #c3c2b7;
  --border: rgba(11, 11, 11, 0.10);
  --border-strong: rgba(11, 11, 11, 0.18);
  --hover: rgba(11, 11, 11, 0.04);
  --shadow: 0 1px 2px rgba(0, 0, 0, 0.04), 0 4px 16px rgba(0, 0, 0, 0.04);

  /* sidebar stays dark in both themes — the Nagios left frame */
  --side: #121312;
  --side-2: #1c1d1b;
  --side-ink: #e9e8e2;
  --side-muted: #8d8b84;
  --side-border: rgba(255, 255, 255, 0.07);

  /* categorical series (validated: adjacent + 3-slot all-pairs) */
  --s1: #2a78d6;  /* blue   — CTR, GLM, within */
  --s2: #eb6834;  /* orange — naive OLS, total */
  --s3: #1baf7a;  /* aqua   — impressions (MRTG "in") */
  --s4: #eda100;  /* yellow */
  --pts: #a9a7a0;
  --accent: #2a78d6;
  --accent-ink: #1c5cab;

  /* Nagios states — reserved for status, always with a label */
  --ok: #0ca30c;
  --warn: #fab219;
  --crit: #d03b3b;
  --unk: #ec835a;
  --pend: #9a988f;
  --run: #2a78d6;
  --on-ok: #0b0b0b;
  --on-warn: #0b0b0b;
  --on-crit: #ffffff;
  --on-unk: #0b0b0b;
  --on-pend: #0b0b0b;
  --ok-text: #006300;
  --crit-text: #b42323;
  --warn-text: #8a5b00;

  --r: 8px;
  --r-sm: 5px;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page: #0d0d0d;
    --surface: #1a1a19;
    --surface-2: #222220;
    --surface-3: #2b2b29;
    --ink: #ffffff;
    --ink-2: #c3c2b7;
    --muted: #898781;
    --grid: #2c2c2a;
    --axis: #383835;
    --border: rgba(255, 255, 255, 0.09);
    --border-strong: rgba(255, 255, 255, 0.16);
    --hover: rgba(255, 255, 255, 0.04);
    --shadow: none;
    --side: #0a0a0a;
    --side-2: #161615;
    --s1: #3987e5;
    --s2: #d95926;
    --s3: #199e70;
    --s4: #c98500;
    --pts: #6e6c66;
    --accent: #3987e5;
    --accent-ink: #86b6ef;
    --ok-text: #0ca30c;
    --crit-text: #e66767;
    --warn-text: #fab219;
    --run: #3987e5;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page: #0d0d0d;
  --surface: #1a1a19;
  --surface-2: #222220;
  --surface-3: #2b2b29;
  --ink: #ffffff;
  --ink-2: #c3c2b7;
  --muted: #898781;
  --grid: #2c2c2a;
  --axis: #383835;
  --border: rgba(255, 255, 255, 0.09);
  --border-strong: rgba(255, 255, 255, 0.16);
  --hover: rgba(255, 255, 255, 0.04);
  --shadow: none;
  --side: #0a0a0a;
  --side-2: #161615;
  --s1: #3987e5;
  --s2: #d95926;
  --s3: #199e70;
  --s4: #c98500;
  --pts: #6e6c66;
  --accent: #3987e5;
  --accent-ink: #86b6ef;
  --ok-text: #0ca30c;
  --crit-text: #e66767;
  --warn-text: #fab219;
  --run: #3987e5;
}

* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  background: var(--page);
  color: var(--ink);
  font: 13px/1.45 var(--font-sans);
  -webkit-font-smoothing: antialiased;
}
a { color: var(--accent-ink); text-decoration: none; }
a:hover { text-decoration: underline; }
button, input, select { font: inherit; color: inherit; }
code, pre, .mono { font-family: var(--font-mono); font-size: 12px; }
.num { font-variant-numeric: tabular-nums; }
.muted { color: var(--muted); }
.ink2 { color: var(--ink-2); }
.nowrap { white-space: nowrap; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }

/* ── layout ─────────────────────────────────────────────────────────────── */
.app { display: grid; grid-template-columns: 228px minmax(0, 1fr); min-height: 100vh; }
.main { display: flex; flex-direction: column; min-width: 0; }
.content { padding: 18px 22px 48px; display: flex; flex-direction: column; gap: 16px; min-width: 0; }

/* ── sidebar (Nagios left frame) ────────────────────────────────────────── */
.sidebar {
  background: var(--side); color: var(--side-ink); border-right: 1px solid var(--side-border);
  position: sticky; top: 0; height: 100vh; overflow-y: auto; display: flex; flex-direction: column;
}
.brand { display: flex; align-items: center; gap: 10px; padding: 16px 16px 14px; border-bottom: 1px solid var(--side-border); }
.brand-mark { width: 30px; height: 30px; border-radius: 7px; background: var(--side-2); display: grid; place-items: center; }
.brand-name { font-weight: 650; letter-spacing: 0.2px; font-size: 14px; }
.brand-name b { color: #3987e5; font-weight: 650; }
.brand-sub { font-size: 10.5px; color: var(--side-muted); font-family: var(--font-mono); }
.nav { padding: 8px 0 12px; flex: 1; }
.nav-h { font-size: 10px; text-transform: uppercase; letter-spacing: 1.1px; color: var(--side-muted); padding: 14px 18px 5px; font-weight: 600; }
.nav a {
  display: flex; align-items: center; gap: 9px; padding: 5px 18px 5px 16px; color: var(--side-ink);
  border-left: 2px solid transparent; font-size: 12.5px; opacity: 0.86;
}
.nav a:hover { background: var(--side-2); text-decoration: none; opacity: 1; }
.nav a.active { border-left-color: #3987e5; background: var(--side-2); opacity: 1; font-weight: 550; }
.nav a .count { margin-left: auto; font-family: var(--font-mono); font-size: 10.5px; padding: 0 6px; border-radius: 9px; line-height: 16px; }
.nav svg { flex: none; opacity: 0.75; }
.side-foot { padding: 12px 16px 16px; border-top: 1px solid var(--side-border); font-size: 10.5px; color: var(--side-muted); font-family: var(--font-mono); line-height: 1.5; word-break: break-word; }

/* ── top bar ────────────────────────────────────────────────────────────── */
.topbar {
  position: sticky; top: 0; z-index: 20; display: flex; align-items: center; gap: 12px;
  padding: 9px 22px; background: color-mix(in srgb, var(--page) 88%, transparent); flex-wrap: wrap; row-gap: 8px;
  backdrop-filter: blur(8px); border-bottom: 1px solid var(--border);
}
.topbar .crumb { font-weight: 600; font-size: 14px; }
.topbar .crumb .muted { font-weight: 400; }
.topbar .spacer { flex: 1; }
.menu-btn { display: none; }
.run-select { display: flex; align-items: center; gap: 8px; }
.run-select select { max-width: min(340px, 34vw); }

select, input[type="text"], input[type="number"], input[type="search"] {
  background: var(--surface); border: 1px solid var(--border-strong); border-radius: var(--r-sm);
  padding: 5px 8px; min-height: 30px; outline: none;
}
select:focus, input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 22%, transparent); }
.btn {
  display: inline-flex; align-items: center; gap: 6px; padding: 5px 11px; min-height: 30px; border-radius: var(--r-sm);
  border: 1px solid var(--border-strong); background: var(--surface); cursor: pointer; font-size: 12.5px; white-space: nowrap;
}
.btn:hover { background: var(--surface-2); text-decoration: none; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
.btn.primary:hover { filter: brightness(1.08); }
.btn.danger:hover { color: var(--crit-text); border-color: var(--crit); }
.btn:disabled { opacity: 0.5; cursor: default; }
.btn.sm { padding: 2px 8px; min-height: 24px; font-size: 11.5px; }
.btn.ghost { border-color: transparent; background: transparent; }
.btn.ghost:hover { background: var(--hover); }
.seg { display: inline-flex; border: 1px solid var(--border-strong); border-radius: var(--r-sm); overflow: hidden; }
.seg button { border: 0; background: transparent; padding: 4px 10px; cursor: pointer; font-size: 12px; min-height: 28px; display: inline-flex; align-items: center; gap: 6px; }
.seg button + button { border-left: 1px solid var(--border); }
.seg button.on { background: var(--surface-3); font-weight: 600; }

/* ── panels ─────────────────────────────────────────────────────────────── */
.panel { background: var(--surface); border: 1px solid var(--border); border-radius: var(--r); box-shadow: var(--shadow); min-width: 0; }
.panel-h {
  display: flex; align-items: center; gap: 10px; padding: 9px 14px; border-bottom: 1px solid var(--border);
  background: linear-gradient(to bottom, var(--surface-2), var(--surface));
  border-radius: var(--r) var(--r) 0 0; min-height: 40px; flex-wrap: wrap;
}
.panel-h h2, .panel-h h3 { margin: 0; font-size: 12.5px; font-weight: 650; letter-spacing: 0.15px; }
.panel-h .sub { color: var(--muted); font-size: 11.5px; }
.panel-h .tools { margin-left: auto; display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
.panel-b { padding: 14px; min-width: 0; }
.panel-b.flush { padding: 0; }
.grid { display: grid; gap: 16px; min-width: 0; }
.g2 { grid-template-columns: repeat(2, minmax(0, 1fr)); }
.g3 { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.g-side { grid-template-columns: minmax(0, 1fr) 340px; }
.section-title { font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: var(--muted); font-weight: 600; margin: 6px 0 -4px; }

/* ── Nagios status header strip ─────────────────────────────────────────── */
.strip { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.infobox { padding: 12px 14px; font-size: 12px; }
.infobox .title { font-weight: 650; font-size: 13px; margin-bottom: 6px; display: flex; align-items: center; gap: 8px; }
.kv { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 3px 12px; }
.kv dt { color: var(--muted); }
.kv dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.totals { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); border: 1px solid var(--border); border-radius: var(--r-sm); overflow: hidden; }
.totals > div { text-align: center; padding: 6px 2px 7px; border-left: 1px solid var(--border); min-width: 0; }
.totals > div:first-child { border-left: 0; }
.totals .lbl { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.totals .val { font-size: 20px; font-weight: 600; line-height: 1.3; }
.totals button { all: unset; display: block; cursor: pointer; }
.totals > div:hover { background: var(--hover); }
.totals .zero { color: var(--muted); font-weight: 400; }

/* ── status cells / pills ───────────────────────────────────────────────── */
.st {
  display: inline-flex; align-items: center; justify-content: center; gap: 5px; min-width: 78px; padding: 2px 8px;
  border-radius: 4px; font: 700 10.5px/16px var(--font-mono); letter-spacing: 0.5px; text-transform: uppercase; white-space: nowrap;
}
.st.ok { background: var(--ok); color: var(--on-ok); }
.st.warning { background: var(--warn); color: var(--on-warn); }
.st.critical { background: var(--crit); color: var(--on-crit); }
.st.unknown { background: var(--unk); color: var(--on-unk); }
.st.pending, .st.queued, .st.cancelled { background: var(--pend); color: var(--on-pend); }
.st.running { background: var(--run); color: #fff; }
.st.failed { background: var(--crit); color: var(--on-crit); }
.st.sm { min-width: 0; padding: 0 6px; font-size: 9.5px; line-height: 15px; }
.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; flex: none; box-shadow: 0 0 0 2px var(--surface); }
.dot.ok { background: var(--ok); } .dot.warning { background: var(--warn); } .dot.critical { background: var(--crit); }
.dot.unknown { background: var(--unk); } .dot.pending { background: var(--pend); } .dot.running { background: var(--run); }
.pulse { animation: pulse 1.6s ease-in-out infinite; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }
.tag { display: inline-block; padding: 0 6px; border-radius: 4px; background: var(--surface-3); color: var(--ink-2); font-size: 10.5px; line-height: 17px; white-space: nowrap; }
.tag.outline { background: transparent; border: 1px solid var(--border-strong); }

/* ── tables (Nagios status details) ─────────────────────────────────────── */
.tbl-wrap { overflow-x: auto; }
table.tbl { border-collapse: separate; border-spacing: 0; width: 100%; font-size: 12.5px; }
.tbl th {
  position: sticky; top: 0; text-align: left; font-weight: 600; font-size: 11px; color: var(--ink-2); padding: 7px 10px;
  background: var(--surface-2); border-bottom: 1px solid var(--border-strong); white-space: nowrap; user-select: none;
}
.tbl th.sortable { cursor: pointer; }
.tbl th.sortable:hover { color: var(--ink); }
.tbl th .arrow { color: var(--accent); margin-left: 3px; }
.tbl td { padding: 6px 10px; border-bottom: 1px solid var(--border); vertical-align: middle; }
.tbl tbody tr:hover td { background: var(--hover); }
.tbl tr.clickable { cursor: pointer; }
.tbl td.r, .tbl th.r { text-align: right; }
.tbl td.num, .tbl th.num { text-align: right; font-variant-numeric: tabular-nums; font-family: var(--font-mono); font-size: 11.5px; }
.tbl td.host { font-weight: 600; white-space: nowrap; vertical-align: top; border-right: 1px solid var(--border); }
.tbl td.host .hd { color: var(--muted); font-weight: 400; font-size: 11px; }
.tbl tr.grp-start td { border-top: 1px solid var(--border-strong); }
.tbl td.info { font-family: var(--font-mono); font-size: 11.5px; color: var(--ink-2); overflow-wrap: anywhere; min-width: 280px; }
.tbl td.svc { white-space: nowrap; font-weight: 550; }
.tbl tr.expanded td { background: var(--surface-2); }
.detail { padding: 10px 14px 14px; background: var(--surface-2); border-bottom: 1px solid var(--border); font-size: 12px; }
.detail .perf { font-family: var(--font-mono); font-size: 11.5px; color: var(--ink-2); background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-sm); padding: 6px 8px; margin-top: 6px; overflow-wrap: anywhere; }
.caveat { color: var(--warn-text); }

.filters { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }

/* ── stat tiles / hero ──────────────────────────────────────────────────── */
.tiles { display: grid; grid-template-columns: repeat(8, minmax(0, 1fr)); gap: 12px; }
@media (max-width: 1500px) { .tiles { grid-template-columns: repeat(4, minmax(0, 1fr)); } }
@media (max-width: 640px) { .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.tile { background: var(--surface); border: 1px solid var(--border); border-radius: var(--r); padding: 10px 12px; min-width: 0; }
.tile .lbl { font-size: 11px; color: var(--muted); }
.tile .val { font-size: 19px; font-weight: 600; margin-top: 2px; overflow-wrap: anywhere; }
.tile .foot { font-size: 11px; color: var(--ink-2); margin-top: 2px; }
.hero { display: flex; gap: 22px; align-items: flex-start; flex-wrap: wrap; }
.hero .big { font-size: 48px; font-weight: 600; line-height: 1; letter-spacing: -1px; }
.hero .big small { font-size: 18px; font-weight: 500; color: var(--muted); letter-spacing: 0; margin-left: 4px; }
.verdict { border-left: 3px solid var(--accent); padding: 8px 12px; background: var(--surface-2); border-radius: 0 var(--r-sm) var(--r-sm) 0; font-size: 13px; }
.verdict.warn { border-left-color: var(--warn); }
.verdict.ok { border-left-color: var(--ok); }

/* hypothesis board */
.hyp { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
.hyp .card { border: 1px solid var(--border); border-radius: var(--r); padding: 10px 11px; background: var(--surface); min-width: 0; }
.hyp .card.lead { border-color: var(--accent); box-shadow: inset 0 3px 0 var(--accent); }
.hyp .card h4 { margin: 0; font-size: 12.5px; display: flex; gap: 6px; align-items: baseline; }
.hyp .card h4 .k { font-family: var(--font-mono); color: var(--muted); font-weight: 500; }
.hyp .card .eq { font-family: var(--font-mono); font-size: 10.5px; color: var(--muted); margin: 2px 0 8px; }
.hyp .ev { display: flex; flex-wrap: wrap; gap: 4px; }
.hyp .ev .tag.primary { background: var(--accent); color: #fff; }

/* ── charts ─────────────────────────────────────────────────────────────── */
.chart { position: relative; width: 100%; min-width: 0; }
.chart svg { display: block; overflow: visible; }
.chart text { fill: var(--muted); font-size: 10.5px; font-family: var(--font-sans); font-variant-numeric: tabular-nums; }
.chart .axis-title { fill: var(--ink-2); font-size: 11px; }
.chart .gridline { stroke: var(--grid); stroke-width: 1; shape-rendering: crispEdges; }
.chart .baseline { stroke: var(--axis); stroke-width: 1; shape-rendering: crispEdges; }
.chart .zero { stroke: var(--ink-2); stroke-width: 1; opacity: 0.55; }
.chart .xhair { stroke: var(--ink-2); stroke-width: 1; opacity: 0.45; pointer-events: none; }
.chart .watermark { fill: var(--muted); opacity: 0.5; font-size: 8.5px; letter-spacing: 1.5px; font-family: var(--font-mono); }
.tip {
  position: absolute; z-index: 5; pointer-events: none; background: var(--surface); border: 1px solid var(--border-strong);
  border-radius: 6px; padding: 7px 9px; font-size: 11.5px; box-shadow: 0 6px 24px rgba(0, 0, 0, 0.18); min-width: 140px; white-space: nowrap;
}
.tip .t { font-weight: 600; margin-bottom: 3px; }
.tip .r { display: flex; align-items: center; gap: 6px; justify-content: space-between; }
.tip .r > span:first-child { display: inline-flex; align-items: center; gap: 6px; color: var(--ink-2); }
.tip .r b { font-weight: 600; font-variant-numeric: tabular-nums; }
.key { width: 14px; height: 3px; border-radius: 2px; display: inline-block; flex: none; }
.key.area { height: 10px; border-radius: 2px; }
.key.dot { width: 8px; height: 8px; border-radius: 50%; }
.legend { display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 11.5px; color: var(--ink-2); padding: 2px 0 6px; }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.legend .off { opacity: 0.5; text-decoration: line-through; }
.chart-note { font-size: 11px; color: var(--muted); margin-top: 6px; }

/* MRTG graph block */
.mrtg { display: grid; grid-template-columns: minmax(0, 1fr); gap: 4px; }
.mrtg-title { font-family: var(--font-mono); font-size: 12px; font-weight: 650; display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
.mrtg-title .muted { font-weight: 400; }
.mrtg-legend { width: 100%; border-collapse: collapse; font-size: 11.5px; margin-top: 4px; }
.mrtg-legend th { text-align: right; color: var(--muted); font-weight: 500; padding: 3px 8px; border-bottom: 1px solid var(--border); font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.5px; }
.mrtg-legend th:first-child { text-align: left; }
.mrtg-legend td { text-align: right; padding: 3px 8px; font-family: var(--font-mono); font-variant-numeric: tabular-nums; }
.mrtg-legend td:first-child { text-align: left; font-family: var(--font-sans); display: flex; align-items: center; gap: 7px; }
.mrtg-head { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 2px 18px; font-size: 12px; }
.mrtg-head div { display: flex; justify-content: space-between; gap: 8px; border-bottom: 1px dotted var(--border-strong); padding: 3px 0; }
.mrtg-head span:first-child { color: var(--muted); }

/* campaign picker list */
.picker { max-height: calc(100vh - 210px); overflow-y: auto; }
.picker a { display: grid; grid-template-columns: minmax(0, 1fr) 70px; gap: 8px; align-items: center; padding: 5px 12px; color: var(--ink); border-bottom: 1px solid var(--border); font-size: 12px; }
.picker a:hover { background: var(--hover); text-decoration: none; }
.picker a.active { background: var(--surface-3); box-shadow: inset 2px 0 0 var(--accent); }
.picker .sub { font-size: 10.5px; color: var(--muted); font-family: var(--font-mono); }

/* console / log */
.console {
  background: #0b0c0b; color: #d6d5cf; font: 11.5px/1.5 var(--font-mono); padding: 12px 14px; border-radius: 0 0 var(--r) var(--r);
  max-height: 520px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; margin: 0;
}
.console .w { color: #fab219; } .console .ok { color: #3ec43e; } .console .h { color: #86b6ef; } .console .e { color: #ff7b7b; }
.summary-pre { margin: 0; padding: 16px 18px; font: 12px/1.5 var(--font-mono); white-space: pre; overflow: auto; max-height: 75vh; background: var(--surface); color: var(--ink); border-radius: 0 0 var(--r) var(--r); }

/* progress */
.stages { display: flex; gap: 3px; margin-top: 8px; }
.stages > div { flex: 1; height: 5px; border-radius: 3px; background: var(--surface-3); }
.stages > div.done { background: var(--ok); }
.stages > div.cur { background: var(--run); animation: pulse 1.2s ease-in-out infinite; }
.runbar { display: flex; align-items: center; gap: 10px; padding: 7px 22px; background: color-mix(in srgb, var(--run) 10%, var(--page)); border-bottom: 1px solid var(--border); font-size: 12px; }
.runbar .stages { margin: 0; width: 220px; }

/* upload */
.drop {
  border: 1.5px dashed var(--border-strong); border-radius: var(--r); padding: 14px; text-align: center; cursor: pointer;
  background: var(--surface-2); transition: border-color 0.15s, background 0.15s; min-width: 0;
}
.drop:hover, .drop.over { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 6%, var(--surface-2)); }
.drop.has { border-style: solid; border-color: color-mix(in srgb, var(--ok) 60%, transparent); }
.drop .fn { font-family: var(--font-mono); font-size: 12px; overflow-wrap: anywhere; }
.form-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.field label { display: block; font-size: 11px; color: var(--muted); margin-bottom: 4px; }
.field input, .field select { width: 100%; }
.alert { padding: 9px 12px; border-radius: var(--r-sm); border: 1px solid; font-size: 12.5px; }
.alert.err { border-color: color-mix(in srgb, var(--crit) 50%, transparent); background: color-mix(in srgb, var(--crit) 8%, transparent); color: var(--crit-text); }
.alert.info { border-color: var(--border-strong); background: var(--surface-2); color: var(--ink-2); }

/* figures gallery */
.gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
.fig { display: flex; flex-direction: column; }
.fig .img { background: #fff; border-bottom: 1px solid var(--border); padding: 8px; display: grid; place-items: center; min-height: 200px; }
.fig .img img { max-width: 100%; height: auto; display: block; }
.fig .cap { font-size: 11.5px; color: var(--ink-2); padding: 8px 12px 0; }
.fig .acts { display: flex; gap: 6px; padding: 10px 12px 12px; margin-top: auto; }

.empty { padding: 48px 16px; text-align: center; color: var(--muted); }
.empty h3 { color: var(--ink); margin: 0 0 6px; font-size: 15px; }

.spin { width: 12px; height: 12px; border: 2px solid currentColor; border-right-color: transparent; border-radius: 50%; display: inline-block; animation: spin 0.8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }

@media (prefers-reduced-motion: reduce) {
  .pulse, .stages > div.cur, .spin { animation: none; }
}

/* ── responsive ─────────────────────────────────────────────────────────── */
@media (max-width: 1200px) {
  .hyp { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .g-side { grid-template-columns: minmax(0, 1fr); }
  .picker { max-height: 320px; }
}
@media (max-width: 900px) {
  .app { grid-template-columns: minmax(0, 1fr); }
  .sidebar { position: fixed; inset: 0 auto 0 0; width: 250px; z-index: 50; transform: translateX(-100%); transition: transform 0.2s; }
  .sidebar.open { transform: none; box-shadow: 0 0 0 100vmax rgba(0, 0, 0, 0.45); }
  .menu-btn { display: inline-flex; }
  .g2, .g3 { grid-template-columns: minmax(0, 1fr); }
  .strip { grid-template-columns: minmax(0, 1fr); }
  .topbar { padding: 8px 16px; flex-wrap: wrap; }
  .runbar { padding: 7px 16px; flex-wrap: wrap; }
  .content { padding: 14px 16px 40px; }
  .run-select select { max-width: 200px; }
}
@media (max-width: 560px) {
  .hyp { grid-template-columns: minmax(0, 1fr); }
  .totals .val { font-size: 17px; }
  .hero .big { font-size: 40px; }
  .gallery { grid-template-columns: minmax(0, 1fr); }
  .topbar .crumb { display: none; }
}

/* graphs page: campaign picker + MRTG stack */
.g-pick { display: grid; grid-template-columns: 270px minmax(0, 1fr); gap: 16px; align-items: start; }
.g-pick > .panel:first-child { position: sticky; top: 64px; }
@media (max-width: 1200px) {
  .g-pick { grid-template-columns: minmax(0, 1fr); }
  .g-pick > .panel:first-child { position: static; }
}
.mrtg-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 22px 26px; }
@media (max-width: 1400px) { .mrtg-grid { grid-template-columns: minmax(0, 1fr); } }

/* ── upload form ───────────────────────────────────────────────────────── */
.upload-form { display: flex; flex-direction: column; gap: 12px; }
.upload-form .drop { text-align: left; cursor: default; padding: 12px 14px; display: flex; flex-direction: column; gap: 6px; }
.drop.bad { border-style: solid; border-color: color-mix(in srgb, var(--warn) 70%, transparent); }
.drop-title { font-weight: 650; font-size: 13px; display: flex; align-items: center; gap: 8px; }
.drop-title .req { font-weight: 500; font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--muted); border: 1px solid var(--border-strong); border-radius: 4px; padding: 0 5px; }
.drop-cols { font-size: 11.5px; color: var(--ink-2); }
.drop-pick { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-top: 2px; }
.drop-file { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-sm); padding: 6px 8px; }
.drop-file .fn { font-family: var(--font-mono); font-size: 12px; font-weight: 600; overflow-wrap: anywhere; }
.drop-file .muted { font-size: 11.5px; }
.drop-acts { margin-left: auto; display: inline-flex; gap: 4px; }
.drop-preview { margin: 0; font: 11px/1.45 var(--font-mono); color: var(--ink-2); background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-sm); padding: 5px 8px; white-space: pre; overflow-x: auto; max-width: 100%; }
.drop-warn { color: var(--warn-text); font-size: 12px; }
.drop-hint { font-size: 11px; color: var(--muted); }
.btn.lg { min-height: 34px; padding: 6px 16px; font-weight: 600; width: 100%; justify-content: center; }
.progress { height: 4px; border-radius: 2px; background: var(--surface-3); overflow: hidden; }
.progress > div { height: 100%; background: var(--accent); transition: width 0.2s; }
.panel.collapsed .panel-h { border-bottom: 0; border-radius: var(--r); }
.panel.collapsed .panel-b { display: none; }

/* upload dialog */
dialog.modal { padding: 0; border: 1px solid var(--border-strong); border-radius: 10px; background: var(--surface); color: var(--ink);
  width: min(860px, calc(100vw - 32px)); max-height: calc(100vh - 48px); box-shadow: 0 24px 80px rgba(0, 0, 0, 0.35); }
dialog.modal::backdrop { background: rgba(0, 0, 0, 0.5); backdrop-filter: blur(2px); }
dialog.modal .panel-h { border-radius: 10px 10px 0 0; }

/* plain-language summary */
.plain { max-width: 820px; }
.plain-head { font-size: 16px; font-weight: 650; padding-left: 12px; border-left: 3px solid var(--accent); line-height: 1.35; }
.plain p { font-size: 14px; line-height: 1.65; margin: 12px 0 10px; color: var(--ink); }
.plain-note { font-size: 11.5px; color: var(--muted); }
.finding { display: inline-flex; align-items: center; gap: 7px; font-size: 12px; line-height: 1.35; min-width: 210px; max-width: 340px; cursor: help; }

/* ── hypothesis badges (replace the old OK/WARNING/CRITICAL statuses) ───── */
:root { --h1: var(--s1); --h2: var(--s2); --h3: var(--s3); --h4: var(--muted); }
.hyp-badge {
  display: inline-flex; align-items: center; gap: 5px; padding: 1px 8px 1px 6px; border-radius: 4px; white-space: nowrap;
  font-size: 11.5px; line-height: 18px; color: var(--ink); --hc: var(--muted);
  background: color-mix(in srgb, var(--hc) 14%, var(--surface)); border: 1px solid color-mix(in srgb, var(--hc) 45%, transparent);
}
.hyp-badge i { width: 8px; height: 8px; border-radius: 50%; background: var(--hc); flex: none; }
.hyp-badge b { font-family: var(--font-mono); font-weight: 700; font-size: 11px; }
.hyp-badge.h1 { --hc: var(--h1); } .hyp-badge.h2 { --hc: var(--h2); } .hyp-badge.h3 { --hc: var(--h3); } .hyp-badge.h4 { --hc: var(--h4); }
.hyp-badge.rejected { background: transparent; border-style: dashed; color: var(--muted); }
.hyp-badge.rejected i { background: transparent; box-shadow: inset 0 0 0 1.5px var(--hc); }
.hyp-badge.none { color: var(--muted); background: transparent; border-color: var(--border); }
.hyp-badge.sm { font-size: 10.5px; line-height: 15px; padding: 0 6px 0 5px; }
.wtag { display: inline-block; font-size: 10.5px; line-height: 16px; padding: 0 6px; border-radius: 4px; color: var(--ink-2);
  border: 1px solid var(--border-strong); white-space: nowrap; }
.wtag.primary { border-color: var(--ink-2); color: var(--ink); font-weight: 600; }
.wtag.info { color: var(--muted); border-style: dashed; }
.tally-dots { display: inline-flex; gap: 8px; flex-wrap: wrap; font-size: 10.5px; color: var(--ink-2); font-weight: 400; }
.tally-dots span { display: inline-flex; align-items: center; gap: 3px; font-family: var(--font-mono); }
.tally-dots i { width: 7px; height: 7px; border-radius: 50%; }
.totals .on-h1 { box-shadow: inset 0 -3px 0 var(--h1); }
.totals .on-h2 { box-shadow: inset 0 -3px 0 var(--h2); }
.totals .on-h3 { box-shadow: inset 0 -3px 0 var(--h3); }
.totals .on-h4 { box-shadow: inset 0 -3px 0 var(--h4); }
.totals .lead { background: var(--surface-2); }
.tbl tr.row-primary td.svc { font-weight: 700; }
.tbl tr.row-primary td { background: color-mix(in srgb, var(--accent) 5%, transparent); }
.plain-head.hyp-H1 { border-left-color: var(--h1); } .plain-head.hyp-H2 { border-left-color: var(--h2); }
.plain-head.hyp-H3 { border-left-color: var(--h3); } .plain-head.hyp-H4 { border-left-color: var(--h4); }
.totals .nm { font-size: 10px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: -2px; }

/* campaign size-quartile cards */
.qcards { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; padding: 14px; }
.qcard {
  all: unset; box-sizing: border-box; cursor: pointer; display: flex; flex-direction: column; gap: 6px; align-items: flex-start;
  padding: 10px 12px; border: 1px solid var(--border); border-radius: var(--r); background: var(--surface); min-width: 0;
}
.qcard:hover { background: var(--hover); }
.qcard:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.qcard.on { border-color: var(--accent); box-shadow: inset 0 3px 0 var(--accent); background: var(--surface-2); }
.qcard-h { display: flex; justify-content: space-between; gap: 8px; width: 100%; font-size: 12.5px; flex-wrap: wrap; }
.qcard-h .muted { font-size: 11.5px; }
.qcard-num { font-size: 11.5px; color: var(--ink); }
.qcard-sub { font-size: 11px; color: var(--muted); display: flex; align-items: center; gap: 5px; }
@media (max-width: 1100px) { .qcards { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 520px) { .qcards { grid-template-columns: minmax(0, 1fr); } }
.tally-row > .infobox { max-width: 620px; }
.tally-row .infobox .title { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.tally-compact { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; padding: 6px 14px; min-height: 44px; font-size: 12.5px; }
.tally-compact > b { font-size: 12.5px; font-weight: 650; margin-right: 4px; }
.tc { display: inline-flex; align-items: center; gap: 5px; padding: 1px 8px 1px 6px; border-radius: 5px; border: 1px solid var(--border);
  color: var(--ink); text-decoration: none; font-size: 11.5px; line-height: 18px; --hc: var(--muted); }
.tc:hover { background: var(--hover); text-decoration: none; }
.tc i { width: 8px; height: 8px; border-radius: 50%; background: var(--hc); }
.tc b { font-variant-numeric: tabular-nums; }
.tc.h1 { --hc: var(--h1); } .tc.h2 { --hc: var(--h2); } .tc.h3 { --hc: var(--h3); } .tc.h4 { --hc: var(--h4); }
.tc.lead { border-color: var(--ink-2); background: var(--surface-2); }
.tc.zero { color: var(--muted); }
.plain-inline { font-weight: 600; color: var(--ink); padding-left: 8px; border-left: 3px solid var(--accent); }
.plain-inline.hyp-H1 { border-left-color: var(--h1); } .plain-inline.hyp-H2 { border-left-color: var(--h2); }
.plain-inline.hyp-H3 { border-left-color: var(--h3); } .plain-inline.hyp-H4 { border-left-color: var(--h4); }
.q-inline { display: inline-flex; gap: 6px; flex-wrap: wrap; }
.q-chip { all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: 5px; padding: 1px 6px 1px 5px; border-radius: 5px;
  border: 1px solid var(--border); font-size: 11.5px; color: var(--ink); }
.q-chip:hover { background: var(--hover); }
.q-chip:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.q-chip.on { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 12%, var(--surface)); box-shadow: inset 0 -2px 0 var(--accent); }
__CTRMON_EOF__
w 'frontend/vite.config.js' <<'__CTRMON_EOF__'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// dev: `npm run dev` with the Flask backend on :5000 (python wsgi.py)
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { "/api": "http://127.0.0.1:5000" } },
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 800 },
});
__CTRMON_EOF__
w 'ctr_analysis.py' <<'__CTRMON_EOF__'
"""
ctr_analysis.py  (v4.1 — binomial GLM primary; QAIC; total-vs-within decomposition)
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

def between_campaign_analysis(df):
    camp = (df.groupby("campaign").agg(clicks=("clicks", "sum"), impr=("impr", "sum"), n_obs=("impr", "size"),
                                       mean_logv=("log_v", "mean")).reset_index())
    camp["ctr"] = camp["clicks"] / camp["impr"]; camp["logit_ctr"] = logit(camp["ctr"])
    rho, p_rho = stats.spearmanr(camp["mean_logv"], camp["ctr"]); tau, p_tau = stats.kendalltau(camp["mean_logv"], camp["ctr"])
    return camp, {"n_campaigns": len(camp), "spearman_rho": float(rho), "spearman_p": float(p_rho),
                  "kendall_tau": float(tau), "kendall_p": float(p_tau)}


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
    ax.set_xlabel("Група обсягу показів"); ax.set_ylabel("Середня погодинна клікабельність, %"); uk_axis(ax.yaxis); ax.legend(loc="upper right")
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
    ml, mlv = df["logit_ctr"].mean(), df["log_v"].mean(); lv = np.linspace(df["log_v"].min(), df["log_v"].max(), 200)
    def band(m):
        b = m.params["log_v"]; ci = m.conf_int().loc["log_v"].values
        p, lo, hi = (inv_logit(ml + c * (lv - mlv)) * 100 for c in (b, ci[0], ci[1]))
        return p, np.minimum(lo, hi), np.maximum(lo, hi)
    pg, lg, hg = band(reg["m1"]); po, _, ho = band(reg["ols_m1"])
    fig, ax = plt.subplots(figsize=(7, 4.4))
    ax.scatter(df["log_v"], df["ctr"] * 100, s=5, color="#9e9e9e", alpha=0.25, edgecolor="none", zorder=1)
    ax.fill_between(lv, lg, hg, color=CLR_MAIN, alpha=0.20, zorder=2)
    hg_, = ax.plot(lv, pg, color=CLR_MAIN, linewidth=1.8, zorder=4); ho_, = ax.plot(lv, po, color=CLR_ALT, linewidth=1.5, linestyle="--", zorder=3)
    ax.set_ylim(0, min(30, float(np.nanmax(ho)) * 1.05))
    ax.set_xlabel("Логарифм погодинного обсягу показів, ln(V)"); ax.set_ylabel("Передбачувана клікабельність, %"); uk_axis(ax.yaxis)
    legend_compact(ax, [hg_, ho_], ["Біноміальна GLM, 95 % довірча смуга", "МНК на logit(CTR)"], loc="upper left")
    save(fig, out / "fig4_marginal_effect.pdf", dpi)
    _caption(f"GLM β₁ = {uk(reg['m1'].params['log_v'],3,sign=True)}; МНК β₁ = {uk(reg['ols_m1'].params['log_v'],3,sign=True)}; "
             "прогноз при середніх logit(CTR) та ln(V); часові коваріати на середніх; сірі точки — погодинні спостереження")

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
    y_within = inv_logit(gm_logit + b_w * (x_line - gm_x)) * 100
    fig, ax = plt.subplots(figsize=(7, 4.4))
    h_pts = ax.scatter(x, y, s=s, facecolor="#d0d0d0", edgecolor="black", linewidth=0.5, alpha=0.8, zorder=3)
    h_t, = ax.plot(x_line, y_total, color="black", linestyle="--", linewidth=1.6, zorder=4)
    h_w, = ax.plot(x_line, y_within, color="black", linestyle="-", linewidth=1.6, zorder=4)
    ax.set_xlabel("Середній логарифм обсягу показів кампанії, ln(V)"); ax.set_ylabel("Клікабельність кампанії, %"); uk_axis(ax.yaxis)
    from matplotlib.lines import Line2D
    h_pts_proxy = Line2D([], [], marker="o", linestyle="none", markersize=6, markerfacecolor="#d0d0d0",
                         markeredgecolor="black", markeredgewidth=0.5)
    legend_compact(ax, [h_pts_proxy, h_t, h_w],
                   ["Кампанії", "Загальний нахил (без ФЕ кампаній)", "Внутрішньокампанійний нахил"],
                   loc="upper right")
    save(fig, out / "fig6_between_campaign.pdf", dpi)
    _caption(f"n = {bc['n_campaigns']} кампаній; розмір маркера ∝ √кількості годин; "
             f"ρ Спірмена = {uk(bc['spearman_rho'],2,sign=True)} (p = {uk(bc['spearman_p'],3)}); "
             f"загальний нахил β = {uk(b_t,3,sign=True)}, внутрішньокампанійний β₁ = {uk(b_w,3,sign=True)}; "
             f"різниця {uk(b_t - b_w,3,sign=True)} — композиційна складова")

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
__CTRMON_EOF__

for cand in "$HERE/ctr_analysis.py" "$PWD/ctr_analysis.py"; do
  if [ -f "$cand" ] && [ "$(cd "$(dirname "$cand")" && pwd)" != "$(cd "$DEST" && pwd)" ]; then
    cp "$cand" "$DEST/ctr_analysis.py"; echo "using analysis script: $cand"; break
  fi
done
echo "wrote $(cd "$DEST" && pwd)"
echo "next: cd $DEST && docker compose up --build -d   # → http://localhost:8080"
