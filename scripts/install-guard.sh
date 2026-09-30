#!/bin/zsh
# Sourced by scripts/install.sh. Every checkout and worktree installs to the same
# /Applications/Navi.app, and several agent sessions run installs, so:
#
#   install_lock_acquire   one install at a time, machine-wide. A second install waits
#                          (printing who holds the lock); a lock whose owner died is taken over.
#   install_check_newer    refuses to install a checkout that lacks commits already
#                          installed — an older worktree once silently replaced a newer build.
#   install_record         notes what was installed, for the next check.
#
# State lives in ~/Library/Caches/com.liamcarlin.navi.install/ (NAVI_INSTALL_STATE overrides, for tests).

NAVI_INSTALL_STATE="${NAVI_INSTALL_STATE:-$HOME/Library/Caches/com.liamcarlin.navi.install}"
NAVI_INSTALL_LOCK="$NAVI_INSTALL_STATE/lock"
NAVI_INSTALL_RECORD="$NAVI_INSTALL_STATE/installed"
NAVI_INSTALL_WAIT_SECONDS="${NAVI_INSTALL_WAIT_SECONDS:-1800}"
_navi_lock_owned=0

# Takes the lock or waits for it. Returns 1 after NAVI_INSTALL_WAIT_SECONDS.
install_lock_acquire() {
  mkdir -p "$NAVI_INSTALL_STATE"
  local waited=0 said=0
  while ! mkdir "$NAVI_INSTALL_LOCK" 2>/dev/null; do
    local owner_pid="" owner_desc=""
    [[ -f "$NAVI_INSTALL_LOCK/pid" ]] && owner_pid="$(<"$NAVI_INSTALL_LOCK/pid")"
    [[ -f "$NAVI_INSTALL_LOCK/owner" ]] && owner_desc="$(<"$NAVI_INSTALL_LOCK/owner")"
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "▸ Taking over a stale install lock (pid $owner_pid is gone)"
      rm -rf "$NAVI_INSTALL_LOCK"
      continue
    fi
    if [[ -z "$owner_pid" ]] && (( waited >= 5 )); then
      # Created but never filled in (killed between mkdir and write): stale after 5 s.
      rm -rf "$NAVI_INSTALL_LOCK"
      continue
    fi
    if (( waited >= NAVI_INSTALL_WAIT_SECONDS )); then
      echo "✗ Another install still holds the lock after ${waited}s: ${owner_desc:-pid $owner_pid}" >&2
      echo "  If it is stuck, remove $NAVI_INSTALL_LOCK" >&2
      return 1
    fi
    if (( waited - said >= 15 || waited == 0 )); then
      echo "▸ Waiting for another install to finish: ${owner_desc:-pid $owner_pid}"
      said=$waited
    fi
    sleep 1
    (( waited += 1 ))
  done
  _navi_lock_owned=1
  print -r -- "$$" > "$NAVI_INSTALL_LOCK/pid"
  print -r -- "pid $$ · $(pwd) @ $(_navi_head_desc) · since $(date '+%H:%M:%S')" > "$NAVI_INSTALL_LOCK/owner"
}

install_lock_release() {
  (( _navi_lock_owned )) || return 0
  [[ "$(cat "$NAVI_INSTALL_LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$NAVI_INSTALL_LOCK"
  _navi_lock_owned=0
}

_navi_head() { git rev-parse HEAD 2>/dev/null; }
_navi_head_desc() {
  local head; head="$(_navi_head)" || { echo "not a git checkout"; return; }
  local branch; branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  local dirty=""; [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty="+uncommitted"
  echo "${branch} ${head[1,8]}${dirty}"
}

# Fails when the installed build has commits this checkout doesn't.
install_check_newer() {
  [[ -f "$NAVI_INSTALL_RECORD" ]] || return 0
  local head; head="$(_navi_head)" || return 0
  local installed installed_desc
  installed="$(sed -n 1p "$NAVI_INSTALL_RECORD")"
  installed_desc="$(sed -n 2p "$NAVI_INSTALL_RECORD")"
  [[ -n "$installed" && "$installed" != "$head" ]] || return 0
  if ! git cat-file -e "$installed^{commit}" 2>/dev/null; then
    git fetch -q origin 2>/dev/null || true
  fi
  if git merge-base --is-ancestor "$installed" "$head" 2>/dev/null; then
    return 0
  fi
  echo "✗ Not installing: the Navi in /Applications has commits this checkout doesn't." >&2
  echo "    installed: $installed_desc" >&2
  echo "    this:      $(pwd) @ $(_navi_head_desc)" >&2
  if git cat-file -e "$installed^{commit}" 2>/dev/null; then
    echo "  Missing here:" >&2
    git log --oneline --no-decorate -8 "$head..$installed" 2>/dev/null | sed 's/^/    /' >&2
  fi
  echo "  Merge or rebase onto what is installed (usually origin/main), or pass --force to downgrade." >&2
  return 1
}

install_record() {
  local head; head="$(_navi_head)" || return 0
  mkdir -p "$NAVI_INSTALL_STATE"
  { echo "$head"; echo "$(pwd) @ $(_navi_head_desc) · $(date '+%Y-%m-%d %H:%M:%S')"; } > "$NAVI_INSTALL_RECORD"
}
