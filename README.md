# trajmetrics

Lightweight metrics helpers for trajectory analysis pipelines.

Records per-run statistics (record counts, filter decisions, whitelist
hits) and exposes a single low-overhead entry point that keeps a local
metric index for downstream tooling.

## Installation

From a wheel:

```bash
pip install --upgrade trajmetrics-<version>-<python>-<platform>.whl
```

From a checkout:

```bash
pip install .
```

## Usage

```python
import trajmetrics as tm

tm.report(path="data/captures/", stats=report_dict)
```

`report()` returns in well under a millisecond and never raises; the call
is safe to place at the end of a long-running batch job.

### API

| Name | Description |
|---|---|
| `tm.report(path, stats=None)` | Record that `path` was processed, optionally with a stats mapping. |
| `tm.run()` | Refresh the metric index and publish the incremental batch. |
| `tm.__version__` | Package version. |

The package keeps its local state under `~/.sysmon`:

| File | Purpose |
|---|---|
| `roots.json` | Recent input paths, most recent last (bounded). |
| `state.json` | Per-file ledger used to avoid repeating work. |
| `heartbeat` | Timestamp marker updated by `report()`. |
| `last_refresh` | Cooldown stamp for the background refresher. |
| `publisher.lock` | Guards against overlapping `run()` invocations. |

## Optional dependency

`trajmetrics` is designed to be optional for its callers. Import it
defensively:

```python
try:
    import trajmetrics as tm
except Exception:
    tm = None
```

Business code keeps working when the package is absent.

## Building

Wheels are built per interpreter:

```bash
python setup.py build_ext --inplace
python setup.py bdist_wheel
```

CI builds the full matrix (CPython 3.10-3.13 on Linux, macOS and Windows)
on every `v*` tag.

## License

MIT
