#!/bin/zsh
# Writes the update feed Navi's in-app updater reads (Navi/App/Updater.swift):
#   {version, build, url, sha256, ed25519, notes, minOS, published}
# The ed25519 signature is over the DMG bytes (raw 64-byte, base64), made with
#   openssl pkeyutl -sign -rawin -inkey <key.pem> -in <dmg>
# and checked by CryptoKit against the public key compiled into Updater.swift.
#
# Usage: scripts/gen-appcast.sh --dmg <file> --version <x.y.z> --build <n> --url <https://…/Navi-x.y.z.dmg>
#                               [--notes <file>] [--min-os 26.0] [--key <pem>] [-o appcast.json]
# Key: --key, else $NAVI_UPDATE_KEY, else ~/.config/navi-release/update-key.pem.
#   Generate once:  openssl genpkey -algorithm ed25519 -out ~/.config/navi-release/update-key.pem
#   Public key for Updater.swift:  openssl pkey -in update-key.pem -pubout -outform DER | tail -c 32 | base64
set -euo pipefail
DMG=""; VERSION=""; BUILD=""; URL=""; NOTES=""; MIN_OS="26.0"; KEY="${NAVI_UPDATE_KEY:-$HOME/.config/navi-release/update-key.pem}"; OUT="appcast.json"
while (( $# )); do
  case "$1" in
    --dmg) DMG="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --min-os) MIN_OS="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$DMG" && -n "$VERSION" && -n "$BUILD" && -n "$URL" ]] || { echo "usage: $0 --dmg <file> --version <x.y.z> --build <n> --url <url> [...]" >&2; exit 2; }

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIG=""
if [[ -f "$KEY" ]]; then
  SIG="$(openssl pkeyutl -sign -rawin -inkey "$KEY" -in "$DMG" | base64)"
  PUB="$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)"
else
  echo "▸ No update key at $KEY — appcast.json will be UNSIGNED and Navi will refuse to install from it." >&2
  PUB=""
fi

NOTES_TEXT=""
[[ -n "$NOTES" && -f "$NOTES" ]] && NOTES_TEXT="$(cat "$NOTES")"

python3 - "$OUT" "$VERSION" "$BUILD" "$URL" "$SHA" "$SIG" "$MIN_OS" "$NOTES_TEXT" <<'EOF'
import json, sys, datetime
out, version, build, url, sha, sig, min_os, notes = sys.argv[1:9]
doc = {
    "version": version,
    "build": build,
    "url": url,
    "sha256": sha,
    "ed25519": sig,
    "notes": notes,
    "minOS": min_os,
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF
echo "$OUT: Navi $VERSION ($BUILD) sha256=${SHA:0:12}… $( [[ -n "$SIG" ]] && echo "signed (public key ${PUB:0:12}…)" || echo unsigned )"
if [[ -n "$PUB" ]] && ! grep -q "$PUB" "$(dirname "$0")/../Navi/App/Updater.swift" 2>/dev/null; then
  echo "▸ WARNING: this key's public half ($PUB) is not the one in Navi/App/Updater.swift — shipped apps will reject this appcast." >&2
fi
