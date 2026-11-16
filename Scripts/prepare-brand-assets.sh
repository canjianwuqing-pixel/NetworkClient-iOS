#!/bin/sh
set -euo pipefail

: "${SRCROOT:?Missing SRCROOT}"
: "${DERIVED_FILE_DIR:?Missing DERIVED_FILE_DIR}"
: "${BUILD_FLAVOR:?Missing BUILD_FLAVOR}"
: "${BRAND_APP_ICON:?Missing BRAND_APP_ICON}"
: "${BRAND_SOURCE_IMAGE_PATH:?Missing BRAND_SOURCE_IMAGE_PATH}"

generated_catalog="${DERIVED_FILE_DIR}/GeneratedBrandAssets.xcassets"
temporary_catalog="${generated_catalog}.tmp.$$"

case "${generated_catalog}" in
    "${DERIVED_FILE_DIR}/GeneratedBrandAssets.xcassets") ;;
    *) echo "error: Invalid generated brand asset path" >&2; exit 1 ;;
esac

trap '/bin/rm -rf "${temporary_catalog}"' EXIT
/bin/rm -rf "${temporary_catalog}"
/bin/mkdir -p "${temporary_catalog}"

/bin/cat > "${temporary_catalog}/Contents.json" <<'JSON'
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON

if [ "${BUILD_FLAVOR}" != "Public" ] || [ "${BRAND_APP_ICON}" != "AppIcon" ]; then
    echo "error: Public builds must use BUILD_FLAVOR=Public and the AppIcon asset" >&2
    exit 1
fi

/bin/sh "${SRCROOT}/Scripts/generate-brand-local-logo.sh"

/bin/rm -rf "${generated_catalog}"
/bin/mv "${temporary_catalog}" "${generated_catalog}"
trap - EXIT

if [ ! -f "${generated_catalog}/Contents.json" ]; then
    echo "error: Generated brand asset catalog preparation failed" >&2
    exit 1
fi

echo "Prepared ${BUILD_FLAVOR} brand assets using ${BRAND_APP_ICON}."
