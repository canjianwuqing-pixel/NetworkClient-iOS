#!/usr/bin/env python3
"""Build auditable GeoData candidates outside the iOS project.

The tool never writes to NetworkPacketTunnel/GeoData. It accepts only the
fixed sources in sources.lock.json, verifies every downloaded payload, builds
GeoSite and CN MRS twice, and leaves redistribution approval false.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Dict, Iterable, Optional, Sequence
import urllib.parse
import urllib.request


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_LOCK = SCRIPT_DIR / "sources.lock.json"
SHIPPING_GEODATA = PROJECT_ROOT / "NetworkPacketTunnel/GeoData"
OUTPUT_NAMES = {
    "geoip.metadb",
    "geosite.dat",
    "cn.mrs",
    "candidate-provenance.json",
}
COMPLIANCE_DIR = PROJECT_ROOT / "Compliance/GeoData"
COMPLIANCE_FILES = {
    "README.md",
    "PROVENANCE.candidate.json",
    "THIRD_PARTY_NOTICES.txt",
    "LICENSES/v2fly-domain-list-community-MIT.txt",
    "LICENSES/DB-IP-Lite-CC-BY-4.0.txt",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
HELPER_MARKER = "GEODATA_AUDIT_JSON="
OFFICIAL_SOURCE_URLS = {
    "geosite": "https://github.com/v2fly/domain-list-community.git",
    "cnMRS": "https://github.com/ProjectClash/Clash.git",
}


class AuditError(RuntimeError):
    """A fail-closed validation error."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def resolved_external_path(path: Path, label: str) -> Path:
    resolved = path.expanduser().resolve()
    project = PROJECT_ROOT.resolve()
    if resolved == project or is_within(resolved, project):
        raise AuditError(f"{label} must be outside the iOS project: {resolved}")
    if resolved == SHIPPING_GEODATA.resolve() or is_within(resolved, SHIPPING_GEODATA.resolve()):
        raise AuditError(f"{label} must never target shipping GeoData: {resolved}")
    return resolved


def validate_https_url(url: str, allowed_hosts: Iterable[str], label: str) -> urllib.parse.ParseResult:
    parsed = urllib.parse.urlparse(url)
    allowed = set(allowed_hosts)
    if parsed.scheme != "https":
        raise AuditError(f"{label} must use HTTPS")
    if not parsed.hostname or parsed.hostname not in allowed:
        raise AuditError(f"{label} host is not allowlisted: {parsed.hostname!r}")
    if parsed.username or parsed.password or parsed.port not in (None, 443):
        raise AuditError(f"{label} contains forbidden credentials or port")
    if parsed.fragment:
        raise AuditError(f"{label} must not contain a fragment")
    return parsed


def require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise AuditError(f"{label} is not a lowercase SHA-256")
    return value


def reject_moving_ref(value: str, label: str) -> None:
    lowered = value.lower()
    if lowered in {"latest", "master", "main", "head"}:
        raise AuditError(f"{label} is a moving ref: {value}")
    pieces = [piece for piece in re.split(r"[/?:=&]+", lowered) if piece]
    if any(piece in {"latest", "master", "main"} for piece in pieces):
        raise AuditError(f"{label} contains a moving ref: {value}")


def load_lock(path: Path = DEFAULT_LOCK) -> Dict[str, Any]:
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError(f"cannot read source lock: {error}") from error
    validate_lock(lock)
    return lock


def validate_lock(lock: Dict[str, Any]) -> None:
    if lock.get("schemaVersion") != 1:
        raise AuditError("source lock schemaVersion must be 1")
    hosts = lock.get("allowedHosts")
    if not isinstance(hosts, list) or not hosts or any(not isinstance(host, str) for host in hosts):
        raise AuditError("allowedHosts must be a non-empty string array")
    if len(set(hosts)) != len(hosts):
        raise AuditError("allowedHosts contains duplicates")

    geosite = lock.get("geosite", {})
    validate_https_url(geosite.get("repoURL", ""), hosts, "geosite.repoURL")
    if geosite.get("repoURL") != OFFICIAL_SOURCE_URLS["geosite"]:
        raise AuditError("geosite.repoURL must be the official V2Fly repository")
    if not COMMIT_RE.fullmatch(str(geosite.get("commit", ""))):
        raise AuditError("geosite.commit must be a fixed 40-character commit")
    reject_moving_ref(geosite["commit"], "geosite.commit")
    if geosite.get("license") != "MIT":
        raise AuditError("geosite license must remain MIT")
    license_url = validate_https_url(geosite.get("licenseURL", ""), hosts, "geosite.licenseURL")
    if geosite["commit"] not in license_url.path:
        raise AuditError("geosite license URL must be fixed to the source commit")
    require_sha256(geosite.get("licenseTextSHA256"), "geosite license text hash")
    require_sha256(geosite.get("expectedAuditPOC", {}).get("sha256"), "geosite audit POC hash")

    cn_mrs = lock.get("cnMRS", {})
    validate_https_url(cn_mrs.get("generatorRepo", ""), hosts, "cnMRS.generatorRepo")
    if cn_mrs.get("generatorRepo") != OFFICIAL_SOURCE_URLS["cnMRS"]:
        raise AuditError("cnMRS.generatorRepo must be the official ProjectClash repository")
    commit = str(cn_mrs.get("generatorCommit", ""))
    if not COMMIT_RE.fullmatch(commit):
        raise AuditError("cnMRS.generatorCommit must be fixed")
    reject_moving_ref(str(cn_mrs.get("generatorTag", "")), "cnMRS.generatorTag")
    if cn_mrs.get("category") != "cn" or cn_mrs.get("input") != "same-build:geosite.dat":
        raise AuditError("cn.mrs must come from category cn of the same-build geosite.dat")
    if cn_mrs.get("licenseOfGenerator") != "GPL-3.0-only":
        raise AuditError("ProjectClash generator license must remain GPL-3.0-only")
    generator_license_url = validate_https_url(
        cn_mrs.get("licenseURL", ""), hosts, "cnMRS.licenseURL"
    )
    if commit not in generator_license_url.path:
        raise AuditError("ProjectClash license URL must be fixed to the generator commit")
    require_sha256(cn_mrs.get("expectedAuditPOC", {}).get("sha256"), "cn.mrs audit POC hash")

    geoip = lock.get("geoip", {})
    parsed = validate_https_url(geoip.get("officialURL", ""), hosts, "geoip.officialURL")
    if parsed.hostname != "download.db-ip.com":
        raise AuditError("geoip.officialURL must use the official DB-IP download host")
    version = str(geoip.get("sourceVersion", ""))
    if not re.fullmatch(r"20[0-9]{2}-(0[1-9]|1[0-2])", version):
        raise AuditError("geoip.sourceVersion must be a fixed YYYY-MM")
    filename = geoip.get("archiveFilename")
    if not isinstance(filename, str) or Path(parsed.path).name != filename or version not in filename:
        raise AuditError("DB-IP URL must point to the locked monthly archive filename")
    require_sha256(geoip.get("archiveSHA256"), "geoip archive hash")
    require_sha256(geoip.get("payloadSHA256"), "geoip payload hash")
    if geoip.get("databaseType") != "DBIP-Country-Lite":
        raise AuditError("DB-IP database type must be DBIP-Country-Lite")
    if geoip.get("license") != "CC-BY-4.0":
        raise AuditError("DB-IP license must remain CC-BY-4.0")
    validate_https_url(geoip.get("licenseURL", ""), hosts, "geoip.licenseURL")
    license_text_url = validate_https_url(
        geoip.get("licenseTextURL", ""), hosts, "geoip.licenseTextURL"
    )
    if license_text_url.hostname != "creativecommons.org":
        raise AuditError("DB-IP license text must use the official Creative Commons host")
    require_sha256(geoip.get("licenseTextSHA256"), "DB-IP license text hash")
    dataset_url = validate_https_url(geoip.get("datasetURL", ""), hosts, "geoip.datasetURL")
    attribution_url = validate_https_url(
        geoip.get("attributionURL", ""), hosts, "geoip.attributionURL"
    )
    if dataset_url.hostname != "db-ip.com" or attribution_url.hostname != "db-ip.com":
        raise AuditError("DB-IP dataset and attribution URLs must use db-ip.com")
    for key in ("cn", "nonCN"):
        sample = geoip.get("validationSamples", {}).get(key, {})
        try:
            ipaddress.ip_address(sample.get("ip", ""))
        except ValueError as error:
            raise AuditError(f"invalid {key} validation IP") from error

    toolchain = lock.get("toolchain", {})
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(toolchain.get("goVersion", ""))):
        raise AuditError("toolchain.goVersion must be exact")
    validate_https_url(toolchain.get("goProxy", ""), hosts, "toolchain.goProxy")
    go_archive = validate_https_url(
        toolchain.get("darwinArm64ArchiveURL", ""),
        hosts,
        "toolchain.darwinArm64ArchiveURL",
    )
    expected_go_archive = f"go{toolchain['goVersion']}.darwin-arm64.tar.gz"
    if go_archive.hostname != "go.dev" or Path(go_archive.path).name != expected_go_archive:
        raise AuditError("Go archive URL must be the locked official Darwin arm64 archive")
    if toolchain.get("projectClashCommit") != commit:
        raise AuditError("toolchain and cnMRS ProjectClash commits differ")
    require_sha256(toolchain.get("darwinArm64ArchiveSHA256"), "Go archive hash")


def verify_sha256(path: Path, expected: str, label: str) -> str:
    actual = sha256_file(path)
    if actual != expected:
        raise AuditError(f"{label} SHA-256 mismatch: got {actual}, want {expected}")
    return actual


def run_command(
    args: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
    capture: bool = False,
) -> str:
    print("+", shlex.join([str(arg) for arg in args]), flush=True)
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=str(cwd) if cwd else None,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    return result.stdout.strip() if capture and result.stdout else ""


def directory_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for entry in path.rglob("*"):
        if entry.is_file() and not entry.is_symlink():
            total += entry.stat().st_size
    return total


def report_work_size(work_dir: Path) -> None:
    size = directory_size(work_dir)
    print(f"Work directory size: {size} bytes ({size / (1024 ** 2):.1f} MiB)", file=sys.stderr)


def git_output(repo: Path, *args: str) -> str:
    return run_command(("git", "-C", str(repo), *args), capture=True)


def verify_git_source(repo: Path, url: str, commit: str, tag: Optional[str] = None) -> None:
    if not (repo / ".git").is_dir():
        raise AuditError(f"missing Git source: {repo}")
    if git_output(repo, "rev-parse", "HEAD") != commit:
        raise AuditError(f"wrong source commit in {repo}")
    if git_output(repo, "remote", "get-url", "origin") != url:
        raise AuditError(f"wrong source origin in {repo}")
    if git_output(repo, "status", "--porcelain"):
        raise AuditError(f"source clone was modified: {repo}")
    if tag and git_output(repo, "rev-list", "-n", "1", tag) != commit:
        raise AuditError(f"tag {tag} does not resolve to locked commit")


def fetch_git_source(repo: Path, url: str, commit: str, tag: Optional[str] = None) -> None:
    if repo.exists():
        verify_git_source(repo, url, commit, tag)
        return
    repo.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    run_command(("git", "init", "--quiet", str(repo)), env=env)
    run_command(("git", "-C", str(repo), "remote", "add", "origin", url), env=env)
    if tag:
        run_command(("git", "-C", str(repo), "fetch", "--depth=1", "origin", f"refs/tags/{tag}:refs/tags/{tag}"), env=env)
    else:
        run_command(("git", "-C", str(repo), "fetch", "--depth=1", "origin", commit), env=env)
    run_command(("git", "-C", str(repo), "checkout", "--detach", "--quiet", commit), env=env)
    verify_git_source(repo, url, commit, tag)


class AllowlistedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed_hosts: Iterable[str]) -> None:
        super().__init__()
        self.allowed_hosts = set(allowed_hosts)

    def redirect_request(self, request: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> Any:
        validate_https_url(newurl, self.allowed_hosts, "redirect URL")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def safe_download(url: str, destination: Path, expected_hash: str, allowed_hosts: Iterable[str], maximum_bytes: int) -> None:
    validate_https_url(url, allowed_hosts, "download URL")
    if destination.exists():
        verify_sha256(destination, expected_hash, destination.name)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    opener = urllib.request.build_opener(AllowlistedRedirectHandler(allowed_hosts))
    request = urllib.request.Request(url, headers={"User-Agent": "NetworkClient-GeoData-Audit/1"})
    temporary: Optional[Path] = None
    try:
        with opener.open(request, timeout=45) as response:
            validate_https_url(response.geturl(), allowed_hosts, "final download URL")
            length = response.headers.get("Content-Length")
            if length and int(length) > maximum_bytes:
                raise AuditError("download is larger than the locked maximum")
            with tempfile.NamedTemporaryFile(prefix=destination.name + ".", suffix=".part", dir=destination.parent, delete=False) as handle:
                temporary = Path(handle.name)
                total = 0
                digest = hashlib.sha256()
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > maximum_bytes:
                        raise AuditError("download exceeded the locked maximum")
                    digest.update(chunk)
                    handle.write(chunk)
        if digest.hexdigest() != expected_hash:
            raise AuditError(f"download SHA-256 mismatch: got {digest.hexdigest()}, want {expected_hash}")
        os.replace(str(temporary), str(destination))
        temporary = None
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def fetch_sources(lock: Dict[str, Any], work_dir: Path) -> Dict[str, Path]:
    sources = work_dir / "sources"
    downloads = work_dir / "downloads"
    v2fly = sources / "domain-list-community"
    project_clash = sources / "ProjectClash-Clash"
    fetch_git_source(v2fly, lock["geosite"]["repoURL"], lock["geosite"]["commit"])
    fetch_git_source(
        project_clash,
        lock["cnMRS"]["generatorRepo"],
        lock["cnMRS"]["generatorCommit"],
        lock["cnMRS"]["generatorTag"],
    )
    archive = downloads / lock["geoip"]["archiveFilename"]
    safe_download(
        lock["geoip"]["officialURL"],
        archive,
        lock["geoip"]["archiveSHA256"],
        lock["allowedHosts"],
        int(lock["geoip"]["maximumDownloadBytes"]),
    )
    return {"v2fly": v2fly, "projectClash": project_clash, "geoipArchive": archive}


def go_environment(lock: Dict[str, Any], work_dir: Path) -> Dict[str, str]:
    cache = work_dir / "cache"
    for path in (cache / "go-build", cache / "go-mod", cache / "gopath"):
        path.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(
        {
            "GOCACHE": str(cache / "go-build"),
            "GOMODCACHE": str(cache / "go-mod"),
            "GOPATH": str(cache / "gopath"),
            "GOPROXY": lock["toolchain"]["goProxy"],
            "GOSUMDB": lock["toolchain"]["goSumDB"],
            "GOTOOLCHAIN": "local",
            "GOENV": "off",
        }
    )
    return env


def verify_go(go_bin: Path, expected: str) -> str:
    if not go_bin.is_file():
        raise AuditError(f"Go executable does not exist: {go_bin}")
    output = run_command((str(go_bin), "version"), capture=True)
    match = re.search(r"\bgo([0-9]+\.[0-9]+\.[0-9]+)\b", output)
    if not match or match.group(1) != expected:
        raise AuditError(f"Go version mismatch: got {output!r}, want go{expected}")
    return match.group(1)


def stage_geoip(archive: Path, output: Path, spec: Dict[str, Any]) -> Dict[str, Any]:
    archive_hash = verify_sha256(archive, spec["archiveSHA256"], "DB-IP archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(prefix="geoip.", suffix=".metadb.part", dir=output.parent, delete=False) as raw:
            temporary = Path(raw.name)
            total = 0
            digest = hashlib.sha256()
            with gzip.open(archive, "rb") as compressed:
                while True:
                    chunk = compressed.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > int(spec["maximumPayloadBytes"]):
                        raise AuditError("DB-IP payload exceeded the 64 MiB ceiling")
                    digest.update(chunk)
                    raw.write(chunk)
        payload_hash = digest.hexdigest()
        if payload_hash != spec["payloadSHA256"]:
            raise AuditError(f"DB-IP payload SHA-256 mismatch: got {payload_hash}, want {spec['payloadSHA256']}")
        os.replace(str(temporary), str(output))
        temporary = None
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    if sha256_file(output) != spec["payloadSHA256"]:
        raise AuditError("renaming the DB-IP payload changed its bytes")
    return {"archiveSHA256": archive_hash, "payloadSHA256": spec["payloadSHA256"], "size": output.stat().st_size}


GO_HELPER = r'''package main

import (
    "encoding/json"
    "fmt"
    "net"
    "net/netip"
    "os"
    "path/filepath"
    "strings"

    "github.com/ProjectClash/Clash/component/geodata"
    "github.com/ProjectClash/Clash/component/geodata/compiled"
    _ "github.com/ProjectClash/Clash/component/geodata/memconservative"
    "github.com/ProjectClash/Clash/component/mmdb"
    C "github.com/ProjectClash/Clash/constant"
    RC "github.com/ProjectClash/Clash/rules/common"
    "github.com/oschwald/maxminddb-golang"
)

const marker = "GEODATA_AUDIT_JSON="

func emit(value any) {
    payload, err := json.Marshal(value)
    if err != nil { panic(err) }
    fmt.Println(marker + string(payload))
}

func fail(err error) {
    fmt.Fprintln(os.Stderr, err)
    os.Exit(1)
}

func compileCN(home string) {
    C.SetHomeDir(home)
    geodata.SetLoader("memconservative")
    if err := geodata.CompileGeoSite("cn"); err != nil { fail(err) }
    path, err := compiled.Path(geodata.CompiledGeoSiteDir(), "cn")
    if err != nil { fail(err) }
    count, err := compiled.EntryCount(geodata.CompiledGeoSiteDir(), "cn")
    if err != nil || count <= 0 {
        if err == nil { err = fmt.Errorf("compiled cn.mrs is empty") }
        fail(err)
    }
    emit(map[string]any{"path": path, "count": count})
}

type countryRecord struct {
    Country struct { ISOCode string `maxminddb:"iso_code"` } `maxminddb:"country"`
}

func hasCode(codes []string, wanted string) bool {
    for _, code := range codes {
        if strings.EqualFold(code, wanted) { return true }
    }
    return false
}

func verifyCandidates(home, cnIPText, nonCNIPText, cnDomain, nonCNDomain string) {
    C.SetHomeDir(home)
    mmdbPath := filepath.Join(home, "geoip.metadb")
    data, err := os.ReadFile(mmdbPath)
    if err != nil { fail(err) }
    reader, err := maxminddb.FromBytes(data)
    if err != nil { fail(err) }
    defer reader.Close()
    if reader.Metadata.NodeCount == 0 { fail(fmt.Errorf("MMDB node count is zero")) }
    cnIP := net.ParseIP(cnIPText)
    nonCNIP := net.ParseIP(nonCNIPText)
    if cnIP == nil || nonCNIP == nil { fail(fmt.Errorf("invalid validation IP")) }
    var cnRecord, nonCNRecord countryRecord
    if err := reader.Lookup(cnIP, &cnRecord); err != nil { fail(err) }
    if err := reader.Lookup(nonCNIP, &nonCNRecord); err != nil { fail(err) }
    if cnRecord.Country.ISOCode == "" || nonCNRecord.Country.ISOCode == "" {
        fail(fmt.Errorf("country.iso_code is unreadable for a validation sample"))
    }

    mmdb.LoadFromBytes(data)
    cnCodes := mmdb.IPInstance().LookupCode(cnIP)
    nonCNCodes := mmdb.IPInstance().LookupCode(nonCNIP)
    geodata.SetGeodataMode(false)
    geoRule, err := RC.NewGEOIP("cn", "DIRECT", false, true)
    if err != nil { fail(err) }
    geoCN := geoRule.MatchIp(netip.MustParseAddr(cnIPText))
    geoNonCN := geoRule.MatchIp(netip.MustParseAddr(nonCNIPText))

    geodata.SetLoader("memconservative")
    geodata.SetCompiledGeoSiteOnly(false)
    geodata.ClearGeoSiteCache()
    rawRule, err := RC.NewGEOSITE("cn", "DIRECT")
    if err != nil { fail(err) }
    rawCN := rawRule.MatchDomain(cnDomain)
    rawNonCN := rawRule.MatchDomain(nonCNDomain)
    rawCount := rawRule.GetRecodeSize()

    geodata.SetCompiledGeoSiteOnly(true)
    geodata.ClearGeoSiteCache()
    compiledRule, err := RC.NewGEOSITE("cn", "DIRECT")
    if err != nil { fail(err) }
    compiledCN := compiledRule.MatchDomain(cnDomain)
    compiledNonCN := compiledRule.MatchDomain(nonCNDomain)
    compiledCount := compiledRule.GetRecodeSize()

    emit(map[string]any{
        "databaseType": reader.Metadata.DatabaseType,
        "nodeCount": reader.Metadata.NodeCount,
        "countryFieldReadable": true,
        "directCNCode": strings.ToLower(cnRecord.Country.ISOCode),
        "directNonCNCode": strings.ToLower(nonCNRecord.Country.ISOCode),
        "coreReaderCNCodes": cnCodes,
        "coreReaderNonCNCodes": nonCNCodes,
        "coreReaderCNMatch": hasCode(cnCodes, "cn"),
        "coreReaderNonCNMatch": hasCode(nonCNCodes, "cn"),
        "geoIPRuleCNMatch": geoCN,
        "geoIPRuleNonCNMatch": geoNonCN,
        "rawGeoSiteCNMatch": rawCN,
        "rawGeoSiteNonCNMatch": rawNonCN,
        "rawGeoSiteCount": rawCount,
        "compiledGeoSiteCNMatch": compiledCN,
        "compiledGeoSiteNonCNMatch": compiledNonCN,
        "compiledGeoSiteCount": compiledCount,
    })
}

func main() {
    if len(os.Args) < 2 { fail(fmt.Errorf("missing command")) }
    switch os.Args[1] {
    case "compile-cn":
        if len(os.Args) != 3 { fail(fmt.Errorf("compile-cn requires a Mihomo home")) }
        compileCN(os.Args[2])
    case "verify-candidates":
        if len(os.Args) != 7 { fail(fmt.Errorf("verify-candidates requires home, two IPs and two domains")) }
        verifyCandidates(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
    default:
        fail(fmt.Errorf("unknown command %q", os.Args[1]))
    }
}
'''


def helper_report(helper: Path, args: Sequence[str]) -> Dict[str, Any]:
    output = run_command((str(helper), *args), capture=True)
    for line in reversed(output.splitlines()):
        if line.startswith(HELPER_MARKER):
            try:
                return json.loads(line[len(HELPER_MARKER):])
            except json.JSONDecodeError as error:
                raise AuditError("Mihomo helper returned invalid JSON") from error
    raise AuditError(f"Mihomo helper returned no audit report: {output}")


def build_helper(
    go_bin: Path,
    project_clash: Path,
    work_dir: Path,
    env: Dict[str, str],
    go_version: str,
) -> Path:
    helper_dir = work_dir / "tools" / "mihomo-geodata-helper-source"
    helper_dir.mkdir(parents=True, exist_ok=True)
    escaped_path = json.dumps(str(project_clash))
    go_mod = (
        "module networkclient.local/geodata-helper\n\n"
        f"go {go_version}\n\n"
        "require github.com/ProjectClash/Clash v0.0.0\n\n"
        f"replace github.com/ProjectClash/Clash => {escaped_path}\n"
    )
    (helper_dir / "go.mod").write_text(go_mod, encoding="utf-8")
    (helper_dir / "main.go").write_text(GO_HELPER, encoding="utf-8")
    tidy_env = env.copy()
    tidy_env["GOFLAGS"] = "-buildvcs=false"
    run_command((str(go_bin), "mod", "tidy"), cwd=helper_dir, env=tidy_env)
    helper = work_dir / "tools" / "mihomo-geodata-helper"
    build_env = env.copy()
    build_env["GOFLAGS"] = "-mod=readonly -buildvcs=false"
    run_command((str(go_bin), "build", "-trimpath", "-o", str(helper), "."), cwd=helper_dir, env=build_env)
    return helper


def build_geosite_once(go_bin: Path, source: Path, destination: Path, env: Dict[str, str]) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    build_env = env.copy()
    build_env["GOFLAGS"] = "-mod=readonly -buildvcs=false"
    run_command(
        (str(go_bin), "run", "./", f"--outputdir={destination}", "--outputname=geosite.dat"),
        cwd=source,
        env=build_env,
    )
    result = destination / "geosite.dat"
    if not result.is_file():
        raise AuditError("V2Fly did not produce geosite.dat")
    return result


def compare_reproducible(first: Path, second: Path, label: str) -> Dict[str, Any]:
    first_hash = sha256_file(first)
    second_hash = sha256_file(second)
    if first_hash != second_hash or first.read_bytes() != second.read_bytes():
        raise AuditError(f"{label} is not bit-for-bit reproducible: {first_hash} != {second_hash}")
    return {
        "firstSHA256": first_hash,
        "secondSHA256": second_hash,
        "size": first.stat().st_size,
        "bitForBitEqual": True,
    }


def atomic_json(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile(prefix=path.name + ".", suffix=".part", dir=path.parent, mode="w", encoding="utf-8", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    os.replace(str(temporary), str(path))


def create_candidate_manifest(
    lock: Dict[str, Any],
    go_version: str,
    geoip_result: Dict[str, Any],
    geosite_result: Dict[str, Any],
    mrs_result: Dict[str, Any],
) -> Dict[str, Any]:
    geosite_hash = geosite_result["firstSHA256"]
    return {
        "schemaVersion": 1,
        "artifacts": {
            "geoip.metadb": {
                "sourceName": lock["geoip"]["sourceName"],
                "sourceURL": lock["geoip"]["officialURL"],
                "sourceVersion": lock["geoip"]["sourceVersion"],
                "archiveSHA256": geoip_result["archiveSHA256"],
                "payloadSHA256": geoip_result["payloadSHA256"],
                "outputSHA256": geoip_result["payloadSHA256"],
                "outputSize": geoip_result["size"],
                "databaseType": lock["geoip"]["databaseType"],
                "license": lock["geoip"]["license"],
                "licenseURL": lock["geoip"]["licenseURL"],
                "transformation": lock["geoip"]["transformation"],
            },
            "geosite.dat": {
                "sourceRepo": lock["geosite"]["repoURL"],
                "sourceCommit": lock["geosite"]["commit"],
                "license": lock["geosite"]["license"],
                "licenseURL": lock["geosite"]["licenseURL"],
                "goVersion": go_version,
                "generatorCommand": lock["geosite"]["generatorCommand"],
                "outputSHA256": geosite_hash,
                "outputSize": geosite_result["size"],
                "reproducibility": geosite_result,
                "matchesAuditPOC": geosite_hash == lock["geosite"]["expectedAuditPOC"]["sha256"],
            },
            "cn.mrs": {
                "inputGeositeSHA256": geosite_hash,
                "generatorRepo": lock["cnMRS"]["generatorRepo"],
                "generatorTag": lock["cnMRS"]["generatorTag"],
                "generatorCommit": lock["cnMRS"]["generatorCommit"],
                "generatorFunction": lock["cnMRS"]["generatorFunction"],
                "category": lock["cnMRS"]["category"],
                "licenseOfGenerator": lock["cnMRS"]["licenseOfGenerator"],
                "licenseURL": lock["cnMRS"]["licenseURL"],
                "outputSHA256": mrs_result["firstSHA256"],
                "outputSize": mrs_result["size"],
                "reproducibility": mrs_result,
                "matchesAuditPOC": mrs_result["firstSHA256"] == lock["cnMRS"]["expectedAuditPOC"]["sha256"],
            },
        },
        "verification": {"completed": False},
        "approval": {
            "redistributionApproved": False,
            "reviewedAt": None,
            "reviewReference": None,
        },
    }


def require_empty_output(output_dir: Path) -> None:
    if output_dir.exists() and any(output_dir.iterdir()):
        raise AuditError(f"output directory must be empty before build: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)


def build_candidates(lock: Dict[str, Any], work_dir: Path, output_dir: Path, go_bin: Path) -> Dict[str, Any]:
    require_empty_output(output_dir)
    paths = {
        "v2fly": work_dir / "sources/domain-list-community",
        "projectClash": work_dir / "sources/ProjectClash-Clash",
        "geoipArchive": work_dir / "downloads" / lock["geoip"]["archiveFilename"],
    }
    verify_git_source(paths["v2fly"], lock["geosite"]["repoURL"], lock["geosite"]["commit"])
    verify_git_source(
        paths["projectClash"],
        lock["cnMRS"]["generatorRepo"],
        lock["cnMRS"]["generatorCommit"],
        lock["cnMRS"]["generatorTag"],
    )
    verify_sha256(paths["geoipArchive"], lock["geoip"]["archiveSHA256"], "DB-IP archive")
    go_version = verify_go(go_bin, lock["toolchain"]["goVersion"])
    env = go_environment(lock, work_dir)
    run_command((str(go_bin), "mod", "download"), cwd=paths["v2fly"], env={**env, "GOFLAGS": "-mod=readonly -buildvcs=false"})

    build_parent = work_dir / "builds"
    build_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="candidate-", dir=build_parent) as temporary_name:
        stage = Path(temporary_name)
        first_geosite = build_geosite_once(go_bin, paths["v2fly"], stage / "geosite-one", env)
        second_geosite = build_geosite_once(go_bin, paths["v2fly"], stage / "geosite-two", env)
        geosite_result = compare_reproducible(first_geosite, second_geosite, "geosite.dat")
        shutil.copyfile(first_geosite, output_dir / "geosite.dat")

        helper = build_helper(go_bin, paths["projectClash"], work_dir, env, go_version)
        mrs_files = []
        for name in ("mrs-one", "mrs-two"):
            home = stage / name
            home.mkdir()
            shutil.copyfile(first_geosite, home / "geosite.dat")
            report = helper_report(helper, ("compile-cn", str(home)))
            if int(report.get("count", 0)) <= 0:
                raise AuditError("Mihomo compiled an empty cn.mrs")
            mrs_files.append(Path(report["path"]))
        mrs_result = compare_reproducible(mrs_files[0], mrs_files[1], "cn.mrs")
        shutil.copyfile(mrs_files[0], output_dir / "cn.mrs")

    geoip_result = stage_geoip(paths["geoipArchive"], output_dir / "geoip.metadb", lock["geoip"])
    manifest = create_candidate_manifest(lock, go_version, geoip_result, geosite_result, mrs_result)
    atomic_json(output_dir / "candidate-provenance.json", manifest)
    verify_git_source(paths["v2fly"], lock["geosite"]["repoURL"], lock["geosite"]["commit"])
    verify_git_source(
        paths["projectClash"],
        lock["cnMRS"]["generatorRepo"],
        lock["cnMRS"]["generatorCommit"],
        lock["cnMRS"]["generatorTag"],
    )
    return manifest


def validate_runtime_report(report: Dict[str, Any], lock: Dict[str, Any]) -> None:
    if report.get("databaseType") != lock["geoip"]["databaseType"]:
        raise AuditError(f"wrong MMDB database type: {report.get('databaseType')!r}")
    if int(report.get("nodeCount", 0)) <= 0 or report.get("countryFieldReadable") is not True:
        raise AuditError("MMDB metadata or country.iso_code is invalid")
    if report.get("directCNCode") != lock["geoip"]["validationSamples"]["cn"]["expectedCode"]:
        raise AuditError("direct MMDB CN sample returned the wrong code")
    if report.get("directNonCNCode") == lock["geoip"]["validationSamples"]["nonCN"]["forbiddenCode"]:
        raise AuditError("direct MMDB non-CN sample unexpectedly returned CN")
    required_true = (
        "coreReaderCNMatch",
        "geoIPRuleCNMatch",
        "rawGeoSiteCNMatch",
        "compiledGeoSiteCNMatch",
    )
    required_false = (
        "coreReaderNonCNMatch",
        "geoIPRuleNonCNMatch",
        "rawGeoSiteNonCNMatch",
        "compiledGeoSiteNonCNMatch",
    )
    if any(report.get(key) is not True for key in required_true):
        raise AuditError("a required Mihomo CN semantic match failed")
    if any(report.get(key) is not False for key in required_false):
        raise AuditError("a non-CN Mihomo semantic sample matched CN")
    if int(report.get("rawGeoSiteCount", 0)) <= 0 or int(report.get("compiledGeoSiteCount", 0)) <= 0:
        raise AuditError("Mihomo reported an empty GEOSITE,cn matcher")


def verify_manifest(manifest: Dict[str, Any], lock: Dict[str, Any], output_dir: Path) -> None:
    if manifest.get("approval", {}).get("redistributionApproved") is not False:
        raise AuditError("candidate manifest must never approve redistribution")
    artifacts = manifest.get("artifacts", {})
    for filename in ("geoip.metadb", "geosite.dat", "cn.mrs"):
        expected = artifacts.get(filename, {}).get("outputSHA256")
        require_sha256(expected, f"candidate {filename} hash")
        verify_sha256(output_dir / filename, expected, filename)
    if artifacts["geoip.metadb"]["outputSHA256"] != lock["geoip"]["payloadSHA256"]:
        raise AuditError("candidate geoip.metadb is not the locked DB-IP payload")
    if artifacts["cn.mrs"].get("inputGeositeSHA256") != artifacts["geosite.dat"]["outputSHA256"]:
        raise AuditError("cn.mrs is not bound to the same-build geosite.dat")


def load_verified_candidate_manifest(lock: Dict[str, Any], output_dir: Path) -> Dict[str, Any]:
    actual_names = {entry.name for entry in output_dir.iterdir()}
    if actual_names != OUTPUT_NAMES:
        raise AuditError(f"unexpected candidate output set: {sorted(actual_names)}")
    manifest = json.loads((output_dir / "candidate-provenance.json").read_text(encoding="utf-8"))
    verify_manifest(manifest, lock, output_dir)
    if manifest.get("verification", {}).get("completed") is not True:
        raise AuditError("candidate runtime verification is incomplete")

    artifacts = manifest["artifacts"]
    geoip = artifacts["geoip.metadb"]
    geosite = artifacts["geosite.dat"]
    cn_mrs = artifacts["cn.mrs"]
    expected_values = (
        (geoip.get("sourceURL"), lock["geoip"]["officialURL"], "geoip source URL"),
        (geoip.get("sourceVersion"), lock["geoip"]["sourceVersion"], "geoip source version"),
        (geoip.get("archiveSHA256"), lock["geoip"]["archiveSHA256"], "geoip archive hash"),
        (geoip.get("payloadSHA256"), lock["geoip"]["payloadSHA256"], "geoip payload hash"),
        (geoip.get("databaseType"), lock["geoip"]["databaseType"], "geoip database type"),
        (geoip.get("license"), lock["geoip"]["license"], "geoip license"),
        (geosite.get("sourceRepo"), lock["geosite"]["repoURL"], "geosite source repo"),
        (geosite.get("sourceCommit"), lock["geosite"]["commit"], "geosite source commit"),
        (geosite.get("license"), lock["geosite"]["license"], "geosite license"),
        (geosite.get("goVersion"), lock["toolchain"]["goVersion"], "geosite Go version"),
        (cn_mrs.get("inputGeositeSHA256"), geosite.get("outputSHA256"), "cn.mrs input hash"),
        (cn_mrs.get("generatorRepo"), lock["cnMRS"]["generatorRepo"], "cn.mrs generator repo"),
        (cn_mrs.get("generatorTag"), lock["cnMRS"]["generatorTag"], "cn.mrs generator tag"),
        (cn_mrs.get("generatorCommit"), lock["cnMRS"]["generatorCommit"], "cn.mrs generator commit"),
        (cn_mrs.get("category"), lock["cnMRS"]["category"], "cn.mrs category"),
        (cn_mrs.get("licenseOfGenerator"), lock["cnMRS"]["licenseOfGenerator"], "cn.mrs generator license"),
    )
    for actual, expected, label in expected_values:
        if actual != expected:
            raise AuditError(f"candidate {label} differs from sources.lock.json")
    for filename, artifact in artifacts.items():
        if artifact.get("outputSize") != (output_dir / filename).stat().st_size:
            raise AuditError(f"candidate {filename} size differs from its manifest")
    for artifact_name in ("geosite.dat", "cn.mrs"):
        artifact = artifacts[artifact_name]
        reproducibility = artifact.get("reproducibility", {})
        output_hash = artifact.get("outputSHA256")
        if (
            reproducibility.get("bitForBitEqual") is not True
            or reproducibility.get("firstSHA256") != output_hash
            or reproducibility.get("secondSHA256") != output_hash
        ):
            raise AuditError(f"candidate {artifact_name} lacks reproducibility proof")
    return manifest


def candidate_provenance_v2(lock: Dict[str, Any], candidate: Dict[str, Any]) -> Dict[str, Any]:
    artifacts = candidate["artifacts"]
    geoip = artifacts["geoip.metadb"]
    geosite = artifacts["geosite.dat"]
    cn_mrs = artifacts["cn.mrs"]
    return {
        "schemaVersion": 2,
        "artifacts": {
            "geoip.metadb": {
                "sourceName": lock["geoip"]["sourceName"],
                "officialURL": lock["geoip"]["officialURL"],
                "sourceVersion": lock["geoip"]["sourceVersion"],
                "archiveFilename": lock["geoip"]["archiveFilename"],
                "archiveSHA256": lock["geoip"]["archiveSHA256"],
                "sourcePayloadSHA256": lock["geoip"]["payloadSHA256"],
                "sourceLicense": lock["geoip"]["license"],
                "databaseType": lock["geoip"]["databaseType"],
                "transformation": lock["geoip"]["transformation"],
                "outputSize": geoip["outputSize"],
                "outputSHA256": geoip["outputSHA256"],
            },
            "geosite.dat": {
                "sourceRepo": lock["geosite"]["repoURL"],
                "sourceCommit": lock["geosite"]["commit"],
                "sourceLicense": lock["geosite"]["license"],
                "generatorCommand": lock["geosite"]["generatorCommand"],
                "goVersion": lock["toolchain"]["goVersion"],
                "outputSize": geosite["outputSize"],
                "outputSHA256": geosite["outputSHA256"],
                "reproducibilityVerified": geosite["reproducibility"]["bitForBitEqual"],
            },
            "cn.mrs": {
                "inputGeositeSHA256": cn_mrs["inputGeositeSHA256"],
                "generatorRepo": lock["cnMRS"]["generatorRepo"],
                "generatorTag": lock["cnMRS"]["generatorTag"],
                "generatorCommit": lock["cnMRS"]["generatorCommit"],
                "generatorFunction": lock["cnMRS"]["generatorFunction"],
                "generatorLicense": lock["cnMRS"]["licenseOfGenerator"],
                "generatorLicenseURL": lock["cnMRS"]["licenseURL"],
                "category": lock["cnMRS"]["category"],
                "outputSize": cn_mrs["outputSize"],
                "outputSHA256": cn_mrs["outputSHA256"],
                "reproducibilityVerified": cn_mrs["reproducibility"]["bitForBitEqual"],
            },
        },
        "licenses": {
            "MIT": {
                "appliesTo": ["geosite.dat", "cn.mrs source data"],
                "file": "LICENSES/v2fly-domain-list-community-MIT.txt",
                "sourceURL": lock["geosite"]["licenseURL"],
                "textSHA256": lock["geosite"]["licenseTextSHA256"],
            },
            "CC-BY-4.0": {
                "appliesTo": ["geoip.metadb"],
                "file": "LICENSES/DB-IP-Lite-CC-BY-4.0.txt",
                "sourceURL": lock["geoip"]["licenseTextURL"],
                "textSHA256": lock["geoip"]["licenseTextSHA256"],
            },
        },
        "approval": {
            "redistributionApproved": False,
            "reviewedAt": None,
            "reviewer": None,
            "reviewReference": None,
        },
    }


def verify_compliance_materials(
    lock: Dict[str, Any], output_dir: Path, compliance_dir: Path
) -> Dict[str, Any]:
    if compliance_dir.resolve() != COMPLIANCE_DIR.resolve():
        raise AuditError(f"compliance directory must be {COMPLIANCE_DIR}")
    missing = [name for name in sorted(COMPLIANCE_FILES) if not (compliance_dir / name).is_file()]
    if missing:
        raise AuditError(f"missing compliance materials: {missing}")
    candidate = load_verified_candidate_manifest(lock, output_dir)
    expected = candidate_provenance_v2(lock, candidate)
    provenance_path = compliance_dir / "PROVENANCE.candidate.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if provenance != expected:
        raise AuditError("PROVENANCE.candidate.json differs from lock or candidate output")
    license_paths = {
        "MIT": compliance_dir / expected["licenses"]["MIT"]["file"],
        "CC-BY-4.0": compliance_dir / expected["licenses"]["CC-BY-4.0"]["file"],
    }
    for identifier, path in license_paths.items():
        verify_sha256(path, expected["licenses"][identifier]["textSHA256"], identifier)
    readme = (compliance_dir / "README.md").read_text(encoding="utf-8")
    notices = (compliance_dir / "THIRD_PARTY_NOTICES.txt").read_text(encoding="utf-8")
    required_readme = (
        "not release-approved",
        "Release gate",
        "Mihomo / ProjectClash XCFramework",
    )
    required_notices = (
        "IP Geolocation by DB-IP",
        "CC-BY-4.0",
        lock["geosite"]["commit"],
        lock["cnMRS"]["generatorCommit"],
    )
    if any(text not in readme for text in required_readme):
        raise AuditError("README is missing a required candidate or release-blocker statement")
    if any(text not in notices for text in required_notices):
        raise AuditError("THIRD_PARTY_NOTICES is missing required attribution details")
    for project_file in PROJECT_ROOT.glob("*.xcodeproj/project.pbxproj"):
        project_text = project_file.read_text(encoding="utf-8")
        if "Compliance/GeoData" in project_text or any(
            Path(name).name in project_text for name in COMPLIANCE_FILES
        ):
            raise AuditError("compliance materials are referenced by the Xcode project")
    return {
        "schemaVersion": provenance["schemaVersion"],
        "candidateHashes": {
            name: provenance["artifacts"][name]["outputSHA256"]
            for name in ("geoip.metadb", "geosite.dat", "cn.mrs")
        },
        "licenseIdentifiers": sorted(provenance["licenses"]),
        "redistributionApproved": provenance["approval"]["redistributionApproved"],
        "xcodeResourceReferences": False,
    }


def verify_candidates(lock: Dict[str, Any], work_dir: Path, output_dir: Path, go_bin: Path) -> Dict[str, Any]:
    actual_names = {entry.name for entry in output_dir.iterdir()}
    if actual_names != OUTPUT_NAMES:
        raise AuditError(f"unexpected candidate output set: {sorted(actual_names)}")
    if any(output_dir.rglob("*.source")):
        raise AuditError("a .source sidecar reached candidate output")
    if (output_dir / "geoip.metadb").stat().st_size >= int(lock["geoip"]["maximumPayloadBytes"]):
        raise AuditError("candidate geoip.metadb is not below 64 MiB")
    manifest_path = output_dir / "candidate-provenance.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    verify_manifest(manifest, lock, output_dir)

    go_version = verify_go(go_bin, lock["toolchain"]["goVersion"])
    project_clash = work_dir / "sources/ProjectClash-Clash"
    verify_git_source(
        project_clash,
        lock["cnMRS"]["generatorRepo"],
        lock["cnMRS"]["generatorCommit"],
        lock["cnMRS"]["generatorTag"],
    )
    helper = work_dir / "tools/mihomo-geodata-helper"
    if not helper.is_file():
        helper = build_helper(
            go_bin,
            project_clash,
            work_dir,
            go_environment(lock, work_dir),
            go_version,
        )

    verify_parent = work_dir / "verify"
    verify_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="runtime-", dir=verify_parent) as home_name:
        home = Path(home_name)
        shutil.copyfile(output_dir / "geoip.metadb", home / "geoip.metadb")
        shutil.copyfile(output_dir / "geosite.dat", home / "geosite.dat")
        compiled_dir = home / "compiled-geosite"
        compiled_dir.mkdir()
        shutil.copyfile(output_dir / "cn.mrs", compiled_dir / "cn.mrs")
        report = helper_report(
            helper,
            (
                "verify-candidates",
                str(home),
                lock["geoip"]["validationSamples"]["cn"]["ip"],
                lock["geoip"]["validationSamples"]["nonCN"]["ip"],
                lock["geositeValidationSamples"]["cn"]["domain"],
                lock["geositeValidationSamples"]["nonCN"]["domain"],
            ),
        )
    validate_runtime_report(report, lock)
    manifest["verification"] = {
        "completed": True,
        "goVersion": go_version,
        "mihomoCommit": lock["cnMRS"]["generatorCommit"],
        "runtime": report,
    }
    manifest["approval"] = {
        "redistributionApproved": False,
        "reviewedAt": None,
        "reviewReference": None,
    }
    atomic_json(manifest_path, manifest)
    verify_manifest(manifest, lock, output_dir)
    return report


def validate_directories(work_dir: Path, output_dir: Optional[Path] = None) -> None:
    if output_dir is None:
        return
    if work_dir == output_dir or is_within(work_dir, output_dir) or is_within(output_dir, work_dir):
        raise AuditError("work and output directories must be separate siblings")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--lock", type=Path, default=DEFAULT_LOCK, help="source lock; defaults to the checked-in lock")
    subparsers = result.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch", help="fetch and verify fixed source inputs")
    fetch.add_argument("--work-dir", type=Path, required=True)

    for name, help_text in (
        ("build", "build candidates from already fetched sources"),
        ("verify", "verify candidate files with the pinned Mihomo reader"),
        ("all", "fetch, build twice, and verify"),
    ):
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("--work-dir", type=Path, required=True)
        command.add_argument("--output-dir", type=Path, required=True)
        command.add_argument("--go-bin", type=Path, required=True, help="path to the pinned Go executable")
    provenance = subparsers.add_parser(
        "candidate-provenance", help="print schema-v2 provenance for verified candidates"
    )
    provenance.add_argument("--output-dir", type=Path, required=True)
    compliance = subparsers.add_parser(
        "verify-compliance", help="verify checked-in compliance materials against candidates"
    )
    compliance.add_argument("--output-dir", type=Path, required=True)
    compliance.add_argument("--compliance-dir", type=Path, required=True)
    return result


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parser().parse_args(argv)
    lock = load_lock(args.lock.resolve())
    output_dir = resolved_external_path(args.output_dir, "output directory") if hasattr(args, "output_dir") else None
    if args.command in ("candidate-provenance", "verify-compliance"):
        assert output_dir is not None
        candidate = load_verified_candidate_manifest(lock, output_dir)
        if args.command == "candidate-provenance":
            print(json.dumps(candidate_provenance_v2(lock, candidate), indent=2, sort_keys=True))
            return 0
        report = verify_compliance_materials(lock, output_dir, args.compliance_dir.expanduser().resolve())
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    work_dir = resolved_external_path(args.work_dir, "work directory")
    validate_directories(work_dir, output_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    if args.command == "fetch":
        result = fetch_sources(lock, work_dir)
        print(json.dumps({key: str(value) for key, value in result.items()}, indent=2, sort_keys=True))
        report_work_size(work_dir)
        return 0

    assert output_dir is not None
    go_bin = args.go_bin.expanduser().resolve()
    if args.command == "build":
        manifest = build_candidates(lock, work_dir, output_dir, go_bin)
        print(json.dumps(manifest, indent=2, sort_keys=True))
        report_work_size(work_dir)
        return 0
    if args.command == "verify":
        report = verify_candidates(lock, work_dir, output_dir, go_bin)
        print(json.dumps(report, indent=2, sort_keys=True))
        report_work_size(work_dir)
        return 0
    fetch_sources(lock, work_dir)
    build_candidates(lock, work_dir, output_dir, go_bin)
    report = verify_candidates(lock, work_dir, output_dir, go_bin)
    print(json.dumps(report, indent=2, sort_keys=True))
    report_work_size(work_dir)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuditError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"GeoData build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
