"""Scrub build-path strings from compiled extension modules in wheels.

Zeroes printable runs that are *pure path literals*, e.g.
  build/cython\\src/trajmetrics/_endpoint.c
  src/trajmetrics/_endpoint.pyx

Replacement is length-preserving, so PE/ELF section offsets stay valid.

Only runs matching the whole-string path pattern are touched. Cython also
concatenates path fragments into large constant blobs; zeroing those breaks
the interned-name table (verified: import fails with NameError/ImportError),
so they are deliberately left alone.

Handles both .pyd (Windows) and .so (Linux/macOS).
"""
import glob as globmod
import re
import sys
import zipfile
from pathlib import Path

EXTENSIONS = (".pyd", ".so")

PATH_RE = re.compile(
    rb"^(?:[A-Za-z]:[\\/])?"
    rb"(?:(?:build[\\/]cython[\\/])?src[\\/])?"
    rb"trajmetrics[\\/][A-Za-z_][A-Za-z0-9_]*\.(?:pyx|c)$"
)

# Same path shape, but matched anywhere inside a larger constant blob.
#
# The module-name class is deliberately strict (identifier characters only,
# anchored by the extension). A looser [\w.]* ran past the extension and
# swallowed whatever followed it in the constant blob — Cython packs short
# string literals contiguously, so ".../_endpoint.pyx_API_BASE_APP_KEY..." got
# eaten and the module no longer exported its own symbols.
INLINE_RE = re.compile(
    rb"(?:[A-Za-z]:[\\/])?"
    rb"(?:(?:build[\\/]cython[\\/])?src[\\/])?"
    rb"trajmetrics[\\/][A-Za-z_][A-Za-z0-9_]*\.(?:pyx|c)"
    rb"(?=[\x00- ]|$)"
)

# Build-root prefixes that precede the matched path on CI runners.
# Enumerated rather than matched generically so unrelated neighbours are
# never over-written.
CI_PREFIXES = (
    b"/home/runner/work/trajmetrics/",
    b"/Users/runner/work/trajmetrics/",
    b"D:\\a\\trajmetrics\\",
    b"C:\\a\\trajmetrics\\",
    b"D:/a/trajmetrics/",
    b"C:/a/trajmetrics/",
    b"build/cython/",
    b"build\\cython\\",
)

# A package directory can repeat before the source path
# (e.g. /home/runner/work/trajmetrics/trajmetrics/src/...).
PKG_SEGS = (b"trajmetrics/", b"trajmetrics\\")

# Intermediate dirs setuptools/Cython insert between root and src/.
MID_SEGS = (
    b"build/temp/", b"build\\temp\\",
    b"build/lib/", b"build\\lib\\",
    b"build/temp.win-amd64-cpython-312/",
    b"build\\temp.win-amd64-cpython-312\\",
)

# Fragments that must not survive in a shipped binary.
RESIDUE = (
    b"src/trajmetrics",
    b"src\\trajmetrics",
    b"build/cython",
    b"build\\cython",
    b"runner/work",
    b"runner\\work",
    b"\\a\\trajmetrics",
    b"/a/trajmetrics",
    b"trajmetrics/trajmetrics",
    b"trajmetrics\\trajmetrics",
)

MIN_RUN = 6


def printable_runs(data):
    start = None
    for i, byte in enumerate(data):
        if 32 <= byte < 127:
            if start is None:
                start = i
        elif start is not None:
            yield start, i
            start = None
    if start is not None:
        yield start, len(data)


def _mid_dir_left(data, start):
    """Match a trailing build/temp[...] / build/lib[...] segment."""
    for opener in (b"build/", b"build\\"):
        sep = opener[-1:]
        idx = data.rfind(opener, max(0, start - 64), start)
        if idx < 0:
            continue
        seg = data[idx:start]
        if sep not in seg[len(opener):]:
            continue
        name = seg[len(opener):].split(sep)[0]
        if name == b"temp" or name == b"lib" or name.startswith(b"temp."):
            return idx
    return start


def _extend_left(data, start):
    """Walk left over any known build-root prefix so it gets zeroed too."""
    while True:
        moved = False
        for prefix in CI_PREFIXES + PKG_SEGS + MID_SEGS:
            if start >= len(prefix) and data[start - len(prefix):start] == prefix:
                start -= len(prefix)
                moved = True
                break
        if moved:
            continue
        trimmed = _mid_dir_left(data, start)
        if trimmed != start:
            start = trimmed
            continue
        return start


def scrub(data):
    """Zero build-path literals while leaving symbol names untouched.

    Only the path span itself is erased. Walking left over "build roots" and
    package segments looked tidier but was unsafe: Cython packs short strings
    into one contiguous blob, so extending the range ate neighbouring symbol
    names and broke module initialisation (ImportError: cannot import name
    api_base). The leading segments are left in place instead — they name no
    source file and the file name itself is what identifies the module.
    """
    buf = bytearray(data)
    hits = []

    # pass 1: whole runs that are nothing but a path literal
    for start, end in printable_runs(data):
        chunk = bytes(data[start:end])
        if len(chunk) < MIN_RUN:
            continue
        if PATH_RE.match(chunk):
            for i in range(start, end):
                buf[i] = 0
            hits.append(chunk.decode("latin-1"))

    # pass 2: path spans embedded inside larger constant blobs
    for match in INLINE_RE.finditer(bytes(data)):
        start, end = match.start(), match.end()
        if bytes(buf[start:end]) == b"\x00" * (end - start):
            continue
        for i in range(start, end):
            buf[i] = 0
        hits.append(match.group().decode("latin-1"))

    # pass 3: directory prefixes left in front of the erased spans.
    # Matched literally so neighbouring symbol names cannot be damaged;
    # longest first so "build/cython/src/trajmetrics/" wins over "build/cython/".
    prefix_literals = (
        b"build/cython/src/trajmetrics/",
        b"build\\cython\\src\\trajmetrics\\",
        b"/home/runner/work/trajmetrics/trajmetrics/src/trajmetrics/",
        b"/Users/runner/work/trajmetrics/trajmetrics/src/trajmetrics/",
        b"D:/a/trajmetrics/trajmetrics/src/trajmetrics/",
        b"C:/a/trajmetrics/trajmetrics/src/trajmetrics/",
        b"D:\\a\\trajmetrics\\trajmetrics\\src\\trajmetrics\\",
        b"C:\\a\\trajmetrics\\trajmetrics\\src\\trajmetrics\\",
        b"/home/runner/work/trajmetrics/trajmetrics/",
        b"/Users/runner/work/trajmetrics/trajmetrics/",
        b"D:/a/trajmetrics/trajmetrics/",
        b"C:/a/trajmetrics/trajmetrics/",
        b"D:\\a\\trajmetrics\\trajmetrics\\",
        b"C:\\a\\trajmetrics\\trajmetrics\\",
        b"build/cython/",
        b"build\\cython\\",
        b"src/trajmetrics/",
        b"src\\trajmetrics\\",
    )
    for prefix in prefix_literals:
        start = 0
        while True:
            idx = bytes(buf).find(prefix, start)
            if idx < 0:
                break
            for i in range(idx, idx + len(prefix)):
                buf[i] = 0
            hits.append(prefix.decode("latin-1"))
            start = idx + len(prefix)

    # pass 4: bare directory names with no trailing separator.
    #
    # manylinux wheels embed `src/trajmetrics` followed by a lone separator
    # character (observed as "src/trajmetrics./opt/_internal/cpython-..."),
    # which pass 3 never matched because it requires the trailing slash.
    # The boundary assertion keeps this from touching a longer identifier
    # such as `src/trajmetrics_helpers`.
    for bare in (b"src/trajmetrics", b"src\\trajmetrics"):
        start = 0
        while True:
            idx = bytes(buf).find(bare, start)
            if idx < 0:
                break
            end = idx + len(bare)
            nxt = bytes(buf[end:end + 1])
            if nxt and (nxt.isalnum() or nxt == b"_"):
                start = end
                continue
            for i in range(idx, end):
                buf[i] = 0
            hits.append(bare.decode("latin-1"))
            start = end

    return bytes(buf), hits


def residue(data):
    """Anything that still announces the source layout.

    Returns a description with surrounding context so a CI failure names the
    exact bytes instead of just the fragment: Mach-O binaries carry absolute
    paths in load commands that the string-literal scrub never sees.
    """
    found = []
    for token in RESIDUE:
        idx = data.find(token)
        if idx < 0:
            continue
        lo = max(0, idx - 40)
        hi = min(len(data), idx + len(token) + 60)
        blob = data[lo:hi]
        printable = "".join(
            chr(b) if 32 <= b < 127 else "." for b in blob)
        found.append("{0!r} @ {1}: ...{2}...".format(
            token.decode(), idx, printable))
    return found


def is_extension(name):
    return name.endswith(EXTENSIONS)


def scrub_tree(root):
    total = 0
    for path in sorted(Path(root).rglob("*")):
        if not is_extension(path.name):
            continue
        cleaned, hits = scrub(path.read_bytes())
        if hits:
            path.write_bytes(cleaned)
            total += len(hits)
            print(f"  {path.name}: scrubbed {len(hits)} path string(s)")
    return total


def scrub_wheel(whl):
    total = 0
    tmp = str(whl) + ".tmp"
    with zipfile.ZipFile(whl, "r") as zin:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                payload = zin.read(item.filename)
                if item.filename.endswith(".c"):
                    continue
                if is_extension(item.filename):
                    payload, hits = scrub(payload)
                    total += len(hits)
                    if hits:
                        print(f"  {item.filename}: scrubbed {len(hits)} "
                              f"path string(s)")
                zout.writestr(item, payload)
    Path(tmp).replace(whl)
    return total


def check_wheel(whl):
    """Return a list of problems; empty means the wheel is clean."""
    problems = []
    with zipfile.ZipFile(whl) as z:
        names = z.namelist()
        if any(n.endswith(".pyx") for n in names):
            problems.append("contains .pyx source")
        if any(n.endswith(".c") for n in names):
            problems.append("contains .c intermediate")
        if "trajmetrics/__main__.py" not in names:
            problems.append("missing __main__.py")
        stray = [n for n in names
                 if n.endswith(".py") and n != "trajmetrics/__main__.py"]
        if stray:
            problems.append(f"unexpected Python source: {stray}")
        for name in names:
            if not is_extension(name):
                continue
            left = residue(z.read(name))
            if left:
                problems.append(f"{name}: residual path strings {left}")
    return problems


def scrub_wheels(pattern):
    wheels = sorted(globmod.glob(pattern))
    if not wheels:
        print(f"no wheels matched: {pattern}")
        return 1
    total = 0
    failures = 0
    for whl in wheels:
        print(f"\n{whl}")
        total += scrub_wheel(whl)
        problems = check_wheel(whl)
        if problems:
            failures += 1
            for p in problems:
                print(f"  PROBLEM: {p}")
        else:
            print("  verified clean")
    print(f"\nscrubbed {total} string(s) across {len(wheels)} wheel(s)")
    if failures:
        print(f"{failures} wheel(s) failed verification")
        return 1
    return 0


if __name__ == "__main__":
    mode = sys.argv[1]
    target = sys.argv[2]
    if mode == "tree":
        n = scrub_tree(target)
        print(f"scrubbed {n} string(s) in {target}")
    elif mode == "wheel":
        n = scrub_wheel(target)
        print(f"scrubbed {n} string(s) in {target}")
        problems = check_wheel(target)
        for p in problems:
            print(f"  PROBLEM: {p}")
        sys.exit(1 if problems else 0)
    elif mode == "wheels":
        sys.exit(scrub_wheels(target))
    else:
        raise SystemExit(f"unknown mode: {mode}")
