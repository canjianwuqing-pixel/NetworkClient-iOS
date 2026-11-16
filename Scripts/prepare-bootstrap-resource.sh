#!/bin/sh
set -euo pipefail

: "${SRCROOT:?Missing SRCROOT}"
: "${TARGET_BUILD_DIR:?Missing TARGET_BUILD_DIR}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Missing UNLOCALIZED_RESOURCES_FOLDER_PATH}"
: "${BRAND_BOOTSTRAP_RESOURCE:?Missing BRAND_BOOTSTRAP_RESOURCE}"
: "${BOOTSTRAP_INPUT_PATH:?Missing BOOTSTRAP_INPUT_PATH}"

bootstrap_input="${BOOTSTRAP_INPUT_PATH}"
resources_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
bootstrap_output="${resources_directory}/${BRAND_BOOTSTRAP_RESOURCE}.json"

if [ ! -e "${bootstrap_input}" ]; then
    echo "error: Bootstrap configuration is missing: ${bootstrap_input}" >&2
    exit 1
fi

if [ -L "${bootstrap_input}" ]; then
    echo "error: Bootstrap configuration must not be a symbolic link" >&2
    exit 1
fi

if [ ! -f "${bootstrap_input}" ] || [ ! -r "${bootstrap_input}" ]; then
    echo "error: Bootstrap configuration must be a readable regular file" >&2
    exit 1
fi

PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "${bootstrap_input}" <<'PY'
import json
import pathlib
import sys
import urllib.parse

path = pathlib.Path(sys.argv[1])

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit("error: Bootstrap configuration is not valid UTF-8 JSON")

if not isinstance(payload, dict):
    raise SystemExit("error: Bootstrap configuration root must be a JSON object")

sources = payload.get("CloudConfig")
if not isinstance(sources, list) or not sources:
    raise SystemExit("error: Bootstrap CloudConfig must be a non-empty array")

for source in sources:
    if not isinstance(source, str) or not source.strip() or source != source.strip():
        raise SystemExit("error: Bootstrap CloudConfig entries must be non-empty trimmed strings")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in source):
        raise SystemExit("error: Bootstrap CloudConfig URL contains control characters")
    try:
        parsed = urllib.parse.urlsplit(source)
        _ = parsed.port
    except ValueError:
        raise SystemExit("error: Bootstrap CloudConfig URL is invalid")
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise SystemExit("error: Bootstrap CloudConfig URLs must be absolute HTTPS URLs")
    if parsed.username is not None or parsed.password is not None:
        raise SystemExit("error: Bootstrap CloudConfig URLs must not contain credentials")

update_hours = payload.get("CloudUpdateHours", 3)
if isinstance(update_hours, bool) or not isinstance(update_hours, int):
    raise SystemExit("error: Bootstrap CloudUpdateHours must be an integer")

print(f"Validated bootstrap schema with {len(sources)} source(s).")
PY

/bin/mkdir -p "${resources_directory}"

temporary_output="${bootstrap_output}.tmp.$$"
trap '/bin/rm -f "${temporary_output}"' EXIT
/bin/cp "${bootstrap_input}" "${temporary_output}"

if ! /usr/bin/cmp -s "${bootstrap_input}" "${temporary_output}"; then
    echo "error: Prepared bootstrap does not match its selected input" >&2
    exit 1
fi

/bin/mv -f "${temporary_output}" "${bootstrap_output}"
trap - EXIT

if [ ! -f "${bootstrap_output}" ] || ! /usr/bin/cmp -s "${bootstrap_input}" "${bootstrap_output}"; then
    echo "error: Bootstrap resource preparation failed" >&2
    exit 1
fi

echo "Prepared bundled ${BRAND_BOOTSTRAP_RESOURCE}.json."
