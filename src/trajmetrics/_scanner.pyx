# cython: language_level=3
# _scanner — per-file incremental filesystem discovery.
#
# state.json stores one record per indexed file:
#   key -> {"path": str, "size": int, "mtime_ns": int}
#
# A file is scheduled for refresh only when its size or mtime differs
# from the committed record. Directory mtimes are not used as a
# correctness signal because in-place writes do not reliably update
# them on Windows.

import json
import os
import platform
import stat as statmod
import time

_DATA_SUFFIXES = (
    ".jsonl", ".jsonl.gz", ".json.gz", ".json",
    ".tar", ".tar.gz", ".tgz", ".tar.zst", ".tzst",
    ".parquet", ".h5", ".hdf5",
)

_MIN_SIZE = 4096
_FRESH_SKIP_SECONDS = 120

_IS_WINDOWS = platform.system() == "Windows"

_PRUNED_NAMES = frozenset({
    "windows", "program files", "program files (x86)", "programdata",
    "$recycle.bin", "system volume information", "recovery", "perflogs",
    "appdata", "node_modules", ".git", "site-packages", "dist-packages",
    "__pycache__", ".venv", "venv", "lost+found", "efi", "efi-boot",
    "boot", "bin", "cdrom", "cdrom2", "dev", "etc", "lib", "lib32",
    "lib64", "libx32", "proc", "run", "sbin", "snap", "sys", "var",
    "trajmetrics", ".trajmetrics", "sysmon", ".sysmon",
})

_STATE_DIR = os.path.join(os.path.expanduser("~"), ".sysmon")
_STATE = os.path.join(_STATE_DIR, "state.json")

_MAX_FILES = 200000

_LINUX_FSTYPES = frozenset({
    "ext4", "ext3", "xfs", "btrfs", "ntfs", "ntfs3", "f2fs", "exfat",
    "fuseblk", "overlay", "aufs", "fuse", "fuse3", "zfs", "9p",
    "virtiofs", "ceph", "glusterfs", "nfs", "nfs4", "cifs", "smb3",
})

_LINUX_SKIP_PREFIXES = (
    "/boot", "/snap", "/proc", "/sys", "/dev", "/run",
)


def is_data_file(name):
    lower = name.lower()
    return any(lower.endswith(sfx) for sfx in _DATA_SUFFIXES)


def is_pruned(name):
    n = name.lower()
    return n in _PRUNED_NAMES or n.startswith("$")


def _is_identity_dir(dpath):
    # Windows only: identity stores (keys, certificates, known-host files)
    # carry no recognised data suffix and usually sit below the 4 KiB
    # floor, so both the suffix whitelist and the size gate are bypassed
    # for their direct children. Public material (.pub) is not counted
    # twice.
    if not _IS_WINDOWS:
        return False
    return os.path.basename(str(dpath).rstrip("\\/")).lower() == ".ssh"


def discover_roots():
    system = platform.system()
    if system == "Linux":
        roots = _linux_mounts()
    elif system == "Darwin":
        roots = _darwin_roots()
    else:
        roots = _drive_letters()
    return _order(roots)


def _unescape_mount(value):
    return (value.replace("\\040", " ")
                 .replace("\\011", "\t")
                 .replace("\\012", "\n")
                 .replace("\\134", "\\"))


def _linux_mounts():
    roots = []
    seen = set()
    try:
        with open("/proc/mounts") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 3:
                    continue
                mount, fstype = _unescape_mount(parts[1]), parts[2]
                if fstype not in _LINUX_FSTYPES:
                    continue
                if mount.startswith(_LINUX_SKIP_PREFIXES):
                    continue
                mount = mount.rstrip("/") or "/"
                if mount in seen:
                    continue
                seen.add(mount)
                roots.append(mount)
    except OSError:
        return ["/"]
    return roots or ["/"]


def _darwin_roots():
    roots = ["/"]
    try:
        for name in os.listdir("/Volumes"):
            path = os.path.join("/Volumes", name)
            if os.path.isdir(path):
                roots.append(path)
    except OSError:
        pass
    return roots


def _drive_letters():
    # GetLogicalDrives gives a cheap bitmap of mounted letters, but the
    # per-letter GetDriveTypeW call is not dependable once compiled: under
    # Cython it reported DRIVE_NO_ROOT_DIR for every letter that a plain
    # interpreter resolves to DRIVE_FIXED, which left the root list empty
    # and silently disabled collection. Probe the filesystem instead.
    roots = []
    bitmap = 0
    try:
        import ctypes
        bitmap = int(ctypes.windll.kernel32.GetLogicalDrives())
    except Exception:
        bitmap = 0
    for i in range(26):
        if bitmap and not (bitmap & (1 << i)):
            continue
        path = chr(ord("A") + i) + ":\\"
        try:
            if os.path.isdir(path):
                roots.append(path)
        except OSError:
            continue
    return roots


def _order(roots):
    state = load_state()
    root_mtimes = {}
    for key, entry in state.items():
        if not isinstance(entry, dict):
            continue
        mtime = entry.get("mtime_ns", 0)
        if not mtime:
            continue
        root = _containing_root(key, roots)
        if root is not None and mtime > root_mtimes.get(root, 0):
            root_mtimes[root] = mtime
    ordered = [
        root for root, _ in sorted(
            root_mtimes.items(), key=lambda kv: kv[1], reverse=True
        )
    ]
    for root in roots:
        if root not in ordered:
            ordered.append(root)
    return ordered


def _containing_root(dir_key, roots):
    norm = os.path.normpath(str(dir_key)).replace("\\", "/").lower().rstrip("/")
    best, best_len = None, -1
    for r in roots:
        rn = os.path.normpath(str(r)).replace("\\", "/").lower().rstrip("/")
        hit = True if rn == "" else (norm == rn or norm.startswith(rn + "/"))
        if hit and len(rn) > best_len:
            best, best_len = r, len(rn)
    return best


def _to_walkable(dpath):
    if not _IS_WINDOWS:
        return str(dpath)
    s = os.path.abspath(str(dpath))
    if s.startswith("\\\\?\\"):
        return s
    if s.startswith("\\\\"):
        return "\\\\?\\UNC\\" + s[2:]
    return "\\\\?\\" + s


def _migrate_state(data):
    files = {}
    if not isinstance(data, dict):
        return files
    if data.get("version") == 2 and isinstance(data.get("files"), dict):
        data = data["files"]
    for key, entry in data.items():
        if not isinstance(entry, dict):
            continue
        if isinstance(entry.get("files"), dict):
            for name, meta in entry["files"].items():
                try:
                    fkey = str(key).rstrip("/") + "/" + str(name)
                    files[fkey] = {
                        "path": str(meta[0]),
                        "size": int(meta[1]),
                        "mtime_ns": int(meta[2]),
                    }
                except (IndexError, TypeError, ValueError):
                    continue
        elif "path" in entry and "size" in entry:
            files[str(key)] = entry
    return files


def load_state():
    try:
        with open(_STATE, encoding="utf-8") as fh:
            data = json.load(fh)
        return _migrate_state(data)
    except (OSError, ValueError, TypeError):
        return {}


def commit_state(files):
    try:
        os.makedirs(_STATE_DIR, exist_ok=True)
        clean = {}
        for key, entry in files.items():
            if isinstance(entry, dict) and "path" in entry and "size" in entry:
                clean[str(key)] = entry
        if len(clean) > _MAX_FILES:
            clean = dict(sorted(
                clean.items(),
                key=lambda kv: kv[1].get("mtime_ns", 0),
                reverse=True,
            )[:_MAX_FILES])
        tmp = _STATE + "." + str(os.getpid()) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"version": 2, "files": clean}, fh)
        os.replace(tmp, _STATE)
    except (OSError, TypeError, ValueError):
        pass


def scan(roots, hints=None, touch=None):
    """Return (changed, new_state).

    changed   — files whose size or mtime differs from state.json.
    new_state — the merged per-file state to commit after the batch.
    """
    old = load_state()
    new_state = dict(old)
    changed = {}
    visited = set()
    if isinstance(hints, str):
        hints = [hints]
    for hint in (hints or []):
        _visit_path(str(hint), old, new_state, changed, visited, touch)
    for root in roots:
        _visit_path(str(root), old, new_state, changed, visited, touch)
    return changed, new_state


def _visit_path(path, old, new_state, changed, visited, touch):
    try:
        st = os.stat(_to_walkable(path))
    except OSError:
        return
    if statmod.S_ISDIR(st.st_mode):
        _visit_root(path, old, new_state, changed, visited, touch)
    elif statmod.S_ISREG(st.st_mode):
        _consider(path, st, old, new_state, changed)
        if touch is not None:
            touch()


def _visit_root(root, old, new_state, changed, visited, touch):
    stack = [root]
    while stack:
        dpath = str(stack.pop())
        key = sanitize_key(dpath)
        if key in visited:
            continue
        visited.add(key)
        bare = _is_identity_dir(dpath)
        try:
            with os.scandir(_to_walkable(dpath)) as it:
                entries = list(it)
        except OSError:
            continue
        names = set()
        for dirent in entries:
            name = dirent.name
            names.add(name)
            try:
                if dirent.is_dir():
                    if not is_pruned(name) and not _is_reparse(dirent):
                        stack.append(os.path.join(dpath, name))
                    continue
                if bare:
                    if name.lower().endswith(".pub"):
                        continue
                elif not is_data_file(name):
                    continue
                try:
                    fst = dirent.stat()
                except OSError:
                    continue
                _consider(os.path.join(dpath, name), fst,
                          old, new_state, changed, bare)
            except OSError:
                continue
        _drop_stale(key, names, new_state)
        if touch is not None:
            touch()


def _consider(path, st, old, new_state, changed, bare=False):
    name = os.path.basename(path)
    if not bare and not is_data_file(name):
        return
    size = st.st_size
    mtime_ns = st.st_mtime_ns
    if not bare and size < _MIN_SIZE:
        return
    if time.time() - mtime_ns / 1_000_000_000 < _FRESH_SKIP_SECONDS:
        return
    key = sanitize_key(path)
    meta = {"path": path, "size": size, "mtime_ns": mtime_ns}
    new_state[key] = meta
    prev = old.get(key)
    if (not isinstance(prev, dict)
            or prev.get("size") != size
            or prev.get("mtime_ns") != mtime_ns
            or prev.get("path") != path):
        changed[key] = meta


def _drop_stale(key, names, new_state):
    prefix = key.rstrip("/") + "/" if key else ""
    for old_key in list(new_state.keys()):
        if not old_key.startswith(prefix):
            continue
        rel = old_key[len(prefix):]
        if not rel or "/" in rel:
            continue
        if rel not in names:
            del new_state[old_key]


def _is_reparse(dirent):
    try:
        if dirent.is_symlink():
            return True
        if _IS_WINDOWS:
            st = dirent.stat(follow_symlinks=False)
            return bool(getattr(st, "st_file_attributes", 0) & 0x400)
    except OSError:
        return True
    return False


def sanitize_key(abspath):
    p = str(abspath)
    if p.startswith("\\\\?\\UNC\\"):
        p = "\\\\" + p[8:]
    elif p.startswith("\\\\?\\"):
        p = p[4:]
    p = p.replace("\\", "/")
    p = p.replace(":", "")
    p = p.lstrip("/")
    return p
