#!/usr/bin/env python3
"""Offline fail-closed tests for GPL source preparation."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-corresponding-source.py")
SPEC = importlib.util.spec_from_file_location("gpl_prepare", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def git(*arguments: str, cwd: Path) -> str:
    return subprocess.check_output(("git", *arguments), cwd=cwd, text=True).strip()


def base_lock() -> dict:
    return {
        "projectClash": {
            "repository": MODULE.OFFICIAL_REPOSITORY,
            "tag": "v1.19.33-clash.2",
            "commit": "a" * 40,
            "treeSHA": "b" * 40,
        },
        "patches": [
            {"order": number, "name": f"{number:04d}-test.patch", "sha256": "c" * 64}
            for number in (2, 3, 4, 5)
        ],
        "toolchain": {"go": "1.26.10", "gomobile": "v0.1.13"},
        "sourceTree": {"patchedDigest": "d" * 64},
    }


class CorrespondingSourcePreparationTests(unittest.TestCase):
    def test_floating_branch_is_rejected(self) -> None:
        lock = base_lock()
        lock["projectClash"]["branch"] = "main"
        with self.assertRaisesRegex(MODULE.PreparationError, "floating"):
            MODULE.validate_source_lock(lock)

    def test_wrong_upstream_commit_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            git("init", "-q", cwd=source)
            git("config", "user.name", "GPL Test", cwd=source)
            git("config", "user.email", "gpl-test@example.invalid", cwd=source)
            (source / "LICENSE").write_text("license")
            git("add", "LICENSE", cwd=source)
            git("commit", "-qm", "fixture", cwd=source)
            git("tag", "v1.19.33-clash.2", cwd=source)
            git("remote", "add", "origin", MODULE.OFFICIAL_REPOSITORY, cwd=source)
            with self.assertRaisesRegex(MODULE.PreparationError, "HEAD"):
                MODULE.verify_git_source(source, base_lock())

    def test_wrong_patch_sha_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patch = root / "Vendor/Mihomo/0002-test.patch"
            patch.parent.mkdir(parents=True)
            patch.write_text("not the locked patch")
            lock = base_lock()
            lock["patches"] = [lock["patches"][0]]
            with self.assertRaisesRegex(MODULE.PreparationError, "SHA-256"):
                MODULE.apply_patches(root, lock, root)

    def test_missing_patch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = base_lock()
            lock["patches"] = [lock["patches"][0]]
            with self.assertRaisesRegex(MODULE.PreparationError, "missing patch"):
                MODULE.apply_patches(root, lock, root)

    def test_patch_apply_failure_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            git("init", "-q", cwd=source)
            patch = root / "Vendor/Mihomo/0002-test.patch"
            patch.parent.mkdir(parents=True)
            patch.write_text("this is not a patch\n")
            lock = base_lock()
            lock["patches"] = [{
                "order": 2,
                "name": patch.name,
                "sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
            }]
            with self.assertRaisesRegex(MODULE.PreparationError, "command failed"):
                MODULE.apply_patches(source, lock, root)

    def test_missing_license_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "LICENSE"
            with self.assertRaisesRegex(MODULE.PreparationError, "missing license"):
                MODULE.verify_locked_file(path, "0" * 64, "license")

    def test_license_sha_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "LICENSE"
            path.write_text("unexpected license text\n")
            with self.assertRaisesRegex(MODULE.PreparationError, "SHA-256 mismatch"):
                MODULE.verify_locked_file(path, "0" * 64, "license")

    def test_source_tree_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source.go").write_text("package source\n")
            with self.assertRaisesRegex(MODULE.PreparationError, "digest mismatch"):
                MODULE.verify_tree_digest(root, "0" * 64, "fixture")

    def test_double_generation_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first"
            second = root / "second"
            for output in (first, second):
                (output / "nested").mkdir(parents=True)
                (output / "a.txt").write_text("same\n")
                (output / "nested/b.txt").write_bytes(b"same bytes\n")
            self.assertEqual(MODULE.tree_digest(first), MODULE.tree_digest(second))

    def test_checked_in_locks_are_structurally_valid(self) -> None:
        lock = json.loads(MODULE.SOURCE_LOCK_PATH.read_text())
        MODULE.validate_source_lock(lock)
        MODULE.verify_locked_file(
            MODULE.THIRD_PARTY_LOCK_PATH,
            lock["thirdPartySourceLockSHA256"],
            "third-party source lock",
        )


if __name__ == "__main__":
    unittest.main()
