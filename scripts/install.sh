#!/bin/zsh
# Build Navi (Release) and install it to /Applications/Navi.app.
# Usage: scripts/install.sh [--no-launch] [--release]
#   --release   go through scripts/release.sh --dry-run (deep-signed, bundled runtime, DMG)
#               and install the app out of that DMG — exercises exactly what ships.
set -euo pipefail
cd "$(dirname "$0")/.."

DD="build/DerivedData-release"
DEST="/Applications/Navi.app"
LAUNCH=1
RELEASE=0
for a in "$@"; do
  case "$a" in
    --no-launch) LAUNCH=0 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found: install Xcode 26"; exit 1; }

MOUNT=""
cleanup() { [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; }
trap cleanup EXIT
if (( RELEASE )); then
  echo "▸ Release pipeline (dry run)…"
  scripts/release.sh --dry-run
  DMG="$(ls -t build/release/Navi-*.dmg | head -1)"
  MOUNT="$(mktemp -d -t navi-install)"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
  SRC="$MOUNT/Navi.app"
  echo "▸ Installing from $DMG"
else
  echo "▸ Building Release…"
  scripts/build.sh Release "$DD"
  SRC="$DD/Build/Products/Release/Navi.app"
fi
[[ -d "$SRC" ]] || { echo "Build product missing: $SRC"; exit 1; }

if pgrep -x Navi >/dev/null; then
  echo "▸ Quitting running Navi…"
  osascript -e 'tell application "Navi" to quit' >/dev/null 2>&1 || pkill -x Navi || true
  sleep 0.5
fi

echo "▸ Installing to $DEST…"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# Register the bundle (navi:// URL scheme, Launch Services).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
RUNTIME="repo checkout (Debug-style)"
[[ -d "$DEST/Contents/Resources/browser-runtime" ]] && RUNTIME="bundled ($(du -sh "$DEST/Contents/Resources/browser-runtime" | awk '{print $1}'))"
echo "✓ Installed Navi $VERSION at $DEST · browser runtime: $RUNTIME"

if (( LAUNCH )); then
  echo "▸ Launching…"
  open "$DEST"
fi

cat <<'EOF'

Next steps
──────────
1. Navi lives in the menu bar (✦). Its window opens on first launch with a
   5-step setup; you can reopen it any time from ✦ → "Navi App & Settings…".

2. Add API keys (AI Providers):
     Jev / TypeSafe   https://console.typesafe.ai/keys
     Claude           https://platform.claude.com
   Keys are stored in your Keychain. Use "Test" to confirm each one.

3. Grant permissions (Permissions), then quit & relaunch Navi once:
     Accessibility     — lets the agent click and type
     Screen Recording  — lets the agent see the screen / Screen Memory capture
     Automation        — lets Navi read the current browser tab
   System Settings → Privacy & Security → (Accessibility | Screen Recording | Automation)

4. Free up ⌘Space. macOS gives it to Spotlight by default:
     General → "Disable Spotlight's ⌘Space for me"   (or Open Keyboard Shortcuts…)
   A logout may be needed for Spotlight to release the key — or record a
   different hotkey for Navi (⌥Space works well).

5. Optional: General → Launch at login;  Screen Memory → Remember what I see.

Logs:  log stream --predicate 'subsystem == "com.liamcarlin.navi"' --level debug
EOF
