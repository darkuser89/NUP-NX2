#!/usr/bin/env bash
set -euo pipefail

# Distribution builds run on GitHub, never through the local Run action.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "Dieses Skript ist ausschließlich für GitHub Actions vorgesehen." >&2
  exit 1
fi
: "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_RUN_NUMBER:?}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$RUNNER_TEMP/NUPStudio"
DIST_DIR="$RUNNER_TEMP/NUPStudio-distribution"
APP_BUNDLE="$BUILD_DIR/Build/Products/Release/NUP Studio.app"
VERSION_ARGS=("CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER")
ZIP_NAME="NUP-Studio-macOS-arm64.zip"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  if [[ ! "${GITHUB_REF_NAME:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release-Tags müssen dem Format v1.0.0 entsprechen." >&2
    exit 1
  fi
  VERSION_ARGS+=("MARKETING_VERSION=${GITHUB_REF_NAME#v}")
  ZIP_NAME="NUP-Studio-${GITHUB_REF_NAME}-macOS-arm64.zip"
fi
cd "$ROOT_DIR"
[[ "$(uname -m)" == "arm64" ]]
xcodebuild -version
xcodebuild -project NUPStudio.xcodeproj -scheme NUPStudio \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" -resultBundlePath "$RUNNER_TEMP/NUPStudio-tests.xcresult" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
  test 2>&1 | tee "$RUNNER_TEMP/NUPStudio-test.log"

xcodebuild -project NUPStudio.xcodeproj -scheme NUPStudio \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  ENABLE_DEBUG_DYLIB=NO \
  "${VERSION_ARGS[@]}" build 2>&1 | tee "$RUNNER_TEMP/NUPStudio-build.log"

[[ -d "$APP_BUNDLE" ]]
[[ "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/NUP Studio")" == "arm64" ]]
codesign --verify --deep --strict "$APP_BUNDLE"
[[ ! -d "$APP_BUNDLE/Contents/PlugIns/NUPStudioTests.xctest" ]]
mkdir -p "$DIST_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"
cd "$DIST_DIR"
shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
printf 'distribution=%s\n' "$DIST_DIR" >> "$GITHUB_OUTPUT"
