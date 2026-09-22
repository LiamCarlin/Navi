#!/bin/zsh
# Reports whether Chrome is reachable for jev-ultrafast. Prints one line:
#   ready | chrome-not-running | debugging-blocked | runtime-missing | error: …
# The interpreter comes from $NAVI_PYTHON (Navi passes the bundled runtime or the
# repo venv); without it the repo's vendor/jev-ultrafast/.venv is used. No uv needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${NAVI_PYTHON:-}"
[[ -n "$PY" ]] || PY="$(cd "$HERE/../.." && pwd)/vendor/jev-ultrafast/.venv/bin/python"
[[ -x "$PY" ]] || { echo "runtime-missing"; exit 0; }
pgrep -x "Google Chrome" >/dev/null || { echo "chrome-not-running"; exit 0; }
OUT=$(PYTHONDONTWRITEBYTECODE=1 "$PY" -B -m browser_harness.run --doctor 2>&1 || true)
if echo "$OUT" | grep -qiE "\[ok *\] *daemon alive"; then echo "ready"; exit 0; fi
if echo "$OUT" | grep -qiE "\[FAIL\] *chrome running"; then echo "chrome-not-running"; exit 0; fi
if echo "$OUT" | grep -qiE "\[FAIL\] *daemon alive|permission|blocked|remote debugging"; then echo "debugging-blocked"; exit 0; fi
echo "error: $(echo "$OUT" | tail -3 | tr '\n' ' ')"
