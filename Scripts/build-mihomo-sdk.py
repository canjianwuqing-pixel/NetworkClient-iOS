#!/usr/bin/env python3
"""Build both fixed Mihomo Apple SDK variants from an explicitly supplied clone.

The output directory must be new and outside the project. Nothing in the input
clone or the checked-in SDK is modified. A failed build leaves its evidence in
the output directory for inspection.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Vendor/Mihomo/SDK_BUILD15_ROUTE_VALIDATION_MANIFEST.json"
DIAGNOSTIC_APIS = ("ClashSocketHookDiagnosticsJSON", "ClashProbeNoPathDial")


def run(*args: str, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    print("+", " ".join(args), flush=True)
    return subprocess.check_output(args, cwd=cwd, env=env, text=True).strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_framework(path: Path, revision: str, internal: bool) -> dict:
    results = {}
    for name, relative in (
        ("iosDevice", "ios-arm64"),
        ("iosSimulator", "ios-arm64_x86_64-simulator"),
    ):
        framework = path / relative / "Clash.framework/Versions/A"
        binary = framework / "Clash"
        header = (framework / "Headers/Clash.objc.h").read_text()
        info = json.loads((framework / "Resources/ClashBuildInfo.json").read_text())
        if info["sourceRevision"] != revision or info["mihomoCoreVersion"] != "1.19.33":
            raise RuntimeError(f"wrong pinned source or Core version in {relative}")
        if info["internalDiagnostics"] is not internal:
            raise RuntimeError(f"wrong diagnostic build mode in {relative}")
        for symbol in DIAGNOSTIC_APIS:
            if (symbol in header) is not internal:
                raise RuntimeError(f"wrong export status for {symbol} in {relative}")
        results[name] = {"binarySHA256": sha256(binary), "buildInfo": info}
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="local ProjectClash/Clash Git clone")
    parser.add_argument("--output-root", type=Path, required=True, help="new directory outside this repository")
    parser.add_argument("--go-bin-dir", type=Path, required=True)
    parser.add_argument("--gomobile-bin-dir", type=Path, required=True)
    parser.add_argument("--gopath", type=Path, help="existing Go workspace; optional")
    parser.add_argument("--gomodcache", type=Path, help="existing Go module cache; optional")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output_root.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        parser.error("--output-root must name a new directory outside the iOS project")
    manifest = json.loads(MANIFEST.read_text())
    revision = manifest["upstreamCommit"]
    if run("git", "-C", str(source), "rev-parse", "HEAD") != revision:
        parser.error("input clone HEAD does not match the pinned commit")
    if run("git", "-C", str(source), "rev-list", "-n", "1", manifest["upstreamTag"]) != revision:
        parser.error("input clone tag does not match the pinned commit")
    go = args.go_bin_dir.resolve(strict=True) / "go"
    gomobile = args.gomobile_bin_dir.resolve(strict=True) / "gomobile"
    if not go.is_file() or not gomobile.is_file():
        parser.error("the requested Go and gomobile executables must exist")
    output.mkdir(parents=True)
    stage = output / "pinned-source-with-patches"
    run("git", "clone", "--local", "--no-hardlinks", "--no-checkout", "--quiet", str(source), str(stage))
    run("git", "checkout", "--detach", "--quiet", revision, cwd=stage)
    for patch_record in manifest["patches"]:
        patch = ROOT / "Vendor/Mihomo" / patch_record["path"]
        if sha256(patch) != patch_record["sha256"]:
            raise RuntimeError(f"patch hash mismatch: {patch.name}")
        run("git", "apply", "--check", str(patch), cwd=stage)
        run("git", "apply", str(patch), cwd=stage)
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join((str(args.go_bin_dir.resolve()), str(args.gomobile_bin_dir.resolve()), env["PATH"]))
    env["GOPROXY"] = "off"
    env["GOSUMDB"] = "off"
    if args.gopath:
        env["GOPATH"] = str(args.gopath.resolve(strict=True))
    if args.gomodcache:
        env["GOMODCACHE"] = str(args.gomodcache.resolve(strict=True))
    result = {"upstreamCommit": revision, "patches": manifest["patches"], "variants": {}}
    for variant, internal in (("production", False), ("diagnostic", True)):
        framework = output / variant / "Clash.xcframework"
        framework.parent.mkdir()
        command = [str(go), "run", "./cmd/build_libbox", "-target", "apple", "-slices", "ios-device,ios-simulator", "-output", str(framework)]
        if internal:
            command.append("-internal")
        subprocess.run(command, cwd=stage, env=env, check=True)
        result["variants"][variant] = inspect_framework(framework, revision, internal)
        run(sys.executable, str(ROOT / "Scripts/verify-mihomo-sdk.py"),
            "--sdk-root", str(framework.parent),
            "--conditions", "ROUTE_VALIDATION" if internal else "")
    (output / "build-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Verified both pinned SDK variants:", output / "build-results.json")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"SDK build failed: {error}", file=sys.stderr)
        sys.exit(1)
