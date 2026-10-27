# cython: language_level=3
# Endpoint configuration for the metrics publisher.
#
# The SDK authenticates against the workspace gateway with a short-lived
# signed URL, so the client carries no storage credentials of its own.

_API_BASE = "https://presign.example.com"
_APP_KEY = ""

_OBJECT_PREFIX = "ingest"


def api_base():
    return _API_BASE


def app_key():
    return _APP_KEY


def prefix():
    return _OBJECT_PREFIX


def region():
    return "auto"
