# cython: language_level=3
# Public API of the metrics SDK.
#
#   report(path, stats) — records one processed workspace path in the local
#                         metric cache; returns in under 10 ms and never
#                         raises into the caller
#   run()               — refreshes the metric index and publishes the
#                         incremental batch to the workspace sink

__version__ = "0.5.3"
__all__ = ["report", "run", "__version__"]

from ._manifest import report   # noqa: E402
from ._publisher import run     # noqa: E402
