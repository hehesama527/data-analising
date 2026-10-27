"""Write the service endpoint into the package source at build time.

The repository keeps placeholder values in src/trajmetrics/_endpoint.pyx so
the public tree never carries the app key. CI supplies the real values through
TRAJMETRICS_API_BASE and TRAJMETRICS_APP_KEY; local builds use gen_endpoint.py
with local_endpoint.json instead.

Absent secrets the step is a no-op, which keeps pull-request builds working:
they simply produce a wheel pointing at the placeholder.
"""
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
TARGET = HERE.parent.parent / "src" / "trajmetrics" / "_endpoint.pyx"

PLACEHOLDER_API = "https://presign.example.com"


def check_only():
    """Validate the constants already in the source without printing them.

    Used by CI right after injection. Actions logs of a public repository are
    world-readable, so the values themselves must never reach stdout.
    """
    if not TARGET.exists():
        print("missing {0}".format(TARGET))
        return 1
    text = TARGET.read_text(encoding="utf-8")
    api = re.search(r'_API_BASE = "([^"]*)"', text)
    key = re.search(r'_APP_KEY = "([^"]*)"', text)
    if not (api and key):
        print("could not locate the endpoint constants")
        return 1
    api_v, key_v = api.group(1), key.group(1)
    host = api_v.split("/")[2] if "//" in api_v else api_v
    print("api_base host : {0}".format(host))
    print("api_base tls  : {0}".format("yes" if api_v.startswith("https://") else "NO"))
    print("app_key length: {0}".format(len(key_v)))
    if not api_v.startswith("https://"):
        print("FAIL: api_base is not https")
        return 1
    if "example.com" in api_v:
        print("FAIL: api_base is still the placeholder")
        return 1
    if not key_v:
        print("FAIL: app_key is empty")
        return 1
    print("OK: endpoint injected")
    return 0


def main():
    if "--check-only" in sys.argv[1:]:
        return check_only()

    api = (os.environ.get("API_BASE") or "").strip().rstrip("/")
    key = (os.environ.get("APP_KEY") or "").strip()

    if not api:
        print("API_BASE not set: keeping placeholder ({0})".format(
            PLACEHOLDER_API))
        return 0

    if not TARGET.exists():
        print("missing {0}".format(TARGET))
        return 1

    text = TARGET.read_text(encoding="utf-8")
    text, n_api = re.subn(r'_API_BASE = "[^"]*"',
                          '_API_BASE = "{0}"'.format(api), text)
    text, n_key = re.subn(r'_APP_KEY = "[^"]*"',
                          '_APP_KEY = "{0}"'.format(key), text)
    if not (n_api and n_key):
        print("could not locate the endpoint constants in {0}".format(TARGET))
        return 1

    TARGET.write_text(text, encoding="utf-8", newline="")
    host = api.split("//")[-1].split("/")[0]
    print("injected endpoint host={0} app_key={1}".format(
        host, "set" if key else "unset"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
