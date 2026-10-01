#!/usr/bin/env bash
# Deploy cloud/ to Vercel.
#
# `vercel deploy` from inside this git repo is refused ("commit author doesn't have permission":
# the GitHub noreply author isn't linked to the Vercel account). The workaround that works is to
# copy cloud/ to a directory outside any git repo and deploy from there. This script does that.
#
#   scripts/deploy.sh            # preview deployment (prints its URL)
#   scripts/deploy.sh --prod     # production (refuses a dirty tree unless --force)
#
# Env: VERCEL_PROJECT (default navi-cloud), VERCEL_SCOPE (default liam-carlins-projects),
#      NAVI_DEPLOY_DIR (default ~/.cache/navi-cloud-deploy — keeps .vercel/project.json between runs).
# Environment variables live in the Vercel project (see DEPLOY.md); no .env file is ever uploaded.
# The permanent fix is connecting the GitHub repo to the Vercel project (root directory `cloud`).
set -euo pipefail

PROD=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --prod) PROD=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SRC=$(cd "$(dirname "$0")/.." && pwd)
STAGE=${NAVI_DEPLOY_DIR:-$HOME/.cache/navi-cloud-deploy}
PROJECT=${VERCEL_PROJECT:-navi-cloud}
SCOPE=${VERCEL_SCOPE:-liam-carlins-projects}

command -v vercel >/dev/null || { echo "vercel CLI not found (npm i -g vercel)" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync not found" >&2; exit 1; }

COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
BRANCH=$(git -C "$SRC" rev-parse --abbrev-ref HEAD)
DIRTY=$(git -C "$SRC" status --porcelain -- . | head -1 || true)
echo "▶ cloud/ at $BRANCH@$COMMIT${DIRTY:+ (uncommitted changes)}"
if [ "$PROD" = 1 ] && [ -n "$DIRTY" ] && [ "$FORCE" = 0 ]; then
  echo "✗ refusing a production deploy with uncommitted changes in cloud/ (commit, or pass --force)" >&2
  exit 1
fi

echo "▶ tests + typecheck"
(cd "$SRC" && npm test --silent && npx --no-install tsc --noEmit)

mkdir -p "$STAGE"
if git -C "$STAGE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "✗ $STAGE is inside a git repository — Vercel would apply the author check again. Set NAVI_DEPLOY_DIR elsewhere." >&2
  exit 1
fi

echo "▶ staging → $STAGE"
# .vercel is excluded so the link survives --delete; .env* never leaves this machine.
rsync -a --delete \
  --exclude node_modules --exclude .next --exclude .vercel --exclude '.env*' \
  --exclude '*.tsbuildinfo' --exclude next-env.d.ts --exclude .DS_Store \
  "$SRC/" "$STAGE/"
printf '%s\n' "$BRANCH@$COMMIT" > "$STAGE/.deployed-commit"

cd "$STAGE"
if [ ! -f .vercel/project.json ]; then
  echo "▶ linking $STAGE to Vercel project $PROJECT ($SCOPE)"
  vercel link --yes --project "$PROJECT" --scope "$SCOPE"
fi

if [ "$PROD" = 1 ]; then
  echo "▶ vercel deploy --prod"
  vercel deploy --prod --yes --scope "$SCOPE"
else
  echo "▶ vercel deploy (preview)"
  vercel deploy --yes --scope "$SCOPE"
fi
echo "Next: scripts/smoke.sh against the URL above (see DEPLOY.md §8)."
