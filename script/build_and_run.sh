#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="NUP Studio"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A single stable build tree, outside project sources and deliverables.
BUILD_DIR="${NUP_BUILD_DIR:-$ROOT_DIR/../../builds/NUPStudio}"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2; exit 2 ;;
esac
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcodebuild -project "$ROOT_DIR/NUPStudio.xcodeproj" -scheme NUPStudio \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" build
case "$MODE" in
  --build-only) exit 0 ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  *)
    /usr/bin/open -n "$APP_BUNDLE"
    case "$MODE" in
      --verify|verify) sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
      --logs|logs) /usr/bin/log stream --info --style compact --predicate 'process == "NUP Studio"' ;;
      --telemetry|telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "de.local.nupstudio"' ;;
    esac
    ;;
esac
