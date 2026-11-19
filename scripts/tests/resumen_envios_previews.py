#!/usr/bin/env python3
import argparse
import copy
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from scripts.tests import resumen_envios_oracle as oracle

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "scripts" / "tests" / "fixtures" / "resumen-envios" / "principal.json"


def compact(result):
    view = result["view"]
    return {
        "state": view["cut"]["state"],
        "eligible_ids": sorted(
            decision["order"]["id"]
            for decision in view["assessment"]["decisions"]
            if decision["outcome"] == "eligible"
        ),
        "source_statuses": view["assessment"]["source_statuses"],
        "issues": view["issues"],
        "units": view["units"],
        "outbox": result["outbox"],
    }


def previews():
    base = json.loads(FIXTURE.read_text(encoding="utf-8"))
    cases = (
        (
            "principal",
            "2026-11-18",
            ["2026-11-18T18:00:00-07:00", "2026-11-18T18:15:00-07:00", "2026-11-18T18:30:00-07:00"],
        ),
        ("temprano", "2026-11-19", ["2026-11-19T05:00:00-07:00"]),
        ("ultimo", "2026-11-19", ["2026-11-19T09:00:00-07:00"]),
    )
    output = {}
    for kind, local_date, times in cases:
        fixture = copy.deepcopy(base)
        fixture["cut"] = {"kind": kind, "local_date": local_date, "at": times[-1]}
        fixture["times"] = times
        with tempfile.TemporaryDirectory(prefix="resumen-envios-preview-") as directory:
            work = Path(directory)
            fixture_path = work / "fixture.json"
            fixture_path.write_text(json.dumps(fixture, ensure_ascii=False), encoding="utf-8")
            env = dict(os.environ, RESUMEN_ENVIOS_DRYRUN="1", PYTHONDONTWRITEBYTECODE="1")
            process = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "scripts.resumen_envios.cli",
                    str(fixture_path),
                    "--db",
                    str(work / "ledger.sqlite"),
                    "--locks",
                    str(work / "locks"),
                ],
                cwd=ROOT,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            result = json.loads(process.stdout)
            expected = oracle.evaluate(fixture)
            observed = compact(result)
            observed["oracle"] = expected
            observed["checks"] = {
                "eligible_matches_oracle": observed["eligible_ids"] == expected["eligible_ids"],
                "sources_match_oracle": observed["source_statuses"] == expected["source_statuses"],
            }
            if not all(observed["checks"].values()):
                raise AssertionError((kind, observed["checks"]))
            output[kind] = observed
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = previews()
    if args.check:
        print(
            json.dumps(
                {
                    key: {
                        "state": value["state"],
                        "checks": value["checks"],
                        "outbox_parts": len(value["outbox"]),
                    }
                    for key, value in result.items()
                },
                ensure_ascii=False,
            )
        )
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
