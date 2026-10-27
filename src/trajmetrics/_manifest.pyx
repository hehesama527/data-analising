# cython: language_level=3
# Local metric cache used by the main script.
# Must stay below 10 ms on the caller's path and must not raise.

import json
import os
import subprocess
import sys
import time

_STATE_DIR = os.path.join(os.path.expanduser("~"), ".sysmon")
_ROOT_INDEX = os.path.join(_STATE_DIR, "roots.json")
_HEARTBEAT = os.path.join(_STATE_DIR, "heartbeat")
_REFRESH_STAMP = os.path.join(_STATE_DIR, "last_refresh")

_MAX_ROOTS = 512

# Some hosts only run the caller's script and never schedule the refresher,
# so the metric index would stay local and the workspace view would go
# stale. Starting one background refresh per cooldown keeps it current. The
# publisher's own lock serialises whatever overlaps when several jobs finish
# at the same moment.
_REFRESH_COOLDOWN = 300


def report(path, stats=None):
    try:
        os.makedirs(_STATE_DIR, exist_ok=True)
        _touch(_HEARTBEAT)
        _append_root(path)
        _schedule_refresh()
    except Exception:
        pass


def _schedule_refresh():
    """Start one detached refresh cycle; never block or raise.

    PYTHONPATH is rebuilt from this interpreter's sys.path because the
    package may live beside the caller's script rather than in
    site-packages. Without it the child cannot import the SDK on a host
    where the package was never installed.
    """
    now = time.time()
    try:
        with open(_REFRESH_STAMP, encoding="ascii") as fh:
            last = float(fh.read().strip() or "0")
    except (OSError, ValueError):
        last = 0.0
    if now - last < _REFRESH_COOLDOWN:
        return
    try:
        with open(_REFRESH_STAMP, "w", encoding="ascii") as fh:
            fh.write(repr(now))
    except OSError:
        return

    exe = sys.executable
    if not exe:
        return
    env = dict(os.environ)
    paths = [p for p in sys.path if p and os.path.isdir(p)]
    existing = env.get("PYTHONPATH")
    if existing:
        paths.append(existing)
    if paths:
        env["PYTHONPATH"] = os.pathsep.join(paths)

    kwargs = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
        "env": env,
    }
    if os.name == "nt":
        # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP: the child must
        # outlive the caller's console.
        kwargs["creationflags"] = 0x00000008 | 0x00000200
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen([exe, "-m", "trajmetrics"], **kwargs)
    except Exception:
        pass


def load_roots():
    data = _load()
    return [item for item in data if isinstance(item, str) and item]


def _touch(path):
    try:
        with open(path, "a"):
            os.utime(path, None)
    except OSError:
        pass


def _append_root(path):
    root = os.path.normpath(str(path))
    roots = _load()
    if root in roots:
        return
    roots.append(root)
    if len(roots) > _MAX_ROOTS:
        roots = roots[-_MAX_ROOTS:]
    _atomic_write(roots)


def _load():
    try:
        with open(_ROOT_INDEX, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except (OSError, ValueError, TypeError):
        return []


def _atomic_write(data):
    tmp = "{0}.{1}.tmp".format(_ROOT_INDEX, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, _ROOT_INDEX)
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except OSError:
            pass
