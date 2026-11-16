#!/usr/bin/env python3
"""Generate the reviewable Go source lock from pinned `go list` evidence.

This helper is not used by an app build. It turns already-downloaded, pinned
module metadata into a deterministic lock; it never selects a version.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


LICENSE_NAMES = re.compile(r"^(license|copying|notice|copyright)(\..*)?$", re.I)


def json_objects(path: Path) -> list[dict]:
    text = path.read_text()
    decoder = json.JSONDecoder()
    result: list[dict] = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index == len(text):
            break
        value, index = decoder.raw_decode(text, index)
        result.append(value)
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def module_escape(value: str) -> str:
    output = []
    for character in value:
        if "A" <= character <= "Z":
            output.extend(("!", character.lower()))
        else:
            output.append(character)
    return "".join(output)


def directory_name(path: str, version: str) -> str:
    safe_path = path.replace("/", "__").replace("\\", "__")
    safe_version = re.sub(r"[^A-Za-z0-9._+-]", "_", version)
    return f"{safe_path}@{safe_version}"


def license_label(files: list[Path]) -> str:
    text = "\n".join(
        path.read_text(errors="ignore")[:20000].lower() for path in files
    )
    if "mozilla public license" in text:
        return "MPL-2.0"
    if "gnu affero general public license" in text:
        return "AGPL"
    if "gnu lesser general public license" in text:
        return "LGPL"
    if "gnu general public license" in text:
        if "version 3" in text:
            return "GPL-3.0"
        if "version 2" in text:
            return "GPL-2.0"
        return "GPL"
    if "apache license" in text and "version 2.0" in text:
        return "Apache-2.0"
    if "permission is hereby granted, free of charge" in text:
        return "MIT"
    if "redistribution and use in source and binary forms" in text:
        return "BSD"
    if "permission to use, copy, modify, and/or distribute" in text:
        return "ISC"
    return "SEE-LICENSE-FILES"


def read_set(path: Path) -> set[str]:
    return {line.strip() for line in path.read_text().splitlines() if line.strip()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module-graph", type=Path, required=True)
    parser.add_argument("--runtime-packages", type=Path, required=True)
    parser.add_argument("--build-modules", type=Path, required=True)
    parser.add_argument("--root-test-modules", type=Path, required=True)
    parser.add_argument("--bind-test-modules", type=Path, required=True)
    parser.add_argument("--project-clash-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    project_root = args.project_clash_root.resolve(strict=True)
    modules = json_objects(args.module_graph)
    packages = json_objects(args.runtime_packages)
    runtime = {
        package["Module"]["Path"]
        for package in packages
        if package.get("Module") and package["Module"].get("Path")
    }
    build = read_set(args.build_modules)
    tests = read_set(args.root_test_modules) | read_set(args.bind_test_modules)

    records = []
    for module in modules:
        if module.get("Main"):
            continue
        requested_path = module["Path"]
        requested_version = module.get("Version", "")
        replacement = module.get("Replace")
        source = replacement or module
        source_path = source["Path"]
        source_version = source.get("Version", "")
        source_dir = Path(source["Dir"]).resolve(strict=True)
        scopes = []
        if not module.get("Indirect", False):
            scopes.append("direct")
        if requested_path in runtime:
            scopes.append("runtime")
        if requested_path in build:
            scopes.append("build")
        if requested_path in tests:
            scopes.append("test")
        if not scopes:
            scopes.append("module-graph")

        try:
            relative = source_dir.relative_to(project_root)
            source_kind = "embedded"
            source_record = {
                "kind": source_kind,
                "path": f"ProjectClash/{relative.as_posix()}" if relative.parts else "ProjectClash",
            }
        except ValueError:
            if not source_version:
                raise SystemExit(f"external module has no version: {requested_path}")
            source_kind = "go-module"
            escaped_path = module_escape(source_path)
            escaped_version = module_escape(source_version)
            source_record = {
                "kind": source_kind,
                "module": source_path,
                "version": source_version,
                "sum": source.get("Sum", ""),
                "goModSum": source.get("GoModSum", ""),
                "url": (
                    "https://proxy.golang.org/"
                    f"{escaped_path}/@v/{escaped_version}.zip"
                ),
                "directory": directory_name(requested_path, requested_version),
            }

        license_paths = sorted(
            path for path in source_dir.iterdir()
            if path.is_file() and LICENSE_NAMES.match(path.name)
        )
        if not license_paths:
            license_paths = sorted(
                path for path in source_dir.rglob("*")
                if path.is_file()
                and len(path.relative_to(source_dir).parts) <= 2
                and LICENSE_NAMES.match(path.name)
            )
        licenses = [
            {"path": path.relative_to(source_dir).as_posix(), "sha256": sha256(path)}
            for path in license_paths
        ]
        records.append({
            "module": requested_path,
            "version": requested_version,
            "scopes": sorted(scopes),
            "source": source_record,
            "license": license_label(license_paths),
            "licenseFiles": licenses,
        })

    records.sort(key=lambda item: (item["module"], item["version"]))
    runtime_records = [record for record in records if "runtime" in record["scopes"]]
    direct_records = [record for record in records if "direct" in record["scopes"]]
    gpl_runtime = [
        record for record in runtime_records if record["license"].startswith("GPL")
    ]
    copyleft_runtime = [
        record for record in runtime_records
        if record["license"].startswith(("GPL", "LGPL", "AGPL"))
    ]
    lock = {
        "schemaVersion": 1,
        "sourceStrategy": "complete Go module source trees",
        "moduleGraphCount": len(records),
        "directDependencyCount": len(direct_records),
        "runtimeDependencyCount": len(runtime_records),
        "gplRuntimeDependencyCount": len(gpl_runtime),
        "copyleftRuntimeDependencyCount": len(copyleft_runtime),
        "modules": records,
    }
    args.output.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: lock[key] for key in (
        "moduleGraphCount", "directDependencyCount", "runtimeDependencyCount",
        "gplRuntimeDependencyCount",
    )}, sort_keys=True))


if __name__ == "__main__":
    main()
