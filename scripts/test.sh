#!/bin/zsh
# Unit tests, hosted inside a Debug Navi.app. The host starts no services and uses a
# throwaway settings suite, an in-memory Keychain and scratch data dirs (Core/TestHost.swift).
# Network is off; `NAVI_TEST_NETWORK=1 scripts/test.sh` runs the `.needsNetwork` tests too,
# with API keys taken from this shell's env (TYPESAFE_API_KEY, ANTHROPIC_API_KEY, …).
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${1:-build/DerivedData}"
mkdir -p "$DD"
if [[ "${NAVI_TEST_NETWORK:-0}" == "1" ]]; then
  # xcodebuild hands TEST_RUNNER_<VAR> to the test host as <VAR>.
  export TEST_RUNNER_NAVI_TEST_NETWORK=1
  for k in TYPESAFE_API_KEY AI_GATEWAY_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY; do
    [[ -n "${(P)k:-}" ]] && export "TEST_RUNNER_$k=${(P)k}"
  done
fi
xcodegen generate --quiet
xcodebuild -project Navi.xcodeproj -scheme Navi -derivedDataPath "$DD" -destination 'platform=macOS' \
  test 2>&1 | tee "$DD.test.log" | grep -E "error:|Test Suite|passed|failed|skipped|\*\* " || true
grep -q "TEST SUCCEEDED" "$DD.test.log"
