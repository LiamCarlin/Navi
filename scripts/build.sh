#!/bin/zsh
# Build Navi. Usage: scripts/build.sh [Debug|Release] [derived-data-dir]
#
# Release is configured (project.yml) to sign with "Developer ID Application" and the
# hardened runtime, and to bundle the browser runtime (scripts/bundle-runtime.sh).
# When that certificate is not in the keychain — most dev Macs — the identity is
# downgraded here so `scripts/install.sh` keeps working: Apple Development if present,
# else ad-hoc. Override with NAVI_SIGN_IDENTITY. Real releases go through scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
DD="${2:-build/DerivedData}"
mkdir -p "$DD"
xcodegen generate --quiet

EXTRA=()
if [[ "$CONFIG" == "Release" ]]; then
  WANT="${NAVI_SIGN_IDENTITY:-Developer ID Application}"
  IDS="$(security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR || true)"
  if [[ "$WANT" == "-" ]]; then
    EXTRA+=("CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=")
  elif echo "$IDS" | grep -q "\"$WANT"; then
    EXTRA+=("CODE_SIGN_IDENTITY=$WANT")
  elif echo "$IDS" | grep -q '"Apple Development'; then
    echo "▸ No \"$WANT\" identity in the keychain — signing Release with Apple Development (local use only; see docs/RELEASE.md)"
    EXTRA+=("CODE_SIGN_IDENTITY=Apple Development")
  else
    echo "▸ No signing identity in the keychain — ad-hoc signing Release (local use only)"
    EXTRA+=("CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=")
  fi
fi

xcodebuild -project Navi.xcodeproj -scheme Navi -configuration "$CONFIG" \
  -derivedDataPath "$DD" -destination 'platform=macOS' "${EXTRA[@]}" \
    build 2>&1 | tee "$DD.build.log" | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)|\*\* " || true
grep -q "BUILD SUCCEEDED" "$DD.build.log"
echo "App: $DD/Build/Products/$CONFIG/Navi.app"
