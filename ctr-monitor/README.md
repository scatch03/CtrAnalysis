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
