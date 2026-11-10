#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${SHIYING_BUILD_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 Scripts/manage_build_apps.py run ./Scripts/build.sh "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SHIYING_MODE="${1:-Debug}"
if (( $# > 0 )); then shift; fi
if [[ "$SHIYING_MODE" == test ]]; then exec ./Scripts/test.sh "$@"; fi
trap 'python3 Scripts/manage_build_apps.py cleanup' EXIT
case "$SHIYING_MODE" in
  Debug)
    xcodebuild -project Shiying.xcodeproj -scheme Shiying -configuration Debug build "$@"
    ;;
  Release)
    xcodebuild -project Shiying.xcodeproj -scheme Shiying -configuration Release -derivedDataPath build/.ReleaseData.noindex build "$@"
    python3 Scripts/manage_build_apps.py install build/.ReleaseData.noindex/Build/Products/Release/Shiying.app
    python3 Scripts/package_release.py
    ;;
  *) print -u2 'Usage: Scripts/build.sh [Debug|Release|test] [xcodebuild settings]'; exit 2 ;;
esac
