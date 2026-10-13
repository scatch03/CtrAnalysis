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
