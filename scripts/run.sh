#!/bin/zsh
# Build (Debug) and (re)launch Navi.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh Debug build/DerivedData
pkill -x Navi 2>/dev/null || true
sleep 0.3
open build/DerivedData/Build/Products/Debug/Navi.app
echo "Navi launched. Logs: log stream --predicate 'subsystem == \"com.liamcarlin.navi\"' --level debug"
