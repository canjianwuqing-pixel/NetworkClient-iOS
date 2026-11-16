# Corresponding-source staging layout

`prepare-corresponding-source.py` writes the following non-release staging
tree. Directory names do not contain local usernames or absolute paths.

```text
output/
├── source/
│   ├── NetworkClient/README.txt
│   ├── ProjectClash/                 complete patched preferred-form source
│   └── third_party/go-modules/       complete pinned external module sources
├── patches/                          four original NetworkClient patches
├── licenses/
│   ├── ProjectClash/
│   ├── PacketFlowBridge/
│   └── go-modules/                   reviewed license bundle
├── build/
│   ├── ProjectClash-upstream.bundle   offline reconstruction of pinned Git metadata
│   ├── generated-bindings/           generated Objective-C/Go bridge source
│   ├── Scripts/                       SDK rebuild and verification tools
│   └── VendorMetadata/                authoritative build provenance
└── manifests/
    ├── upstream-source-tree.txt
    ├── patched-source-tree.txt
    ├── staging-tree.txt
    └── preparation.json
```

The final `NetworkClient-iOS-<version>-<build>-source.zip` is intentionally not
created in this batch. A later batch must add the release-matched NetworkClient
tree, final license decision, version/build mapping and approved GeoData source
materials before packaging.
