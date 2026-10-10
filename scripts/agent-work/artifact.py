#!/usr/bin/env python3
"""Verify that the native runtime packages are the build of the reviewed source (T11 :295).

Usage: artifact.py verify --manifest <artifact-manifest.json> [--package-dir DIR] [--runtime-repo R] [--limits L]
"""
import argparse
import base64
import hashlib
import json
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def member(archive, name):
    try:
        return archive.extractfile(f"package/{name}").read()
    except (KeyError, AttributeError):
        return None


def schema_at(repo, sha, kind):
    package = subprocess.run(["git", "-C", str(repo), "show", f"{sha}:package.json"],
                             capture_output=True, text=True)
    if package.returncode != 0:
        return None
    return json.loads(package.stdout).get("openclaw", {}).get("schemaVersions", {}).get(kind)


def package_problems(entry, path, runtime):
    if not path.is_file():
        return [f"{entry['file']}: missing"]
    raw = path.read_bytes()
    problems = []
    if hashlib.sha256(raw).hexdigest() != entry["sha256"]:
        problems.append(f"{entry['file']}: sha256 differs from the manifest")
    if "sha512-" + base64.b64encode(hashlib.sha512(raw).digest()).decode() != entry["integrity"]:
        problems.append(f"{entry['file']}: integrity differs from the manifest")
    try:
        archive = tarfile.open(path, "r:gz")
    except tarfile.TarError:
        return problems + [f"{entry['file']}: not a package tarball"]
    with archive:
        package = json.loads(member(archive, "package.json") or b"{}")
        if (package.get("name"), package.get("version")) != (entry["name"], entry["version"]):
            problems.append(f"{entry['file']}: is {package.get('name')} {package.get('version')}")
        if entry["name"] == "openclaw":
            built = json.loads(member(archive, "dist/build-info.json") or b"{}").get("commit")
            if built != runtime["sourceSha"]:
                problems.append(f"{entry['file']}: built from {built}, not {runtime['sourceSha']}")
            entry_js = member(archive, "dist/entry.js") or b""
            if hashlib.sha256(entry_js).hexdigest() != runtime["entrySha256"]:
                problems.append(f"{entry['file']}: dist/entry.js is not the recorded build")
    return problems


def problems(manifest, package_dir, runtime_repo):
    runtime = manifest["runtime"]
    found = []
    for entry in manifest["packages"]:
        found += package_problems(entry, Path(package_dir) / entry["file"], runtime)
    for kind, change in manifest["migrations"].items():
        for side, sha in (("from", manifest["previousRuntime"]["sourceSha"]), ("to", runtime["sourceSha"])):
            actual = schema_at(runtime_repo, sha, kind)
            if actual != change[side]:
                found.append(f"{kind} schema at {sha[:12]} is {actual}, the manifest says {change[side]}")
    state = manifest["migrations"]["state"]
    if state["to"] > state["from"] and manifest["schemaCompatibility"] != "previous-binary-unreadable":
        found.append(f"state schema {state['from']} -> {state['to']}: the previous binary cannot read it")
    return found


LIMIT_FIELDS = ("maxAutomaticRecoveryCalls", "maxCacheReadTokens", "maxChildren", "maxConcurrentTasks",
                "maxContextTokens", "maxDepth", "maxInputTokens", "maxModelCalls", "maxOutputTokens", "maxTreeTokens")


def limit_problems(limits):
    """A production profile is finite and sourced; an unknown (null) limit keeps admission closed (T11 :297)."""
    profile = limits.get("productionProfile") or {}
    values, sources = profile.get("values", {}), profile.get("sources", {})
    found = []
    for field in LIMIT_FIELDS:
        if field not in values:
            found.append(f"{field} is missing")
            continue
        value = values[field]
        if value is not None and (isinstance(value, bool) or not isinstance(value, int) or value <= 0):
            found.append(f"{field} must be a positive integer or null")
        if not sources.get(field):
            found.append(f"{field} has no source")
    unknown = [field for field in LIMIT_FIELDS if field in values and values[field] is None]
    if limits.get("productionAdmissionEnabled") and unknown:
        found.append("production admission is enabled with unknown limits: " + ", ".join(unknown))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify",))
    parser.add_argument("--manifest", type=Path, default=ROOT / "docs/evidence/agent-work/artifact-manifest.json")
    parser.add_argument("--package-dir", type=Path)
    parser.add_argument("--runtime-repo", type=Path)
    parser.add_argument("--limits", type=Path, default=ROOT / "docs/evidence/agent-work/limits.json")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    package_dir = args.package_dir or Path(manifest["packageDir"])
    runtime_repo = args.runtime_repo or Path(json.loads(
        (ROOT / "docs/evidence/agent-work/runtime-map.json").read_text())["runtime"]["localCheckout"])
    found = problems(manifest, package_dir, runtime_repo)
    found += limit_problems(json.loads(args.limits.read_text()))
    if found:
        print("\n".join(f"artifact: {problem}" for problem in found), file=sys.stderr)
        return 1
    print(f"artifact OK: openclaw {manifest['runtime']['version']} from {manifest['runtime']['sourceSha']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
