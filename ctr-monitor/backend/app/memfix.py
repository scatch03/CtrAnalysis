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
