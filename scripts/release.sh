#!/bin/zsh
# Navi release pipeline:
#   xcodegen → Release build (bundles the browser runtime) → Developer ID deep sign
#   → notarize + staple → DMG → notarize + staple the DMG → appcast.json (ed25519-signed)
#
# Usage: scripts/release.sh [--dry-run] [--universal] [--skip-notarize] [--notes <file>]
#   --dry-run        no Developer ID or notary profile needed: signs ad-hoc (or with what the
#                    keychain has), skips notarization/stapling, still produces the DMG + appcast
#   --universal      also bundle the x86_64 Python tree (Intel Macs)
#   --skip-notarize  sign with Developer ID but do not submit (for a quick local check)
#   --notes <file>   release notes (plain text) for appcast.json
#
# Environment:
#   NAVI_SIGN_IDENTITY   codesign identity (default "Developer ID Application")
#   NAVI_NOTARY_PROFILE  notarytool keychain profile (default "navi"; docs/RELEASE.md)
#   NAVI_UPDATE_KEY      ed25519 PEM that signs appcast.json (default ~/.config/navi-release/update-key.pem)
#   NAVI_DOWNLOAD_BASE   where the DMG will be hosted (default https://navi.app/downloads)
#
# Output: build/release/Navi-<version>.dmg, build/release/appcast.json, build/release/Navi.app
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0; UNIVERSAL=0; NOTARIZE=1; NOTES=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --universal) UNIVERSAL=1; shift ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    --notes) NOTES="$2"; shift 2 ;;
    -h|--help) sed -n 2,20p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

IDENTITY="${NAVI_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NAVI_NOTARY_PROFILE:-navi}"
BASE="${NAVI_DOWNLOAD_BASE:-https://navi.app/downloads}"
DD="build/DerivedData-release"
OUT="build/release"
say() { echo "▸ $*"; }

have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR | grep -q "\"$1"; }
if [[ "$IDENTITY" != "-" ]] && ! have_identity "$IDENTITY"; then
  if (( DRY )); then
    say "No \"$IDENTITY\" identity in the keychain — dry run signs ad-hoc (-). Gatekeeper will reject this build on other Macs."
    IDENTITY="-"
  else
    echo "No \"$IDENTITY\" identity in the keychain. One-time setup is in docs/RELEASE.md, or use --dry-run." >&2
    exit 1
  fi
fi
if (( DRY )); then NOTARIZE=0; fi
if (( NOTARIZE )) && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "notarytool profile \"$PROFILE\" is missing or invalid: xcrun notarytool store-credentials $PROFILE (docs/RELEASE.md)" >&2
  exit 1
fi

# --- 1. Build ------------------------------------------------------------------------------
say "Release build (identity: $IDENTITY)"
export NAVI_SIGN_IDENTITY="$IDENTITY"
(( UNIVERSAL )) && export NAVI_UNIVERSAL=1
scripts/build.sh Release "$DD"
APP_SRC="$DD/Build/Products/Release/Navi.app"
[[ -d "$APP_SRC" ]] || { echo "Build product missing: $APP_SRC" >&2; exit 1; }
if [[ ! -x "$APP_SRC/Contents/Resources/browser-runtime/python-arm64/bin/python3.12" ]]; then
  say "Runtime missing from the build product — bundling now"
  scripts/bundle-runtime.sh --into "$APP_SRC" $( (( UNIVERSAL )) && echo --universal )
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_SRC/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo 26.0)"
rm -rf "$OUT"; mkdir -p "$OUT"
APP="$OUT/Navi.app"
ditto "$APP_SRC" "$APP"
say "Navi $VERSION ($BUILD) staged in $APP"

# --- 2. Sign, inside-out --------------------------------------------------------------------
TS=(--timestamp); [[ "$IDENTITY" == "-" ]] && TS=(--timestamp=none)
say "Signing every Mach-O in the browser runtime"
n=0
find "$APP/Contents/Resources/browser-runtime" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 \
  | while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q 'Mach-O'; then
        codesign --force --sign "$IDENTITY" --options runtime "${TS[@]}" "$f" 2>&1 | grep -v 'replacing existing signature' || true
      fi
    done
say "Signing Navi.app (hardened runtime, Navi/Navi.entitlements)"
codesign --force --sign "$IDENTITY" --options runtime "${TS[@]}" --entitlements Navi/Navi.entitlements "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -2
if [[ "$IDENTITY" != "-" ]]; then
  codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier" | head -2
fi

# --- 3. Notarize + staple the app -----------------------------------------------------------
if (( NOTARIZE )); then
  ZIP="$OUT/Navi-$VERSION-notarize.zip"
  say "Notarizing the app (profile: $PROFILE)"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1
else
  say "Skipping notarization$( (( DRY )) && echo ' (dry run)' )"
fi

# --- 4. DMG ---------------------------------------------------------------------------------
DMG="$OUT/Navi-$VERSION.dmg"
say "Building $DMG"
scripts/make-dmg.sh "$APP" "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" "${TS[@]}" "$DMG"
fi
if (( NOTARIZE )); then
  say "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# --- 5. Appcast -----------------------------------------------------------------------------
say "Writing $OUT/appcast.json"
scripts/gen-appcast.sh --dmg "$DMG" --version "$VERSION" --build "$BUILD" --url "$BASE/Navi-$VERSION.dmg" \
  --min-os "$MIN_OS" ${NOTES:+--notes "$NOTES"} -o "$OUT/appcast.json"

echo
echo "Release $VERSION ($BUILD)$( (( DRY )) && echo ' — DRY RUN, not shippable')"
echo "  app      $APP"
echo "  dmg      $DMG  ($(du -h "$DMG" | awk '{print $1}'))"
echo "  appcast  $OUT/appcast.json"
if (( ! DRY )); then
  echo
  echo "Next: upload Navi-$VERSION.dmg + appcast.json to $BASE/ (see docs/RELEASE.md), then verify:"
  echo "  curl -s $(dirname "$BASE")/appcast.json | python3 -m json.tool"
fi
