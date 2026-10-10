#!/usr/bin/env python3
"""T11 :295: the artifact manifest pins the reviewed runtime and its packages prove it."""
import base64
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import artifact  # noqa: E402

MANIFEST = ROOT / "docs/evidence/agent-work/artifact-manifest.json"


def tgz(path, files):
    with tarfile.open(path, "w:gz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(f"package/{name}")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    raw = path.read_bytes()
    return hashlib.sha256(raw).hexdigest(), "sha512-" + base64.b64encode(hashlib.sha512(raw).digest()).decode()


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class ArtifactVerifyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.repo = root / "r"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "t")
        commits = []
        for state in (19, 27):
            (self.repo / "package.json").write_text(json.dumps(
                {"name": "openclaw", "version": "2026.9.7",
                 "openclaw": {"schemaVersions": {"state": state, "agent": 24}}}))
            git(self.repo, "add", "package.json")
            git(self.repo, "commit", "-qm", f"state {state}")
            commits.append(git(self.repo, "rev-parse", "HEAD"))
        self.previous, self.source = commits
        self.packages = root / "paquete"
        self.packages.mkdir()
        self.entry = b"console.log('entry')\n"
        main_sha, main_integrity = tgz(self.packages / "openclaw-2026.9.7.tgz", {
            "package.json": json.dumps({"name": "openclaw", "version": "2026.9.7"}).encode(),
            "dist/entry.js": self.entry,
            "dist/build-info.json": json.dumps({"version": "2026.9.7", "commit": self.source}).encode()})
        ai_sha, ai_integrity = tgz(self.packages / "openclaw-ai-2026.9.7.tgz", {
            "package.json": json.dumps({"name": "@openclaw/ai", "version": "2026.9.7"}).encode()})
        self.manifest = {
            "schema": "agent-work-artifact-manifest.v1",
            "runtime": {"sourceSha": self.source, "version": "2026.9.7",
                        "entrySha256": hashlib.sha256(self.entry).hexdigest()},
            "packages": [
                {"name": "openclaw", "version": "2026.9.7", "file": "openclaw-2026.9.7.tgz",
                 "sha256": main_sha, "integrity": main_integrity},
                {"name": "@openclaw/ai", "version": "2026.9.7", "file": "openclaw-ai-2026.9.7.tgz",
                 "sha256": ai_sha, "integrity": ai_integrity}],
            "previousRuntime": {"version": "2026.9.7", "sourceSha": self.previous},
            "migrations": {"state": {"from": 19, "to": 27}, "agent": {"from": 24, "to": 24}},
            "schemaCompatibility": "previous-binary-unreadable",
        }

    def problems(self, manifest=None):
        return artifact.problems(manifest or self.manifest, self.packages, self.repo)

    def test_the_built_packages_of_the_reviewed_source_verify(self):
        self.assertEqual(self.problems(), [])

    def test_a_package_that_is_not_the_recorded_one_is_refused(self):
        (self.packages / "openclaw-ai-2026.9.7.tgz").write_bytes(b"other")
        self.assertEqual(self.problems(), ["openclaw-ai-2026.9.7.tgz: sha256 differs from the manifest",
                                           "openclaw-ai-2026.9.7.tgz: integrity differs from the manifest",
                                           "openclaw-ai-2026.9.7.tgz: not a package tarball"])

    def test_a_package_built_from_another_commit_is_refused(self):
        self.manifest["runtime"]["sourceSha"] = self.previous
        self.assertIn(f"openclaw-2026.9.7.tgz: built from {self.source}, not {self.previous}", self.problems())

    def test_an_entry_point_that_is_not_the_reviewed_build_is_refused(self):
        self.manifest["runtime"]["entrySha256"] = "0" * 64
        self.assertEqual(self.problems(), ["openclaw-2026.9.7.tgz: dist/entry.js is not the recorded build"])

    def test_the_migrations_must_be_the_schema_of_both_commits(self):
        self.manifest["migrations"]["state"]["to"] = 26
        self.assertEqual(self.problems(), [f"state schema at {self.source[:12]} is 27, the manifest says 26"])

    def test_a_newer_schema_cannot_be_declared_readable_by_the_previous_binary(self):
        self.manifest["schemaCompatibility"] = "previous-binary-readable"
        self.assertEqual(self.problems(), ["state schema 19 -> 27: the previous binary cannot read it"])

    def test_a_missing_package_file_is_refused(self):
        (self.packages / "openclaw-2026.9.7.tgz").unlink()
        self.assertEqual(self.problems(), ["openclaw-2026.9.7.tgz: missing"])

    def test_the_cli_exits_with_the_problems(self):
        path = Path(self.temp.name) / "manifest.json"
        path.write_text(json.dumps(self.manifest))
        run = lambda: subprocess.run([sys.executable, str(ROOT / "scripts/agent-work/artifact.py"), "verify",
                                      "--manifest", str(path), "--package-dir", str(self.packages),
                                      "--runtime-repo", str(self.repo)], capture_output=True, text=True)
        good = run()
        self.assertEqual((good.returncode, good.stdout.strip()), (0, "artifact OK: openclaw 2026.9.7 from " + self.source))
        limits = json.loads((ROOT / "docs/evidence/agent-work/limits.json").read_text())
        limits["productionAdmissionEnabled"] = True
        limits["productionProfile"]["values"]["maxContextTokens"] = None
        open_limits = Path(self.temp.name) / "limits.json"
        open_limits.write_text(json.dumps(limits))
        refused = subprocess.run([sys.executable, str(ROOT / "scripts/agent-work/artifact.py"), "verify",
                                  "--manifest", str(path), "--package-dir", str(self.packages),
                                  "--runtime-repo", str(self.repo), "--limits", str(open_limits)],
                                 capture_output=True, text=True)
        self.assertEqual((refused.returncode, refused.stderr.strip()),
                         (1, "artifact: production admission is enabled with unknown limits: maxContextTokens"))
        (self.packages / "openclaw-2026.9.7.tgz").unlink()
        bad = run()
        self.assertEqual((bad.returncode, bad.stderr.strip()), (1, "artifact: openclaw-2026.9.7.tgz: missing"))


class ArtifactManifestTest(unittest.TestCase):
    def test_the_repo_manifest_matches_the_reviewed_runtime(self):
        manifest = json.loads(MANIFEST.read_text())
        packages = Path(manifest["packageDir"])
        repo = Path(json.loads((ROOT / "docs/evidence/agent-work/runtime-map.json").read_text())
                    ["runtime"]["localCheckout"])
        if not packages.is_dir() or not (repo / ".git").exists():
            self.skipTest(f"the built packages live on the build host ({packages})")
        self.assertEqual(artifact.problems(manifest, packages, repo), [])


class LimitsProfileTest(unittest.TestCase):
    FIELDS = ["maxConcurrentTasks", "maxDepth", "maxChildren", "maxModelCalls", "maxInputTokens", "maxOutputTokens",
              "maxCacheReadTokens", "maxContextTokens", "maxTreeTokens", "maxAutomaticRecoveryCalls"]

    def doc(self, enabled=False, **values):
        profile = {field: 10 for field in self.FIELDS}
        profile.update(values)
        return {"productionProfile": {"values": profile, "sources": {field: "x" for field in self.FIELDS}},
                "productionAdmissionEnabled": enabled}

    def test_an_unknown_value_blocks_admission(self):
        self.assertEqual(artifact.limit_problems(self.doc(maxContextTokens=None)), [])
        self.assertEqual(artifact.limit_problems(self.doc(True, maxContextTokens=None)),
                         ["production admission is enabled with unknown limits: maxContextTokens"])
        self.assertEqual(artifact.limit_problems(self.doc(True)), [])

    def test_every_limit_is_finite_positive_and_sourced(self):
        bad = self.doc(maxDepth=0, maxModelCalls=1.5)
        del bad["productionProfile"]["sources"]["maxChildren"]
        del bad["productionProfile"]["values"]["maxTreeTokens"]
        self.assertEqual(artifact.limit_problems(bad), [
            "maxChildren has no source", "maxDepth must be a positive integer or null",
            "maxModelCalls must be a positive integer or null", "maxTreeTokens is missing"])

    def test_the_repo_limits_are_complete_and_admission_opens_only_per_entry(self):
        limits = json.loads((ROOT / "docs/evidence/agent-work/limits.json").read_text())
        self.assertEqual(artifact.limit_problems(limits), [])
        unknown = [field for field, value in limits["productionProfile"]["values"].items() if value is None]
        self.assertEqual((unknown, limits["productionAdmissionEnabled"]), ([], False))


if __name__ == "__main__":
    unittest.main()
