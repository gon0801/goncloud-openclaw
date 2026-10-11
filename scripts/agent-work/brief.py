#!/usr/bin/env python3
"""Write one managed-task brief under the instruction root and print its submit fragments.

Standard library only: this file is copied alone to the gateway host.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

MAX_INSTRUCTION_BYTES = 1024 * 1024


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


def instruction_ref(digest):
    return {"ref": f"artifact:{digest}", "digest": f"sha256:{digest}"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="managedTasks.instructionRoot")
    parser.add_argument("--file", type=Path, help="brief file; stdin when omitted")
    parser.add_argument("--host", help="target hostId, for example mac-local")
    parser.add_argument("--adapter", help="target adapterId, for example claude_opus")
    args = parser.parse_args(argv)
    if bool(args.host) != bool(args.adapter):
        parser.error("--host and --adapter go together")
    content = args.file.read_bytes() if args.file else sys.stdin.buffer.read()
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
