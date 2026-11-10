#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${SHIYING_BUILD_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 Scripts/manage_build_apps.py run ./Scripts/test.sh "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
trap 'python3 Scripts/manage_build_apps.py cleanup' EXIT
xcodebuild -project Shiying.xcodeproj -scheme Shiying -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/.TestData.noindex test "$@"
