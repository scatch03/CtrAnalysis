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
