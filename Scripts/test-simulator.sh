#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NETWORKCLIENT_SIMULATOR_ID:?Set NETWORKCLIENT_SIMULATOR_ID to an available iPhone simulator UUID}"
mkdir -p .build
xcodebuild -project NetworkClient-iOS.xcodeproj -scheme NetworkClient-iOS \
  -configuration Debug -destination "platform=iOS Simulator,id=$NETWORKCLIENT_SIMULATOR_ID,arch=arm64" \
  -derivedDataPath .build/Xcode -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO test
