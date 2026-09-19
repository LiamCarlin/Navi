#!/bin/zsh
# Build Navi (Release) and install it to /Applications/Navi.app.
# Usage: scripts/install.sh [--no-launch]
set -euo pipefail
cd "$(dirname "$0")/.."

DD="build/DerivedData-release"
DEST="/Applications/Navi.app"
LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found: install Xcode 26"; exit 1; }

echo "▸ Building Release…"
scripts/build.sh Release "$DD"
SRC="$DD/Build/Products/Release/Navi.app"
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
echo "✓ Installed Navi $VERSION at $DEST"

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
