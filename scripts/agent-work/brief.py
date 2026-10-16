#!/usr/bin/env python3
"""Write one managed-task brief under the instruction root and print its submit fragments.

Standard library only: this file is copied alone to the gateway host.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

MAX_INSTRUCTION_BYTES = 1024 * 1024

# Copies of LAUNCH_SCHEMA and HEADER_END (sesion.py) and of PROVIDER and MODEL_NAME (modelos.py), which
# this file cannot import on the gateway host. test-agent-work-routing.py compares them.
LAUNCH_SCHEMA = "agent-work.launch.v1"
HEADER_END = "---"
PROVIDER = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
MODEL_NAME = re.compile(r"[A-Za-z0-9._:@/-]{1,128}")
# The profile line and section (SUA-03, design 4.5): `canonical` is contexto.canonico, which this file
# cannot import either; test-agent-work-routing.py compares them.
PROFILE_ID = re.compile(r"[a-z][a-z0-9-]{0,31}")


def write_instruction(instruction_root, content):
    """Publish content as <root>/<sha256> and return the hex digest."""
    if not content or len(content) > MAX_INSTRUCTION_BYTES:
        raise ValueError(f"brief must contain 1 to {MAX_INSTRUCTION_BYTES} bytes")
    digest = hashlib.sha256(content).hexdigest()
    root = Path(instruction_root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("instruction root must be an existing directory")
    artifact = root / digest
    pending = None
    try:
        descriptor, pending = tempfile.mkstemp(prefix=".managed-instruction-", dir=root)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(pending, artifact)
        except FileExistsError:
            if artifact.is_symlink() or artifact.read_bytes() != content:
                raise ValueError("instruction artifact differs from digest")
    finally:
        if pending is not None:
            os.unlink(pending)
    return digest


def model_id(text):
    """A well-formed <provider>/<model>. Whether it may run is the host's answer, not this file's."""
    provider, slash, name = text.partition("/")
    if not slash or not PROVIDER.fullmatch(provider) or not MODEL_NAME.fullmatch(name):
        raise argparse.ArgumentTypeError(f"not <provider>/<model>: {text!r}")
    return text


def profile_id(text):
    if not PROFILE_ID.fullmatch(text):
        raise argparse.ArgumentTypeError(f"not a profile id: {text!r}")
    return text


def launch_header(model, profile=None):
    """The header the host reads with LaunchHeader.parse. It goes inside the brief so the digest covers it."""
    lines = [LAUNCH_SCHEMA]
    if model:
        lines.append(f"model: {model}")
    if profile:
        lines.append(f"profile: {profile}")
    return ("\n".join([*lines, HEADER_END]) + "\n").encode()


def canonical(document):
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def find_profile(profiles_file, profile):
    """The profile named profile in perfiles.v1.json, or ValueError."""
    try:
        document = json.loads(Path(profiles_file).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read {profiles_file}: {exc}") from exc
    for candidate in document.get("profiles", []):
        if candidate.get("id") == profile:
            return candidate
    raise ValueError(f"unknown profile {profile!r} in {profiles_file}")


def profile_section(profile):
    """What a native child reads of its profile, ahead of the prose: the digest marks which profile."""
    digest = hashlib.sha256(canonical(profile)).hexdigest()
    skills = ", ".join(profile["skills"]) or "ninguna"
    writes = "sí" if profile["writesSource"] else "no"
    return (f"<!-- perfil inicio id={profile['id']} digest=sha256:{digest} -->\n"
            f"Tu perfil en este encargo: {profile['id']}. {profile['purpose']}\n"
            f"Contratos que entregas: {', '.join(profile['resultContracts'])}. Escribes fuente: {writes}. "
            f"Skills de tu perfil, además de poteto: {skills}.\n"
            "<!-- perfil fin -->\n").encode()


def instruction_ref(digest):
    return {"ref": f"artifact:{digest}", "digest": f"sha256:{digest}"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="managedTasks.instructionRoot")
    parser.add_argument("--file", type=Path, help="brief file; stdin when omitted")
    parser.add_argument("--host", help="target hostId, for example mac-local")
    parser.add_argument("--adapter", help="target adapterId, for example fixture-cli-a")
    parser.add_argument("--model", type=model_id, help="model the adapter launches, as <provider>/<model>")
    parser.add_argument("--perfil", type=profile_id, help="worker profile, for example ingenieria")
    parser.add_argument("--perfiles", type=Path, help="perfiles.v1.json; required by --perfil without --host")
    args = parser.parse_args(argv)
    if bool(args.host) != bool(args.adapter):
        parser.error("--host and --adapter go together")
    if args.perfiles and not args.perfil:
        parser.error("--perfiles goes with --perfil")
    if args.perfil and not args.host and not args.perfiles:
        parser.error("--perfil without --host is a native target and needs --perfiles")
    section = b""
    if args.perfiles:
        try:
            profile = find_profile(args.perfiles, args.perfil)
        except ValueError as exc:
            print(f"brief: {exc}", file=sys.stderr)
            return 1
        # A CLI host reads the profile from its own copy; a native child reads it here.
        section = b"" if args.host else profile_section(profile)
    content = args.file.read_bytes() if args.file else sys.stdin.buffer.read()
    if (args.model or args.perfil) and content:
        # An empty brief stays empty, so write_instruction refuses it instead of publishing a bare header.
        content = launch_header(args.model, args.perfil) + section + content
    try:
        digest = write_instruction(args.root, content)
    except (OSError, ValueError) as exc:
        print(f"brief: {exc}", file=sys.stderr)
        return 1
    fragments = {"instructionRef": instruction_ref(digest)}
    if args.host:
        fragments["target"] = {"kind": "cli", "hostId": args.host, "adapterId": args.adapter}
    print(json.dumps(fragments, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
