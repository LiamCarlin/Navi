#!/bin/zsh
# Uploads what scripts/release.sh produced to a GitHub Release — the default hosting for
# Navi's DMG and update feed (docs/RELEASE.md § Hosting):
#
#   https://github.com/<repo>/releases/download/v<version>/Navi-<version>.dmg   ← appcast "url"
#   https://github.com/<repo>/releases/latest/download/appcast.json              ← NaviUpdateFeedURL
#   https://github.com/<repo>/releases/latest/download/Navi.dmg                  ← the site's Download button
#
# The release is created as a DRAFT: nothing is public (and no installed Navi is offered the
# update) until you press "Publish release" on GitHub, or pass --publish.
#
# Usage: scripts/publish-release.sh [--repo owner/name] [--publish] [--dry-run] [--allow-unsigned]
#   --dry-run          print what would be uploaded and the gh command; touch nothing
#   --allow-unsigned   allow a build that is not notarized / an appcast without a signature
#                      (a private test release; never --publish one)
# Needs: gh (authenticated), build/release/{Navi-<v>.dmg, appcast.json} from scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${NAVI_RELEASE_REPO:-LiamCarlin/Navi}"; PUBLISH=0; DRY=0; UNSIGNED_OK=0
while (( $# )); do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --allow-unsigned) UNSIGNED_OK=1; shift ;;
    -h|--help) sed -n 2,17p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
OUT="build/release"
FEED="$OUT/appcast.json"
[[ -f "$FEED" ]] || { echo "No $FEED — run scripts/release.sh first." >&2; exit 1; }
VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$FEED")"
URL="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$FEED")"
SIG="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ed25519",""))' "$FEED")"
DMG="$OUT/Navi-$VERSION.dmg"
TAG="v$VERSION"
[[ -f "$DMG" ]] || { echo "No $DMG next to the appcast." >&2; exit 1; }

problems=()
EXPECTED="https://github.com/$REPO/releases/download/$TAG/Navi-$VERSION.dmg"
[[ "$URL" == "$EXPECTED" ]] || problems+=("appcast url is $URL, not $EXPECTED — rerun release.sh with NAVI_RELEASE_REPO=$REPO (or NAVI_DOWNLOAD_BASE)")
[[ -n "$SIG" ]] || problems+=("appcast.json is unsigned — installed copies will refuse it (update key: docs/RELEASE.md step 3)")
if ! xcrun stapler validate -q "$DMG" >/dev/null 2>&1; then
  problems+=("$DMG is not notarized/stapled — Gatekeeper will block it on other Macs")
fi
if (( ${#problems} )); then
  for p in "${problems[@]}"; do echo "▸ $p" >&2; done
  if (( ! UNSIGNED_OK )); then
    echo "Refusing to upload. Fix the above, or pass --allow-unsigned for a private test draft." >&2
    exit 1
  fi
  (( PUBLISH )) && { echo "--publish is not allowed with --allow-unsigned." >&2; exit 1; }
fi

# A stable name for the website's Download button (…/releases/latest/download/Navi.dmg).
ALIAS="$OUT/Navi.dmg"
NOTES="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("notes") or "")' "$FEED")"
[[ -n "$NOTES" ]] || NOTES="Navi $VERSION"
ARGS=(release create "$TAG" "$DMG" "$ALIAS" "$FEED" --repo "$REPO" --title "Navi $VERSION" --notes "$NOTES")
(( PUBLISH )) || ARGS+=(--draft)
if (( DRY )); then
  echo "Would upload to $REPO ($TAG, $( (( PUBLISH )) && echo published || echo draft )):"
  echo "  $DMG ($(du -h "$DMG" | awk '{print $1}'))  +  Navi.dmg (same file)  +  $FEED"
  echo "  gh ${ARGS[*]}"
  exit 0
fi
command -v gh >/dev/null || { echo "gh is required (brew install gh; gh auth login)" >&2; exit 1; }
cp "$DMG" "$ALIAS"
trap 'rm -f "$ALIAS"' EXIT
gh "${ARGS[@]}"
echo
if (( PUBLISH )); then
  echo "Published. Check: curl -sL https://github.com/$REPO/releases/latest/download/appcast.json | python3 -m json.tool"
else
  echo "Draft created: https://github.com/$REPO/releases/tag/$TAG — review it, then press \"Publish release\"."
  echo "Until then installed copies keep seeing the previous appcast.json."
fi
