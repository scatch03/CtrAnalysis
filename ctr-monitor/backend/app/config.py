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
