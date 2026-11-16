# Mihomo integration source and provenance

The public snapshot intentionally omits the prebuilt `Clash.xcframework`. This directory retains integration patches, build manifests, license texts, third-party notices, and reproducibility material only.

The recorded upstream is ProjectClash/Clash tag `v1.19.33-clash.2`, commit `34d0a954c50a9233bc216e3cb73a016397fdad5b`. The source changes are applied in the order recorded by `SDK_BUILD15_ROUTE_VALIDATION_MANIFEST.json`.

To prepare a local SDK for authorized development, use a pinned local clone and an output directory outside this repository:

```sh
python3 Scripts/build-mihomo-sdk.py \
  --source <pinned-local-clone> \
  --output-root <external-output-directory> \
  --go-bin-dir <go-bin-directory> \
  --gomobile-bin-dir <gomobile-bin-directory>
```

The build script validates the pinned revision and patch hashes. Supplying or linking a locally built SDK into Xcode remains the user's responsibility; the public Xcode project does not reference an SDK binary.

Mihomo and its dependencies remain subject to their actual licenses. The retained license bundle, notices, patches, and compliance records do not by themselves authorize redistribution of a compiled framework. Review `Compliance/GPL/` before any binary distribution.
