#!/bin/zsh
# Offline task bench: Navi's decision layer on every task in scripts/taskbench/tasks.json,
# with live Jev and (by default) a fresh COPY of screen memory. Nothing drives the screen.
#
#   scripts/taskbench/offline.sh                    # all tasks, with memory
#   scripts/taskbench/offline.sh --no-memory        # without screen memory
#   scripts/taskbench/offline.sh --only errand-01,msg-02
#   scripts/taskbench/offline.sh --planner          # also ask TaskPlanner (Claude) per task
#   scripts/taskbench/offline.sh --repeat 3         # every task 3× (how stable Jev's decisions are)
#   scripts/taskbench/offline.sh --dd build/DerivedData-bench
#
# Keys: TYPESAFE_API_KEY / AI_GATEWAY_API_KEY / ANTHROPIC_API_KEY from the env, else from the
# Keychain item Navi's own dev scripts use (`security find-generic-password -s com.liamcarlin.navi -a keys -w`,
# a JSON object). Keys are never printed. Results: build/taskbench/offline-<stamp>.{json,md}.
set -euo pipefail
cd "$(dirname "$0")/../.."

DD="build/DerivedData-bench"
MEMORY=1
ONLY=""
PLANNER=0
REPEAT=1
while (( $# )); do
  case "$1" in
    --no-memory) MEMORY=0 ;;
    --only) ONLY="$2"; shift ;;
    --planner) PLANNER=1 ;;
    --repeat) REPEAT="$2"; shift ;;
    --dd) DD="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "${TYPESAFE_API_KEY:-}${AI_GATEWAY_API_KEY:-}" ]]; then
  KEYS_JSON="$(security find-generic-password -s com.liamcarlin.navi -a keys -w 2>/dev/null || true)"
  if [[ -n "$KEYS_JSON" ]]; then
    for k in TYPESAFE_API_KEY AI_GATEWAY_API_KEY ANTHROPIC_API_KEY; do
      v="$(KEYS_JSON="$KEYS_JSON" python3 -c "import json,os,sys; print(json.loads(os.environ['KEYS_JSON']).get(sys.argv[1],''))" "$k")"
      [[ -n "$v" ]] && export "$k=$v"
    done
  fi
  unset KEYS_JSON
fi
if [[ -z "${TYPESAFE_API_KEY:-}${AI_GATEWAY_API_KEY:-}" ]]; then
  echo "No Jev key (TYPESAFE_API_KEY / AI_GATEWAY_API_KEY) in the env or the Keychain item." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="build/taskbench"
mkdir -p "$OUTDIR" "$DD"
OUT="$PWD/$OUTDIR/offline-$STAMP.json"

if (( MEMORY )); then
  LIVE_DB="$HOME/Library/Application Support/Navi/memory.sqlite"
  if [[ -f "$LIVE_DB" ]]; then
    COPY="$(mktemp -d)/memory.sqlite"
    # The online-backup API reads a consistent snapshot without writing to the live database.
    sqlite3 "file:$LIVE_DB?mode=ro" ".backup '$COPY'"
    export TEST_RUNNER_NAVI_BENCH_DB="$COPY"
    echo "▸ screen memory: a copy at $COPY"
  else
    echo "▸ no memory.sqlite — running without screen memory"
  fi
fi

export TEST_RUNNER_NAVI_TEST_NETWORK=1
for k in TYPESAFE_API_KEY AI_GATEWAY_API_KEY ANTHROPIC_API_KEY; do
  [[ -n "${(P)k:-}" ]] && export "TEST_RUNNER_$k=${(P)k}"
done
export TEST_RUNNER_NAVI_BENCH_OUT="$OUT"
[[ -n "$ONLY" ]] && export TEST_RUNNER_NAVI_BENCH_ONLY="$ONLY"
(( PLANNER )) && export TEST_RUNNER_NAVI_BENCH_PLANNER=1
export TEST_RUNNER_NAVI_BENCH_REPEAT="$REPEAT"

xcodegen generate --quiet
xcodebuild -project Navi.xcodeproj -scheme Navi -derivedDataPath "$DD" -destination 'platform=macOS' \
  -only-testing:NaviTests/TaskBenchTests test > "$DD.taskbench.log" 2>&1 || true

[[ -n "${COPY:-}" ]] && rm -rf "$(dirname "$COPY")"
if [[ -f "${OUT%.json}.md" ]]; then
  cat "${OUT%.json}.md"
  echo
  echo "▸ results: $OUT"
else
  grep -E "error:|failed|TEST (SUCCEEDED|FAILED)" "$DD.taskbench.log" | tail -20
  echo "No results written; full log: $DD.taskbench.log" >&2
  exit 1
fi
