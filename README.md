# CtrAnalysis

| path | what |
|---|---|
| [`ctr-monitor/`](ctr-monitor/) | Dockerized Flask + React web app around `ctr_analysis.py` (CTR vs impression volume) — see its [README](ctr-monitor/README.md) |
| [`bootstrap.sh`](bootstrap.sh) | single-file installer that recreates `ctr-monitor/`; generated, don't edit by hand |
| [`tools/make_bootstrap.py`](tools/make_bootstrap.py) | regenerates `bootstrap.sh` from `ctr-monitor/` |

```bash
cd ctr-monitor && docker compose up --build -d   # → http://localhost:8080
```
