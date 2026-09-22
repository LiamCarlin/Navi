#!/bin/zsh
# Packs an app into a compressed DMG with an /Applications symlink — plain hdiutil, no
# create-dmg dependency. Usage: scripts/make-dmg.sh <Navi.app> <out.dmg> [volume-name]
set -euo pipefail
APP="$1"; DMG="$2"; VOL="${3:-Navi}"
[[ -d "$APP/Contents" ]] || { echo "not an app bundle: $APP" >&2; exit 1; }
STAGE="$(mktemp -d -t navi-dmg)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
# Optional Finder background: put a PNG at scripts/dmg-background.png and a .DS_Store
# recorded from a mounted image next to it; both are copied in when present.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$HERE/dmg-background.png" && -f "$HERE/dmg-DS_Store" ]]; then
  mkdir -p "$STAGE/.background"
  cp "$HERE/dmg-background.png" "$STAGE/.background/background.png"
  cp "$HERE/dmg-DS_Store" "$STAGE/.DS_Store"
fi
rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify -quiet "$DMG"
echo "$(du -h "$DMG" | awk '{print $1}')  $DMG"
