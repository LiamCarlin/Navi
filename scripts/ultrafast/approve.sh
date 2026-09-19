#!/bin/zsh
# Dismisses Chrome's per-connection "Allow" sheet on macOS (needs Accessibility for Navi).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
cd "$ROOT/vendor/jev-ultrafast" && uv run --python 3.12 browser-harness mac-approve 2>&1 | tail -3
