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
