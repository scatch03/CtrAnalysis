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
