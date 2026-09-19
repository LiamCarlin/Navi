#!/bin/zsh
# Reports whether Chrome is reachable for jev-ultrafast. Prints one line:
#   ready | chrome-not-running | debugging-blocked | runtime-missing | error: …
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$ROOT/vendor/jev-ultrafast"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
[[ -x "$VENDOR/.venv/bin/python" ]] || { echo "runtime-missing"; exit 0; }
pgrep -x "Google Chrome" >/dev/null || { echo "chrome-not-running"; exit 0; }
cd "$VENDOR"
OUT=$(uv run --python 3.12 browser-harness --doctor 2>&1 || true)
if echo "$OUT" | grep -qiE "\[ok *\] *daemon alive"; then echo "ready"; exit 0; fi
if echo "$OUT" | grep -qiE "\[FAIL\] *chrome running"; then echo "chrome-not-running"; exit 0; fi
if echo "$OUT" | grep -qiE "\[FAIL\] *daemon alive|permission|blocked|remote debugging"; then echo "debugging-blocked"; exit 0; fi
echo "error: $(echo "$OUT" | tail -3 | tr '\n' ' ')"
