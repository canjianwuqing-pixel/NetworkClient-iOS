#!/usr/bin/env python3
"""Fast, offline tests for the locked GeoData build tool."""

import copy
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-geodata.py")
SPEC = importlib.util.spec_from_file_location("networkclient_build_geodata", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GeoDataBuildToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = MODULE.load_lock()

    def test_checked_in_lock_schema_is_valid_and_fixed(self):
        MODULE.validate_lock(copy.deepcopy(self.lock))
        self.assertEqual(self.lock["schemaVersion"], 1)
        self.assertEqual(self.lock["geosite"]["commit"], "777d056afe68b2643c1ef15f80e7bde3dfa149b1")
        self.assertEqual(self.lock["cnMRS"]["generatorCommit"], "34d0a954c50a9233bc216e3cb73a016397fdad5b")
        self.assertEqual(self.lock["geoip"]["sourceVersion"], "2026-11")

    def test_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="geodata-test-") as directory:
            path = Path(directory) / "payload"
            path.write_bytes(b"unexpected")
            with self.assertRaises(MODULE.AuditError):
                MODULE.verify_sha256(path, "0" * 64, "fixture")

    def test_non_https_url_is_rejected(self):
        with self.assertRaises(MODULE.AuditError):
            MODULE.validate_https_url("http://download.db-ip.com/file", self.lock["allowedHosts"], "fixture")

    def test_non_allowlisted_host_is_rejected(self):
        with self.assertRaises(MODULE.AuditError):
            MODULE.validate_https_url("https://example.invalid/file", self.lock["allowedHosts"], "fixture")

    def test_allowlisted_but_non_official_source_is_rejected(self):
        bad = copy.deepcopy(self.lock)
        bad["geoip"]["officialURL"] = (
            "https://go.dev/dl/dbip-country-lite-2026-11.mmdb.gz"
        )
        with self.assertRaisesRegex(MODULE.AuditError, "official DB-IP"):
            MODULE.validate_lock(bad)

    def test_moving_refs_are_rejected(self):
        bad = copy.deepcopy(self.lock)
        bad["cnMRS"]["generatorTag"] = "latest"
        with self.assertRaises(MODULE.AuditError):
            MODULE.validate_lock(bad)

    def test_dbip_runtime_metadata_report_is_validated(self):
        report = {
            "databaseType": "DBIP-Country-Lite",
            "nodeCount": 10,
            "countryFieldReadable": True,
            "directCNCode": "cn",
            "directNonCNCode": "us",
            "coreReaderCNMatch": True,
            "coreReaderNonCNMatch": False,
            "geoIPRuleCNMatch": True,
            "geoIPRuleNonCNMatch": False,
            "rawGeoSiteCNMatch": True,
            "rawGeoSiteNonCNMatch": False,
            "rawGeoSiteCount": 1,
            "compiledGeoSiteCNMatch": True,
            "compiledGeoSiteNonCNMatch": False,
            "compiledGeoSiteCount": 1,
        }
        MODULE.validate_runtime_report(report, self.lock)
        report["databaseType"] = "unexpected"
        with self.assertRaises(MODULE.AuditError):
            MODULE.validate_runtime_report(report, self.lock)

    def test_gzip_decompression_and_rename_preserve_payload_bytes(self):
        payload = b"fixed-mmdb-fixture" * 128
        with tempfile.TemporaryDirectory(prefix="geodata-test-") as directory:
            root = Path(directory)
            archive = root / "country.mmdb.gz"
            with gzip.GzipFile(filename=str(archive), mode="wb", mtime=0) as handle:
                handle.write(payload)
            spec = {
                "archiveSHA256": MODULE.sha256_file(archive),
                "payloadSHA256": hashlib.sha256(payload).hexdigest(),
                "maximumPayloadBytes": 1024 * 1024,
            }
            output = root / "geoip.metadb"
            result = MODULE.stage_geoip(archive, output, spec)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(result["payloadSHA256"], hashlib.sha256(payload).hexdigest())

    def test_candidate_manifest_can_never_approve_redistribution(self):
        geoip = {"archiveSHA256": "1" * 64, "payloadSHA256": "2" * 64, "size": 1}
        geosite = {"firstSHA256": "3" * 64, "secondSHA256": "3" * 64, "size": 1, "bitForBitEqual": True}
        mrs = {"firstSHA256": "4" * 64, "secondSHA256": "4" * 64, "size": 1, "bitForBitEqual": True}
        manifest = MODULE.create_candidate_manifest(self.lock, "1.26.10", geoip, geosite, mrs)
        self.assertIs(manifest["approval"]["redistributionApproved"], False)
        self.assertEqual(manifest["artifacts"]["cn.mrs"]["inputGeositeSHA256"], "3" * 64)

    def test_work_or_output_cannot_target_the_project_or_shipping_data(self):
        with self.assertRaises(MODULE.AuditError):
            MODULE.resolved_external_path(MODULE.PROJECT_ROOT / "temporary-output", "output")
        with self.assertRaises(MODULE.AuditError):
            MODULE.resolved_external_path(MODULE.SHIPPING_GEODATA, "output")

    def test_manifest_rejects_a_cn_mrs_from_another_geosite(self):
        with tempfile.TemporaryDirectory(prefix="geodata-test-") as directory:
            output = Path(directory)
            payloads = {
                "geoip.metadb": b"geoip",
                "geosite.dat": b"geosite",
                "cn.mrs": b"mrs",
            }
            for name, payload in payloads.items():
                (output / name).write_bytes(payload)
            manifest = {
                "approval": {"redistributionApproved": False},
                "artifacts": {
                    name: {"outputSHA256": hashlib.sha256(payload).hexdigest()}
                    for name, payload in payloads.items()
                },
            }
            manifest["artifacts"]["geoip.metadb"]["outputSHA256"] = self.lock["geoip"]["payloadSHA256"]
            (output / "geoip.metadb").write_bytes(b"not-the-locked-large-fixture")
            manifest["artifacts"]["geoip.metadb"]["outputSHA256"] = MODULE.sha256_file(output / "geoip.metadb")
            manifest["artifacts"]["cn.mrs"]["inputGeositeSHA256"] = "0" * 64
            manifest["artifacts"]["geosite.dat"]["outputSHA256"] = MODULE.sha256_file(output / "geosite.dat")
            original_payload = self.lock["geoip"]["payloadSHA256"]
            altered_lock = copy.deepcopy(self.lock)
            altered_lock["geoip"]["payloadSHA256"] = manifest["artifacts"]["geoip.metadb"]["outputSHA256"]
            self.assertNotEqual(original_payload, altered_lock["geoip"]["payloadSHA256"])
            with self.assertRaisesRegex(MODULE.AuditError, "same-build geosite"):
                MODULE.verify_manifest(manifest, altered_lock, output)

    def test_output_directory_must_be_separate_from_work_directory(self):
        root = Path(tempfile.gettempdir()).resolve() / "geodata-separation-test"
        with self.assertRaises(MODULE.AuditError):
            MODULE.validate_directories(root, root / "output")

    def test_candidate_provenance_v2_is_locked_and_never_approved(self):
        geosite_hash = self.lock["geosite"]["expectedAuditPOC"]["sha256"]
        mrs_hash = self.lock["cnMRS"]["expectedAuditPOC"]["sha256"]
        candidate = {
            "artifacts": {
                "geoip.metadb": {
                    "outputSize": 1,
                    "outputSHA256": self.lock["geoip"]["payloadSHA256"],
                },
                "geosite.dat": {
                    "outputSize": 2,
                    "outputSHA256": geosite_hash,
                    "reproducibility": {"bitForBitEqual": True},
                },
                "cn.mrs": {
                    "inputGeositeSHA256": geosite_hash,
                    "outputSize": 3,
                    "outputSHA256": mrs_hash,
                    "reproducibility": {"bitForBitEqual": True},
                },
            }
        }
        provenance = MODULE.candidate_provenance_v2(self.lock, candidate)
        self.assertEqual(provenance["schemaVersion"], 2)
        self.assertEqual(set(provenance["licenses"]), {"MIT", "CC-BY-4.0"})
        self.assertEqual(provenance["artifacts"]["geoip.metadb"]["outputSHA256"], self.lock["geoip"]["payloadSHA256"])
        self.assertIs(provenance["approval"]["redistributionApproved"], False)
        self.assertIsNone(provenance["approval"]["reviewedAt"])
        self.assertIsNone(provenance["approval"]["reviewer"])
        self.assertIsNone(provenance["approval"]["reviewReference"])

    def test_checked_in_compliance_materials_exist_and_are_not_xcode_resources(self):
        compliance = MODULE.COMPLIANCE_DIR
        for name in MODULE.COMPLIANCE_FILES:
            self.assertTrue((compliance / name).is_file(), name)
        project_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in MODULE.PROJECT_ROOT.glob("*.xcodeproj/project.pbxproj")
        )
        self.assertNotIn("Compliance/GeoData", project_text)
        for name in MODULE.COMPLIANCE_FILES:
            self.assertNotIn(Path(name).name, project_text)

    def test_shipping_data_matches_formal_candidate_and_release_gate_remains(self):
        expected = {
            "geoip.metadb": "145ce5dfb812d8de28547e6289bb5c5f8b3df2f1dea21d324d5b575e0431311f",
            "geosite.dat": "02ad51927d05608b672bbcdf37f37b94ce1fdb7dcd10852f367ed457ad56280b",
            "cn.mrs": "ffb5b4311029519a52066711a75a38a5f27d9aa6357778342429babe21cff92c",
            "PROVENANCE.json": "d2d7225543c65a4fecb4379b06a0fc7a93cd080389eb6efec97ebb5004d73e05",
        }
        for name, digest in expected.items():
            self.assertEqual(MODULE.sha256_file(MODULE.SHIPPING_GEODATA / name), digest)
        provenance = json.loads(
            (MODULE.SHIPPING_GEODATA / "PROVENANCE.json").read_text(encoding="utf-8")
        )
        self.assertEqual(provenance["schema"], 1)
        self.assertEqual(provenance["schemaVersion"], 2)
        self.assertEqual(provenance["candidateFiles"], {
            name: digest for name, digest in expected.items() if name != "PROVENANCE.json"
        })
        self.assertEqual(
            provenance["artifacts"]["geoip.metadb"]["databaseType"],
            "DBIP-Country-Lite",
        )
        self.assertIs(provenance["redistributionApproved"], False)
        self.assertIs(provenance["approval"]["redistributionApproved"], False)
        self.assertIsNone(provenance["approval"]["reviewedAt"])
        self.assertIsNone(provenance["approval"]["reviewer"])
        self.assertIsNone(provenance["approval"]["reviewReference"])
        provider = (MODULE.PROJECT_ROOT / "NetworkPacketTunnel/PacketTunnelProvider.swift").read_text(encoding="utf-8")
        self.assertIn('#error("Build 15 GeoData redistribution provenance is not approved")', provider)


if __name__ == "__main__":
    unittest.main()
