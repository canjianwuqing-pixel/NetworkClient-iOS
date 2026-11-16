#!/bin/sh
set -eu

fixtures='Resources/BrandFixtures/BrandA.json
Resources/BrandFixtures/BrandB.json
Resources/BrandFixtures/LogoA.png
Resources/BrandFixtures/LogoB.png
Resources/BrandFixtures/Profiles.json
Resources/BrandFixtures/ThemeA.json
Resources/BrandFixtures/ThemeB.json
Resources/UIFixture.json'

destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

case "${CONFIGURATION:-}" in
    Debug|Debug-Public)
        expected_fixture_setting=YES
        ;;
    Release|Release-Public)
        expected_fixture_setting=NO
        ;;
    *)
        echo "error: unsupported configuration for test fixtures" >&2
        exit 1
        ;;
esac

if [ "${INCLUDE_TEST_FIXTURES:-}" != "$expected_fixture_setting" ]; then
    echo "error: INCLUDE_TEST_FIXTURES does not match the active configuration" >&2
    exit 1
fi

case "$expected_fixture_setting" in
    YES)
        mkdir -p "$destination"
        printf '%s\n' "$fixtures" | while IFS= read -r relative_path; do
            source_path="${SRCROOT}/${relative_path}"
            fixture_name=$(basename "$relative_path")
            if [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
                echo "error: invalid test fixture source: ${relative_path}" >&2
                exit 1
            fi
            /usr/bin/install -m 0644 "$source_path" "${destination}/${fixture_name}"
        done
        ;;
    NO)
        printf '%s\n' "$fixtures" | while IFS= read -r relative_path; do
            fixture_name=$(basename "$relative_path")
            if [ -e "${destination}/${fixture_name}" ] || [ -L "${destination}/${fixture_name}" ]; then
                echo "error: Release bundle contains test fixture: ${fixture_name}" >&2
                exit 1
            fi
        done
        ;;
esac
