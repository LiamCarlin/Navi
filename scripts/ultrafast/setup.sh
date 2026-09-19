#!/bin/zsh
# Installs the jev-ultrafast runtime Navi uses for browser tasks.
#   - uv (Python package manager)          brew install uv
#   - Python 3.12 (fetched by uv)
#   - vendor/jev-ultrafast deps incl. browser-harness (Chrome CDP bridge)
# Usage: scripts/ultrafast/setup.sh [--check]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$ROOT/vendor/jev-ultrafast"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

if [[ "${1:-}" == "--check" ]]; then
  command -v uv >/dev/null || { echo "uv: missing"; exit 3; }
  [[ -x "$VENDOR/.venv/bin/python" ]] || { echo "venv: missing"; exit 4; }
  "$VENDOR/.venv/bin/python" -c "import jev_ultrafast, browser_harness" 2>/dev/null || { echo "deps: missing"; exit 5; }
  echo "ok $("$VENDOR/.venv/bin/python" --version)"
  exit 0
fi

if ! command -v uv >/dev/null; then
  if command -v brew >/dev/null; then brew install uv; else curl -LsSf https://astral.sh/uv/install.sh | sh; fi
fi
cd "$VENDOR"
uv sync --python 3.12 --frozen
uv run --python 3.12 python -c "import jev_ultrafast, browser_harness; print('jev-ultrafast runtime ready')"
echo
echo "Next: open Chrome → chrome://inspect/#remote-debugging → tick 'Allow remote debugging for this browser instance'."
echo "Then in Navi → Settings → Agent → 'Check Chrome connection'."
