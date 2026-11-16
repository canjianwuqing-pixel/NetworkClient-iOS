#!/usr/bin/env python3
"""Reject a mismatched production/ROUTE_VALIDATION Mihomo SDK at build time."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Vendor/Mihomo/SDK_BUILD15_ROUTE_VALIDATION_MANIFEST.json"
SLICES = {"iosDevice": "ios-arm64", "iosSimulator": "ios-arm64_x86_64-simulator"}
DIAGNOSTIC_APIS = ("ClashSocketHookDiagnosticsJSON", "ClashProbeNoPathDial")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--conditions", default="")
    args = parser.parse_args()
    diagnostic = "ROUTE_VALIDATION" in args.conditions.split()
    variant = "diagnostic" if diagnostic else "production"
    expected = json.loads(MANIFEST.read_text())
    hashes = expected["isolatedDiagnosticFrameworkSHA256" if diagnostic else "frameworkSHA256"]
    tags = set(expected["diagnosticGoTags" if diagnostic else "productionGoTags"])
    apple_tags = {"with_low_memory", "no_easytier"}
    sdk = args.sdk_root / "Clash.xcframework"
    for key, slice_name in SLICES.items():
        base = sdk / slice_name / "Clash.framework/Versions/A"
        binary = base / "Clash"
        info = json.loads((base / "Resources/ClashBuildInfo.json").read_text())
        header = (base / "Headers/Clash.objc.h").read_text()
        if info["sourceRevision"] != expected["upstreamCommit"]:
            raise ValueError(f"{slice_name}: upstream commit mismatch")
        if info["sdkVersion"] != expected["upstreamTag"] or info["mihomoCoreVersion"] != expected["coreVersion"]:
            raise ValueError(f"{slice_name}: pinned version mismatch")
        if info["goToolchain"] != "go" + expected["toolchain"]["go"]:
            raise ValueError(f"{slice_name}: pinned Go toolchain mismatch")
        if set(info["buildTags"]) != tags - apple_tags or set(info["buildTagsNotMacos"]) != apple_tags:
            raise ValueError(f"{slice_name}: compilation tags differ from {variant} manifest")
        if info["internalDiagnostics"] is not diagnostic or ("clash_internal" in info["buildTags"]) is not diagnostic:
            raise ValueError(f"{slice_name}: SDK variant does not match {variant} compilation conditions")
        for symbol in DIAGNOSTIC_APIS:
            if (symbol in header) is not diagnostic:
                raise ValueError(f"{slice_name}: {symbol} export does not match {variant}")
        if sha256(binary) != hashes[key]:
            raise ValueError(f"{slice_name}: SDK binary hash differs from pinned {variant} manifest")
    print(f"Verified {variant} Mihomo SDK at fixed Core {expected['coreVersion']}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError) as error:
        print(f"Mihomo SDK selection error: {error}", file=sys.stderr)
        sys.exit(1)
