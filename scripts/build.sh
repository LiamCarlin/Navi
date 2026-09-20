#!/bin/zsh
# Build Navi. Usage: scripts/build.sh [Debug|Release] [derived-data-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
DD="${2:-build/DerivedData}"
mkdir -p "$DD"
xcodegen generate --quiet
xcodebuild -project Navi.xcodeproj -scheme Navi -configuration "$CONFIG" \
  -derivedDataPath "$DD" -destination 'platform=macOS' \
    build 2>&1 | tee "$DD.build.log" | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)|\*\* " || true
grep -q "BUILD SUCCEEDED" "$DD.build.log"
echo "App: $DD/Build/Products/$CONFIG/Navi.app"
