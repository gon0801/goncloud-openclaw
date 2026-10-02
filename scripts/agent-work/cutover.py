#!/usr/bin/env python3
"""Offline cutover rehearsal. This CLI never invokes a live service."""

import argparse
import fcntl
import hashlib
import json
import os
import tempfile
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def write_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def checked_manifest(path):
    manifest = read_json(path)
    if manifest.get("schema") != 1 or not isinstance(manifest.get("sourceSha"), str) or len(manifest["sourceSha"]) != 40:
        raise ValueError("manifest schema or source SHA invalid")
    package = Path(manifest.get("package", ""))
    if not package.is_absolute() or not package.is_file():
        raise ValueError("manifest package must exist at an absolute path")
    if digest(package) != manifest.get("packageSha256"):
        raise ValueError("manifest package hash mismatch")
    if manifest.get("schemaCompatibility") not in ("previous-binary-readable", "previous-binary-unreadable"):
        raise ValueError("schema compatibility must be explicit")
    return manifest


def authorized(path, manifest_path, state, operation):
    if path is None:
        raise ValueError("recorded authorization required")
    record = read_json(path)
    if (record.get("manifestSha256") != digest(manifest_path)
            or record.get("scope") != state.get("scope")
            or record.get("generation") != state.get("preparedGeneration")
            or operation not in record.get("operations", [])
            or not record.get("recordedBy")):
        raise ValueError("authorization does not match manifest, scope, generation and operation")


def prepare(state, manifest_path):
    if state.get("admission") != "frozen" or not state.get("capture"):
        raise ValueError("prepare requires frozen admission and result capture")
    if state.get("owner") != "legacy" or not isinstance(state.get("generation"), int):
        raise ValueError("prepare requires legacy owner and known generation")
    state["preparedGeneration"] = state["generation"] + 1
    state["preparedManifestSha256"] = digest(manifest_path)
    return "prepared"


def apply(state, manifest_path, authorization):
    if state.get("owner") != "legacy" or state.get("admission") != "frozen":
        raise ValueError("apply requires frozen legacy owner")
    if state.get("preparedManifestSha256") != digest(manifest_path):
        raise ValueError("manifest differs from prepared manifest")
    if state.get("preparedGeneration") != state.get("generation", -1) + 1:
        raise ValueError("prepared generation is stale")
    authorized(authorization, manifest_path, state, "apply")
    cron = state.get("cron", {})
    if not state.get("capture") or cron.get("suspended") is not True:
        raise ValueError("result capture and suspended old cron required")
    if cron.get("inFlight") != 0 or cron.get("postSuspendRequests") != 0:
        raise ValueError("old cron has in-flight or post-suspension requests")
    if state.get("uncertainAdmissions"):
        raise ValueError("uncertain admission needs reconciliation")
    if state.get("emitters") != ["legacy"]:
        raise ValueError("exactly one old emitter required before transfer")
    state["owner"] = "native"
    state["generation"] = state["preparedGeneration"]
    state["emitters"] = ["native"]
    state["binary"] = "candidate"
    state["config"] = "candidate"
    state["admission"] = "enabled"
    return "applied"


def rollback(state, manifest, manifest_path, authorization):
    state["admission"] = "frozen"
    authorized(authorization, manifest_path, state, "rollback")
    if state.get("owner") != "native" or state.get("emitters") != ["native"]:
        raise ValueError("rollback requires one native owner")
    if not state.get("capture"):
        raise ValueError("result capture missing")
    if manifest["schemaCompatibility"] != "previous-binary-readable":
        raise ValueError("previous binary cannot read migrated schema; retain candidate")
    if state.get("rollbackFailure"):
        raise ValueError("rollback failed; retain candidate and pending results")
    state["binary"] = "previous"
    state["config"] = "previous"
    state["owner"] = "legacy"
    state["generation"] += 1
    state["emitters"] = ["legacy"]
    return "rolled-back; old cron remains suspended"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "inspect", "apply", "rollback"))
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--authorization", type=Path)
    parser.add_argument("--simulation", action="store_true")
    args = parser.parse_args()
    if not args.simulation:
        parser.error("only offline simulation is implemented; live cutover is not authorized")
    try:
        # A separate lock survives atomic state-file replacement.
        with Path(str(args.state) + ".lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = read_json(args.state)
            if args.command == "inspect":
                print(json.dumps(state, sort_keys=True))
                return 0
            if args.command == "rollback":
                state["admission"] = "frozen"
                write_json(args.state, state)
            manifest = checked_manifest(args.manifest)
            if args.command == "prepare":
                message = prepare(state, args.manifest)
            elif args.command == "apply":
                message = apply(state, args.manifest, args.authorization)
            else:
                message = rollback(state, manifest, args.manifest, args.authorization)
            write_json(args.state, state)
            print(message)
            return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(1, f"cutover: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
