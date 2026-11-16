# GPL corresponding-source preparation

This directory locks the preferred-form source inputs for the ProjectClash SDK
integration. The public snapshot omits the compiled SDK. These records do not
authorize a binary release and do not contain a final corresponding-source archive.

The authoritative inputs are:

- `SOURCE_LOCK.json`: upstream, patches, toolchain, source-tree and SDK hashes.
- `THIRD_PARTY_SOURCE_LOCK.json`: the complete Go module graph and source locks.
- `MODIFICATIONS.md`: prominent local modification notices.
- `RELEASE_SOURCE_LAYOUT.md`: the staging and future release layout.

Run `Scripts/GPL/prepare-corresponding-source.py` with the pinned Go toolchain
and `gobind` v0.1.13. The tool clones only the fixed official ProjectClash
repository, verifies every lock before applying a patch, downloads exact Go
module source archives through the HTTPS Go module proxy with checksum database
verification, and writes a deterministic staging tree outside the repository.

The prepared tree includes the full patched ProjectClash source, complete
external Go module sources, original license files, patch files, build scripts,
SDK provenance and generated Objective-C/Go binding source. It deliberately
does not include GeoData approval or a final release ZIP.

Only the current `SDK_BUILD15_ROUTE_VALIDATION_MANIFEST.json` is copied into
staging. The historical `SDK_BUILD_MANIFEST.json` remains in `Vendor/Mihomo/`
for repository provenance but is intentionally excluded because it records a
local signing environment rather than a source-reconstruction requirement.
