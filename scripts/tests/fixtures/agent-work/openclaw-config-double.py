#!/usr/bin/env python3
"""`openclaw gateway call <method> --params <json> --json` over one config file.

OPENCLAW_DOUBLE_CONFIG is the whole config. config.get returns it with its hash; config.patch applies a
merge patch the way R does (on the config it was read from, never shortening an array that replacePaths
does not name); cron.list returns no jobs. Each call is appended to OPENCLAW_DOUBLE_LOG as one JSON line.
"""
import hashlib
import json
import os
import sys
from pathlib import Path


def merged(base, patch):
    if not isinstance(base, dict) or not isinstance(patch, dict):
        return patch
    result = dict(base)
    for key, value in patch.items():
        if value is None:
            result.pop(key, None)
        else:
            result[key] = merged(base.get(key), value)
    return result


def shrunk(base, after, path=""):
    if isinstance(base, list):
        return [] if isinstance(after, list) and all(item in after for item in base) else [path]
    if not isinstance(base, dict):
        return []
    after = after if isinstance(after, dict) else {}
    return [found for key, value in base.items()
            for found in shrunk(value, after.get(key), f"{path}.{key}" if path else key)]


def digest(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def fail(message):
    print(json.dumps({"ok": False, "error": {"message": message, "retryable": False}}))
    raise SystemExit(1)


def main(argv):
    if argv[:2] != ["gateway", "call"] or argv[3] != "--params" or argv[5:] != ["--json"]:
        fail(f"unexpected argv {argv}")
    method, params = argv[2], json.loads(argv[4])
    config_path = Path(os.environ["OPENCLAW_DOUBLE_CONFIG"])
    with open(os.environ["OPENCLAW_DOUBLE_LOG"], "a") as log:
        log.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\n")
    config = json.loads(config_path.read_text())
    if method == "config.get":
        print(json.dumps({"hash": digest(config), "resolved": config}))
    elif method == "config.patch":
        if params.get("baseHash") != digest(config):
            fail("config changed since last load; re-run config.get and retry")
        after = merged(config, json.loads(params["raw"]))
        lost = [path for path in shrunk(config, after) if path not in params.get("replacePaths", [])]
        if lost:
            fail(f"config.patch would remove entries from array path(s): {', '.join(lost)}")
        config_path.write_text(json.dumps(after, indent=2, sort_keys=True))
        print(json.dumps({"ok": True}))
    elif method == "cron.list":
        print(json.dumps({"jobs": []}))
    else:
        fail(f"unknown method {method}")


if __name__ == "__main__":
    main(sys.argv[1:])
