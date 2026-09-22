#!/bin/zsh
# Proves the browser runtime bundled inside a Navi.app works on its own — no repo, no uv,
# no PYTHON* environment — the way it will on someone else's Mac.
#
#   1. --version / --selftest: every dependency imports from the bundled interpreter
#   2. a real one-step browser task against the user's Chrome (needs the Jev key in the
#      Keychain and Chrome with remote debugging allowed; skipped with --no-task)
#
# Usage: scripts/dev/runtime-smoke.sh [Navi.app] [--no-task] [--goal "…"] [--url https://…]
#   default app: build/release/Navi.app, then /tmp/NaviDist/Navi.app, then /Applications/Navi.app
set -uo pipefail
cd "$(dirname "$0")/../.."
APP=""; TASK=1; GOAL="read the page title"; URL="https://example.com"
while (( $# )); do
  case "$1" in
    --no-task) TASK=0; shift ;;
    --goal) GOAL="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done
if [[ -z "$APP" ]]; then
  for c in build/release/Navi.app /tmp/NaviDist/Navi.app /Applications/Navi.app; do
    [[ -x "$c/Contents/Resources/browser-runtime/python-arm64/bin/python3.12" ]] && { APP="$c"; break; }
  done
fi
RT="$APP/Contents/Resources/browser-runtime"
[[ "$(uname -m)" == "arm64" ]] && PY="$RT/python-arm64/bin/python3.12" || PY="$RT/python-x86_64/bin/python3.12"
[[ -x "$PY" ]] || { echo "no bundled runtime in ${APP:-<none>} (build one: scripts/release.sh --dry-run)"; exit 1; }

echo "▸ App:      $APP"
echo "▸ Python:   $PY"
echo "▸ Manifest: $(cat "$RT/manifest.json" | tr -d '\n' | tr -s ' ')"
echo "▸ Sig:      $(codesign -dv "$PY" 2>&1 | grep -E '^(Signature|Authority=Developer ID|TeamIdentifier)' | head -2 | tr '\n' ' ')"
echo

# A scrubbed environment: only what Navi itself passes (UltrafastBridge.environment()).
CLEAN=(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
       SSL_CERT_FILE="$(dirname "$PY")/../lib/python3.12/site-packages/certifi/cacert.pem" NAVI_PYTHON="$PY")

echo "▸ 1/3 selftest (python -I -B navi_runner.py --version)"
OUT="$("${CLEAN[@]}" "$PY" -I -B "$RT/navi_runner.py" --version)"; RC=$?
echo "$OUT" | python3 -m json.tool 2>/dev/null || echo "$OUT"
(( RC == 0 )) || { echo "selftest FAILED ($RC)"; exit 1; }
echo

echo "▸ 2/3 doctor.sh from the bundle (bin/doctor.sh, NAVI_PYTHON=bundled)"
DOCTOR="$("${CLEAN[@]}" /bin/zsh "$RT/bin/doctor.sh" 2>&1)"
echo "    $DOCTOR"
echo

(( TASK )) || { echo "▸ 3/3 task skipped (--no-task)"; exit 0; }
echo "▸ 3/3 one-step task: \"$GOAL\" on $URL (background tab, closed afterwards)"
# Keys: the environment first (no Keychain prompt), else Navi's Keychain item (may prompt once).
JEV="${TYPESAFE_API_KEY:-}"; ANTH="${ANTHROPIC_API_KEY:-}"
if [[ -z "$JEV" ]]; then
  KEYS="$(security find-generic-password -s com.liamcarlin.navi -a keys -w 2>/dev/null || true)"
  JEV="$(printf '%s' "$KEYS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("TYPESAFE_API_KEY",""))' 2>/dev/null || true)"
  [[ -n "$ANTH" ]] || ANTH="$(printf '%s' "$KEYS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ANTHROPIC_API_KEY",""))' 2>/dev/null || true)"
fi
[[ -n "$JEV" ]] || { echo "    no TYPESAFE_API_KEY (Keychain or env) — cannot run a task"; exit 1; }
[[ "$DOCTOR" == "ready" ]] || { echo "    Chrome is not reachable ($DOCTOR) — open Chrome and allow remote debugging (chrome://inspect/#remote-debugging)"; exit 1; }
"${CLEAN[@]}" TYPESAFE_API_KEY="$JEV" ANTHROPIC_API_KEY="${ANTH:-${ANTHROPIC_API_KEY:-}}" TYPESAFE_MODEL=jev-latest \
  NAVI_TEXT_MODEL=claude-haiku-4-5 NAVI_BACKGROUND_TAB=1 NAVI_TAB_POLICY=close \
  "$PY" -I -B -u "$RT/navi_runner.py" --url "$URL" --goal "$GOAL" --max-steps 3 2>"$TMPDIR/navi-smoke-stderr.log" \
  | python3 -c '
import json, sys
status = None
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except ValueError: print("   ", line); continue
    ev = e.get("event")
    if ev == "status": print("    status  ", e.get("message"))
    elif ev == "ready": print("    ready   ", e.get("elements"), "elements ·", e.get("title"))
    elif ev == "decision":
        conf = int((e.get("confidence") or 0) * 100)
        print("    jev     ", e.get("operation"), e.get("target") or "", str(conf) + "% ·", e.get("latency_ms"), "ms")
    elif ev == "step": print("    step    ", e.get("kind"), e.get("action"))
    elif ev == "done":
        status = e.get("status"); print("    done    ", status, "·", e.get("summary"), "·", e.get("elapsed_ms"), "ms"); print("    title   ", e.get("title")); print("    url     ", e.get("url"))
    elif ev == "error": status = "error"; print("    error   ", e.get("message"))
sys.exit(0 if status in ("done", "blocked") else 1)
'
RC=$?
(( RC == 0 )) && echo "▸ runtime smoke OK" || { echo "▸ runtime smoke FAILED ($RC) — stderr tail:"; tail -5 "$TMPDIR/navi-smoke-stderr.log"; }
exit $RC
