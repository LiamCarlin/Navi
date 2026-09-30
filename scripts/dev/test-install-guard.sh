#!/bin/zsh
# Tests scripts/install-guard.sh without building anything: lock contention,
# stale locks, Ctrl-C release, and the downgrade check. Run from the repo root.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
STATE="$(mktemp -d -t navi-install-guard)"
export NAVI_INSTALL_STATE="$STATE"
fail=0
check() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=1; fi }

# A fake install: take the lock, note start/end, hold it for $2 seconds.
holder() {
  zsh -c "source '$ROOT/scripts/install-guard.sh'; trap install_lock_release EXIT; trap 'exit 130' INT TERM
          install_lock_acquire || exit 1
          echo \"\$(date +%s.%N 2>/dev/null || date +%s) start $1\" >> '$STATE/events'
          sleep $2
          echo \"\$(date +%s) end $1\" >> '$STATE/events'"
}

# 1. Two installs at once: the second starts only after the first ends.
holder A 3 > "$STATE/a.out" & pa=$!
sleep 0.5
holder B 1 > "$STATE/b.out" & pb=$!
wait $pa $pb
check "second install waits for the first" '[[ "$(cut -d" " -f2- "$STATE/events" | tr "\n" ",")" == "start A,end A,start B,end B," ]]'
check "the waiting install says who it waits for" 'grep -q "Waiting for another install to finish: pid" "$STATE/b.out"'
check "lock is released afterwards" '[[ ! -e "$STATE/lock" ]]'

# 2. A lock left by a process that died is taken over.
mkdir -p "$STATE/lock"; echo 999999 > "$STATE/lock/pid"; echo "pid 999999 · gone" > "$STATE/lock/owner"
rm -f "$STATE/events"; holder C 0 > "$STATE/c.out"
check "stale lock is taken over" 'grep -q "stale install lock" "$STATE/c.out" && grep -q "start C" "$STATE/events"'

# 3. Ctrl-C during an install releases the lock.
holder D 30 > /dev/null & pd=$!
sleep 1; kill -INT $pd; wait $pd 2>/dev/null
check "interrupted install releases the lock" '[[ ! -e "$STATE/lock" ]]'

# 4. Downgrade check: a checkout missing the installed commits is refused.
head=$(git rev-parse HEAD); old=$(git rev-parse HEAD~3)
OLDTREE="$STATE/oldtree"; git worktree add -q --detach "$OLDTREE" "$old"
{ echo "$head"; echo "test @ $head"; } > "$STATE/installed"
( cd "$OLDTREE" && source "$ROOT/scripts/install-guard.sh" && install_check_newer ) > "$STATE/old.out" 2>&1
check "older checkout is refused" '[[ $? -ne 0 ]] && grep -q "Not installing" "$STATE/old.out" && grep -q "Missing here" "$STATE/old.out"'
( source scripts/install-guard.sh && install_check_newer ) > /dev/null 2>&1
check "same commit is fine" '[[ $? -eq 0 ]]'
{ echo "$old"; echo "test @ $old"; } > "$STATE/installed"
( source scripts/install-guard.sh && install_check_newer ) > /dev/null 2>&1
check "newer checkout is fine" '[[ $? -eq 0 ]]'
git worktree remove --force "$OLDTREE"

rm -rf "$STATE"
exit $fail
