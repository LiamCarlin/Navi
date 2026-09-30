#!/bin/zsh
# Re-vendors https://github.com/awlevin/typesafe-computer-use into vendor/typesafe-computer-use.
#
# That repository is the source of truth for how Navi's native computer-use driver thinks
# (Navi/Agent/TypesafeCU/). The Swift port follows it module by module; docs/TYPESAFE_CU.md
# maps each Python module to its Swift counterpart. After a sync, read the upstream diff
# (`git diff vendor/typesafe-computer-use`) and carry every change in decide.py, runner.py,
# actions.py, writer.py, perception.py, models.py and dates.py into the port and its tests.
#
# Usage: scripts/typesafe-cu/sync.sh [<commit-or-branch>]   (default: main)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REF="${1:-main}"
DEST="$ROOT/vendor/typesafe-computer-use"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --quiet https://github.com/awlevin/typesafe-computer-use "$TMP/src"
git -C "$TMP/src" checkout --quiet "$REF"
COMMIT="$(git -C "$TMP/src" rev-parse HEAD)"
PREVIOUS="$(cat "$DEST/UPSTREAM_COMMIT" 2>/dev/null || echo none)"

rm -rf "$DEST"
mkdir -p "$DEST"
rsync -a --exclude .git --exclude .venv --exclude __pycache__ "$TMP/src/" "$DEST/"
echo "$COMMIT" > "$DEST/UPSTREAM_COMMIT"

echo "vendored typesafe-computer-use $COMMIT (was $PREVIOUS)"
if [[ "$PREVIOUS" != none && "$PREVIOUS" != "$COMMIT" ]]; then
  echo "upstream changes to port:"
  git -C "$TMP/src" log --oneline "$PREVIOUS..$COMMIT" -- typesafe_computer_use/ 2>/dev/null || true
fi
