#!/bin/zsh
# Dismisses Chrome's per-connection "Allow" sheet on macOS (needs Accessibility for Navi).
# Interpreter from $NAVI_PYTHON (bundled runtime or repo venv); falls back to the repo venv.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${NAVI_PYTHON:-}"
[[ -n "$PY" ]] || PY="$(cd "$HERE/../.." && pwd)/vendor/jev-ultrafast/.venv/bin/python"
[[ -x "$PY" ]] || { echo "runtime missing"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 "$PY" -B -m browser_harness.run mac-approve 2>&1 | tail -3
