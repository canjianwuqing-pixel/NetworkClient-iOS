# GeoData Candidate Compliance Materials

This directory documents a reproducible candidate replacement chain for the
GeoData files used by NetworkClient.

## Status

- The public snapshot omits the runtime GeoData database files.
- The files described here are candidate outputs only and are not release-approved.
- `PROVENANCE.candidate.json` records fixed sources, hashes, licenses, and
  reproducibility evidence for the candidate outputs.
- Successful generation, verification, and presence of license materials do
  not grant release approval.
- A human distribution and legal review is still required before replacing
  the shipping files.
- `redistributionApproved` must remain `false` until that review is
  completed.
- The Packet Tunnel redistribution gate must remain active until an authorized
  review approves a lawful source and distribution process.

## Fixed candidate chain

- `geoip.metadb`: DB-IP Country Lite 2026-11, distributed under
  CC-BY-4.0. The official MMDB gzip payload is decompressed without modifying
  the database contents and renamed for application compatibility.
- `geosite.dat`: generated from V2Fly/domain-list-community at commit
  `777d056afe68b2643c1ef15f80e7bde3dfa149b1`, under the MIT License.
- `cn.mrs`: compiled from the `cn` category of that same candidate
  `geosite.dat` using ProjectClash/Clash tag `v1.19.33-clash.2`, commit
  `34d0a954c50a9233bc216e3cb73a016397fdad5b`.

Candidate binary files are generated outside the repository and are not stored
in this directory.

## Independent blocker

The Mihomo / ProjectClash XCFramework distribution and GPLv3 obligations are
an independent Release blocker. These candidate GeoData materials do not
resolve, waive, or approve that SDK distribution issue.

## Verification

After generating candidates into an external output directory:

```sh
python3 Scripts/GeoData/build-geodata.py verify-compliance \
  --output-dir <external-output-directory> \
  --compliance-dir Compliance/GeoData
```

This verifies the candidate output hashes, lock-to-provenance consistency,
license-text hashes, attribution material, approval state, and that these
files are not referenced by the Xcode project.
