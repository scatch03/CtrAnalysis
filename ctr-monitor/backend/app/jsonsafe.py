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
