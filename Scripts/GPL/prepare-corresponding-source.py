#!/usr/bin/env python3
"""Prepare deterministic ProjectClash corresponding-source staging.

The tool is fail-closed. It selects no floating version, never reads private
configuration trees, and writes only to a new directory outside the
NetworkClient repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
SOURCE_LOCK_PATH = ROOT / "Compliance/GPL/SOURCE_LOCK.json"
THIRD_PARTY_LOCK_PATH = ROOT / "Compliance/GPL/THIRD_PARTY_SOURCE_LOCK.json"
OFFICIAL_REPOSITORY = "https://github.com/ProjectClash/Clash.git"
PINNED_TAG_PATTERN = re.compile(r"^v\d+\.\d+\.\d+-clash\.\d+$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class PreparationError(RuntimeError):
    pass


def run(*arguments: str, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    process = subprocess.run(
        arguments, cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if process.returncode:
        detail = process.stderr.strip() or process.stdout.strip()
        raise PreparationError(f"command failed ({' '.join(arguments)}): {detail}")
    return process.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_records(root: Path) -> list[tuple[str, int, str]]:
    records = []
    for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
        relative = path.relative_to(root)
        if ".git" in relative.parts:
            continue
        records.append((relative.as_posix(), path.stat().st_size, sha256(path)))
    return records


def tree_digest(root: Path) -> str:
    canonical = "".join(
        f"{digest}  {relative}\n" for relative, _, digest in tree_records(root)
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def write_tree_manifest(root: Path, destination: Path) -> str:
    records = tree_records(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("".join(
        f"{relative}\t{size}\t{digest}\n" for relative, size, digest in records
    ))
    canonical = "".join(
        f"{digest}  {relative}\n" for relative, _, digest in records
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def validate_source_lock(lock: dict) -> None:
    project = lock.get("projectClash", {})
    if project.get("repository") != OFFICIAL_REPOSITORY:
        raise PreparationError("only the official ProjectClash HTTPS repository is allowed")
    if "branch" in project or not PINNED_TAG_PATTERN.fullmatch(project.get("tag", "")):
        raise PreparationError("floating branches and unpinned tags are forbidden")
    if not HEX40.fullmatch(project.get("commit", "")):
        raise PreparationError("the upstream commit must be a full SHA-1")
    if not HEX40.fullmatch(project.get("treeSHA", "")):
        raise PreparationError("the upstream tree must be a full SHA-1")
    patches = lock.get("patches", [])
    if [patch.get("order") for patch in patches] != [2, 3, 4, 5]:
        raise PreparationError("patch order must be exactly 0002, 0003, 0004, 0005")
    for patch in patches:
        if not patch.get("name", "").startswith(f"{patch['order']:04d}-"):
            raise PreparationError("patch name does not match its fixed order")
        if not HEX64.fullmatch(patch.get("sha256", "")):
            raise PreparationError("every patch must carry a full SHA-256")
    toolchain = lock.get("toolchain", {})
    if toolchain.get("go") != "1.26.10" or toolchain.get("gomobile") != "v0.1.13":
        raise PreparationError("unexpected Go or gomobile version")


def verify_locked_file(path: Path, expected: str, label: str) -> None:
    if not path.is_file():
        raise PreparationError(f"missing {label}: {path}")
    actual = sha256(path)
    if actual != expected:
        raise PreparationError(f"{label} SHA-256 mismatch: {actual}")


def verify_tree_digest(path: Path, expected: str, label: str) -> None:
    actual = tree_digest(path)
    if actual != expected:
        raise PreparationError(f"{label} tree digest mismatch: {actual}")


def canonical_remote(value: str) -> str:
    return value.removesuffix("/").removesuffix(".git")


def verify_git_source(source: Path, lock: dict) -> None:
    project = lock["projectClash"]
    origin = run("git", "-C", str(source), "remote", "get-url", "origin")
    if canonical_remote(origin) != canonical_remote(OFFICIAL_REPOSITORY):
        raise PreparationError(f"unexpected upstream origin: {origin}")
    if run("git", "-C", str(source), "rev-parse", "HEAD") != project["commit"]:
        raise PreparationError("upstream HEAD does not match the locked commit")
    if run("git", "-C", str(source), "rev-parse", f"{project['tag']}^{{}}") != project["commit"]:
        raise PreparationError("upstream tag does not resolve to the locked commit")
    if run("git", "-C", str(source), "rev-parse", "HEAD^{tree}") != project["treeSHA"]:
        raise PreparationError("upstream Git tree does not match the lock")
    verify_locked_file(source / "LICENSE", project["licenseSHA256"], "ProjectClash LICENSE")
    verify_locked_file(source / "NOTICE", project["noticeSHA256"], "ProjectClash NOTICE")
    verify_locked_file(
        source / "THIRD_PARTY_LICENSES.md",
        project["thirdPartyLicensesSHA256"],
        "ProjectClash third-party license summary",
    )
    verify_locked_file(source / "go.mod", project["goModSHA256"], "ProjectClash go.mod")
    verify_locked_file(source / "go.sum", project["goSumSHA256"], "ProjectClash go.sum")
    verify_tree_digest(source, lock["sourceTree"]["upstreamDigest"], "upstream")


def clone_upstream(destination: Path, lock: dict, local_source: Path | None) -> None:
    if local_source:
        local_source = local_source.resolve(strict=True)
        run("git", "clone", "--local", "--no-hardlinks", "--no-checkout", "--quiet",
            str(local_source), str(destination))
        run("git", "-C", str(destination), "remote", "set-url", "origin", OFFICIAL_REPOSITORY)
    else:
        run("git", "clone", "--no-checkout", "--quiet", OFFICIAL_REPOSITORY, str(destination))
    run("git", "-C", str(destination), "checkout", "--detach", "--quiet",
        lock["projectClash"]["commit"])
    verify_git_source(destination, lock)


def apply_patches(source: Path, lock: dict, repository: Path = ROOT) -> None:
    for record in lock["patches"]:
        patch = repository / "Vendor/Mihomo" / record["name"]
        verify_locked_file(patch, record["sha256"], f"patch {record['name']}")
        run("git", "apply", "--check", str(patch), cwd=source)
        run("git", "apply", str(patch), cwd=source)
    verify_tree_digest(source, lock["sourceTree"]["patchedDigest"], "patched source")


def parse_json_stream(text: str) -> list[dict]:
    decoder = json.JSONDecoder()
    values = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index == len(text):
            break
        value, index = decoder.raw_decode(text, index)
        values.append(value)
    return values


def go_environment(go: Path, cache: Path, allow_network: bool) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update({
        "PATH": os.pathsep.join((str(go.parent), environment.get("PATH", ""))),
        "GOTOOLCHAIN": "local",
        "GOPATH": str(cache / "gopath"),
        "GOMODCACHE": str(cache / "gomod"),
        "GOPROXY": "https://proxy.golang.org" if allow_network else "off",
        "GOSUMDB": "sum.golang.org" if allow_network else "off",
        "GOPRIVATE": "",
        "GONOSUMDB": "",
    })
    (cache / "gopath").mkdir(parents=True, exist_ok=True)
    (cache / "gomod").mkdir(parents=True, exist_ok=True)
    return environment


def verify_go(go: Path, lock: dict) -> None:
    version = run(str(go), "version")
    expected = f"go version go{lock['toolchain']['go']} "
    if expected not in version:
        raise PreparationError(f"wrong Go toolchain: {version}")


def stage_module_sources(
    third_party_lock: dict, destination: Path, go: Path, cache: Path,
) -> dict[str, Path]:
    external = {}
    for record in third_party_lock["modules"]:
        source = record["source"]
        if source["kind"] != "go-module":
            continue
        if not source["url"].startswith("https://proxy.golang.org/"):
            raise PreparationError("module source URL is not the locked HTTPS Go proxy")
        external[(source["module"], source["version"])] = source
    arguments = [f"{module}@{version}" for module, version in sorted(external)]
    environment = go_environment(go, cache, allow_network=True)
    output = run(str(go), "mod", "download", "-json", *arguments, env=environment)
    downloads = {
        (item["Path"], item["Version"]): item for item in parse_json_stream(output)
    }
    destination.mkdir(parents=True)
    copied: dict[str, Path] = {}
    for record in third_party_lock["modules"]:
        source = record["source"]
        if source["kind"] != "go-module":
            continue
        item = downloads.get((source["module"], source["version"]))
        if not item or item.get("Error"):
            raise PreparationError(f"module source unavailable: {record['module']}")
        if item.get("Sum") != source["sum"] or item.get("GoModSum") != source["goModSum"]:
            raise PreparationError(f"module checksum mismatch: {record['module']}")
        source_dir = Path(item["Dir"]).resolve(strict=True)
        output_dir = destination / source["directory"]
        shutil.copytree(source_dir, output_dir, symlinks=False)
        for license_record in record["licenseFiles"]:
            verify_locked_file(
                output_dir / license_record["path"], license_record["sha256"],
                f"{record['module']} license",
            )
        if "runtime" in record["scopes"] and not record["licenseFiles"]:
            raise PreparationError(f"runtime module has no license file: {record['module']}")
        copied[record["module"]] = output_dir
    return copied


def verify_embedded_sources(third_party_lock: dict, project_clash: Path) -> None:
    for record in third_party_lock["modules"]:
        source = record["source"]
        if source["kind"] != "embedded":
            continue
        prefix = "ProjectClash/"
        relative = source["path"]
        directory = project_clash if relative == "ProjectClash" else project_clash / relative.removeprefix(prefix)
        if not directory.is_dir():
            raise PreparationError(f"missing embedded module: {record['module']}")
        for license_record in record["licenseFiles"]:
            verify_locked_file(
                directory / license_record["path"], license_record["sha256"],
                f"{record['module']} embedded license",
            )
        if "runtime" in record["scopes"] and not record["licenseFiles"]:
            raise PreparationError(f"embedded runtime module has no license: {record['module']}")


def copy_materials(output: Path, upstream: Path, patched: Path, lock: dict) -> None:
    source = output / "source"
    project_clash = source / "ProjectClash"
    shutil.copytree(patched, project_clash, ignore=shutil.ignore_patterns(".git"))
    network_client = source / "NetworkClient"
    network_client.mkdir(parents=True)
    (network_client / "README.txt").write_text(
        "The release-matched NetworkClient source tree is added by GPL Source Package Batch 2.\n"
    )
    patches = output / "patches"
    patches.mkdir(parents=True)
    for record in lock["patches"]:
        shutil.copy2(ROOT / "Vendor/Mihomo" / record["name"], patches / record["name"])
    licenses = output / "licenses"
    shutil.copytree(ROOT / "Vendor/Mihomo/ThirdPartyLicenses", licenses / "go-modules")
    project_licenses = licenses / "ProjectClash"
    project_licenses.mkdir(parents=True)
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_LICENSES.md"):
        shutil.copy2(project_clash / name, project_licenses / name)
    packet_flow = licenses / "PacketFlowBridge"
    packet_flow.mkdir(parents=True)
    shutil.copy2(ROOT / "Vendor/Mihomo/ADAPTER_LICENSE.txt", packet_flow / "ADAPTER_LICENSE.txt")
    shutil.copy2(
        ROOT / "Vendor/Mihomo/ADAPTER_PACKETFLOW_PROVENANCE.md",
        packet_flow / "ADAPTER_PACKETFLOW_PROVENANCE.md",
    )
    build_scripts = output / "build/Scripts"
    build_scripts.mkdir(parents=True)
    for name in ("build-mihomo-sdk.py", "verify-mihomo-sdk.py"):
        shutil.copy2(ROOT / "Scripts" / name, build_scripts / name)
    metadata = output / "build/VendorMetadata"
    metadata.mkdir(parents=True)
    # SDK_BUILD_MANIFEST.json is a historical local-build record that contains
    # signing-environment metadata. The current authoritative SDK manifest below
    # is sufficient for source reconstruction and avoids publishing that private
    # build provenance in corresponding-source staging.
    for name in ("README.md", "SDK_BUILD15_ROUTE_VALIDATION_MANIFEST.json"):
        shutil.copy2(ROOT / "Vendor/Mihomo" / name, metadata / name)
    bundle = output / "build/ProjectClash-upstream.bundle"
    run(
        "git", "-C", str(upstream), "bundle", "create", str(bundle),
        lock["projectClash"]["tag"],
    )
    (output / "build/README.md").write_text(
        "# Offline rebuild input\n\n"
        "Clone `ProjectClash-upstream.bundle`, check out the commit recorded in "
        "`manifests/SOURCE_LOCK.json`, then apply the four files in `patches/` in "
        "numeric order. This reconstructs the Git metadata expected by the included "
        "SDK build script while `source/ProjectClash/` remains the complete patched "
        "preferred-form source for inspection and modification. All external Go "
        "module sources are already under `source/third_party/go-modules/`.\n"
    )


def generate_bindings(
    patched: Path, output: Path, go: Path, gobind: Path, cache: Path, lock: dict,
) -> None:
    if not gobind.is_file():
        raise PreparationError(f"missing gobind executable: {gobind}")
    tags = ",".join(lock["toolchain"]["buildTags"])
    environment = go_environment(go, cache, allow_network=False)
    environment.update({"GOOS": "ios", "GOARCH": "arm64", "CGO_ENABLED": "1"})
    environment["PATH"] = os.pathsep.join((str(gobind.parent), environment["PATH"]))
    destination = output / "build/generated-bindings"
    destination.mkdir(parents=True)
    run(
        str(gobind), "-lang=go,objc", "-outdir", str(destination),
        f"-tags={tags}", ".", cwd=patched / "bind/clash", env=environment,
    )
    if not (destination / "src/gobind/Clash.objc.h").is_file():
        raise PreparationError("gobind did not generate the expected Objective-C bridge")


def verify_sdk(lock: dict) -> None:
    base = ROOT / "Vendor/Mihomo/Clash.xcframework"
    verify_locked_file(
        base / "ios-arm64/Clash.framework/Versions/A/Clash",
        lock["sdk"]["deviceBinarySHA256"], "device SDK binary",
    )
    verify_locked_file(
        base / "ios-arm64_x86_64-simulator/Clash.framework/Versions/A/Clash",
        lock["sdk"]["simulatorBinarySHA256"], "simulator SDK binary",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("--gobind", type=Path, required=True)
    parser.add_argument("--upstream-clone", type=Path)
    parser.add_argument("--module-cache", type=Path)
    arguments = parser.parse_args()

    output = arguments.output_root.expanduser().absolute()
    repository = ROOT.resolve()
    if output.exists() or output == repository or repository in output.parents:
        parser.error("--output-root must be a new directory outside the repository")
    if "Private" in output.parts:
        parser.error("Private paths are not allowed")
    work = output.with_name(output.name + ".work")
    if work.exists():
        parser.error(f"temporary work path already exists: {work}")

    source_lock = json.loads(SOURCE_LOCK_PATH.read_text())
    third_party_lock = json.loads(THIRD_PARTY_LOCK_PATH.read_text())
    validate_source_lock(source_lock)
    verify_locked_file(
        THIRD_PARTY_LOCK_PATH, source_lock["thirdPartySourceLockSHA256"],
        "third-party source lock",
    )
    go = arguments.go.resolve(strict=True)
    gobind = arguments.gobind.resolve(strict=True)
    verify_go(go, source_lock)
    verify_sdk(source_lock)

    work.mkdir(parents=True)
    try:
        upstream = work / "upstream"
        clone_upstream(upstream, source_lock, arguments.upstream_clone)
        patched = work / "patched"
        run("git", "clone", "--local", "--no-hardlinks", "--no-checkout", "--quiet",
            str(upstream), str(patched))
        run("git", "-C", str(patched), "checkout", "--detach", "--quiet",
            source_lock["projectClash"]["commit"])
        apply_patches(patched, source_lock)

        output.mkdir(parents=True)
        copy_materials(output, upstream, patched, source_lock)
        module_cache = (
            arguments.module_cache.expanduser().absolute()
            if arguments.module_cache else work / "module-cache"
        )
        stage_module_sources(
            third_party_lock, output / "source/third_party/go-modules", go, module_cache,
        )
        verify_embedded_sources(third_party_lock, output / "source/ProjectClash")
        generate_bindings(patched, output, go, gobind, module_cache, source_lock)

        manifests = output / "manifests"
        manifests.mkdir(parents=True)
        shutil.copy2(SOURCE_LOCK_PATH, manifests / SOURCE_LOCK_PATH.name)
        shutil.copy2(THIRD_PARTY_LOCK_PATH, manifests / THIRD_PARTY_LOCK_PATH.name)
        upstream_digest = write_tree_manifest(upstream, manifests / "upstream-source-tree.txt")
        patched_digest = write_tree_manifest(
            output / "source/ProjectClash", manifests / "patched-source-tree.txt"
        )
        if upstream_digest != source_lock["sourceTree"]["upstreamDigest"]:
            raise PreparationError("written upstream manifest digest drifted")
        if patched_digest != source_lock["sourceTree"]["patchedDigest"]:
            raise PreparationError("written patched manifest digest drifted")
        preparation = {
            "schemaVersion": 1,
            "projectClashCommit": source_lock["projectClash"]["commit"],
            "patchedSourceDigest": patched_digest,
            "moduleGraphCount": third_party_lock["moduleGraphCount"],
            "runtimeDependencyCount": third_party_lock["runtimeDependencyCount"],
            "generatedBindings": "gomobile/gobind v0.1.13",
            "deviceSDKBinarySHA256": source_lock["sdk"]["deviceBinarySHA256"],
            "simulatorSDKBinarySHA256": source_lock["sdk"]["simulatorBinarySHA256"],
            "finalSourceZipGenerated": False,
        }
        (manifests / "preparation.json").write_text(
            json.dumps(preparation, indent=2, sort_keys=True) + "\n"
        )
        staging_digest = write_tree_manifest(output, manifests / "staging-tree.txt")
        print(json.dumps({
            "output": str(output),
            "patchedSourceDigest": patched_digest,
            "stagingDigest": staging_digest,
            "moduleGraphCount": third_party_lock["moduleGraphCount"],
        }, sort_keys=True))
    except Exception:
        if output.exists():
            shutil.rmtree(output)
        raise
    finally:
        if work.exists():
            shutil.rmtree(work)


if __name__ == "__main__":
    try:
        main()
    except (OSError, PreparationError, json.JSONDecodeError) as error:
        print(f"corresponding-source preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
