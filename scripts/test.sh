#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${1:-build/DerivedData}"
mkdir -p "$DD"
xcodegen generate --quiet
xcodebuild -project Navi.xcodeproj -scheme Navi -derivedDataPath "$DD" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO test 2>&1 | tee "$DD.test.log" | grep -E "error:|Test Suite|passed|failed|\*\* " || true
grep -q "TEST SUCCEEDED" "$DD.test.log"
