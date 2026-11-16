#!/bin/sh
set -euo pipefail

: "${SRCROOT:?Missing SRCROOT}"
: "${TARGET_BUILD_DIR:?Missing TARGET_BUILD_DIR}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Missing UNLOCALIZED_RESOURCES_FOLDER_PATH}"
: "${BRAND_LOCAL_LOGO_RESOURCE:?Missing BRAND_LOCAL_LOGO_RESOURCE}"
: "${BRAND_SOURCE_IMAGE_PATH:?Missing BRAND_SOURCE_IMAGE_PATH}"

# Public builds use the tracked AppIcon source as their local logo fallback.
source_logo="${BRAND_SOURCE_IMAGE_PATH}"
resources_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
destination_logo="${resources_directory}/${BRAND_LOCAL_LOGO_RESOURCE}.png"

if [ ! -e "${source_logo}" ]; then
    echo "error: Brand source image is missing" >&2
    exit 1
fi

if [ -L "${source_logo}" ]; then
    echo "error: Brand source image must not be a symbolic link" >&2
    exit 1
fi

if [ ! -f "${source_logo}" ] || [ ! -r "${source_logo}" ]; then
    echo "error: Brand source image must be a readable regular file" >&2
    exit 1
fi

PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "${source_logo}" <<'PY'
import pathlib
import struct
import sys
import zlib

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
signature = b"\x89PNG\r\n\x1a\n"
if not data.startswith(signature):
    raise SystemExit("error: Brand source image is not a valid PNG")

offset = len(signature)
chunks = []
dimensions = None
while offset < len(data):
    if offset + 12 > len(data):
        raise SystemExit("error: Brand source PNG has a truncated chunk")
    length = struct.unpack(">I", data[offset:offset + 4])[0]
    chunk_type = data[offset + 4:offset + 8]
    chunk_end = offset + 12 + length
    if chunk_end > len(data):
        raise SystemExit("error: Brand source PNG has an invalid chunk length")
    payload = data[offset + 8:offset + 8 + length]
    expected_crc = struct.unpack(">I", data[offset + 8 + length:chunk_end])[0]
    if zlib.crc32(chunk_type + payload) & 0xFFFFFFFF != expected_crc:
        raise SystemExit("error: Brand source PNG has an invalid CRC")
    chunks.append(chunk_type)
    if chunk_type == b"IHDR":
        if length != 13 or dimensions is not None:
            raise SystemExit("error: Brand source PNG has an invalid IHDR")
        dimensions = struct.unpack(">II", payload[:8])
    offset = chunk_end
    if chunk_type == b"IEND":
        break

if not chunks or chunks[0] != b"IHDR" or chunks[-1] != b"IEND" or offset != len(data):
    raise SystemExit("error: Brand source image is not a complete PNG")
if dimensions != (1024, 1024):
    raise SystemExit("error: Brand source image must be exactly 1024x1024")
PY

/bin/mkdir -p "${resources_directory}"

if [ -f "${destination_logo}" ] && /usr/bin/cmp -s "${source_logo}" "${destination_logo}"; then
    exit 0
fi

temporary_logo="${destination_logo}.tmp.$$"
trap '/bin/rm -f "${temporary_logo}"' EXIT
/bin/cp "${source_logo}" "${temporary_logo}"

if ! /usr/bin/cmp -s "${source_logo}" "${temporary_logo}"; then
    echo "error: Generated BrandLocalLogo does not match its brand source" >&2
    exit 1
fi

/bin/mv -f "${temporary_logo}" "${destination_logo}"
trap - EXIT

if [ ! -f "${destination_logo}" ] || ! /usr/bin/cmp -s "${source_logo}" "${destination_logo}"; then
    echo "error: BrandLocalLogo generation failed" >&2
    exit 1
fi

echo "Generated bundled ${BRAND_LOCAL_LOGO_RESOURCE}.png from the selected brand source."
