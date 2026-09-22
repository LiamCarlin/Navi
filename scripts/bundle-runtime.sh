#!/bin/zsh
# Builds the relocatable browser runtime Navi ships inside the app and (optionally)
# places it at Navi.app/Contents/Resources/browser-runtime.
#
# What ends up in the bundle:
#   browser-runtime/
#     python-arm64/      python-build-standalone CPython 3.12 + deps in its site-packages (Apple silicon)
#     python-x86_64/     same for Intel Macs (--universal only; UltrafastBridge picks the tree by arch)
#     navi_runner.py     scripts/ultrafast/navi_runner.py
#     bin/doctor.sh      scripts/ultrafast/{doctor,approve}.sh (they take the interpreter from $NAVI_PYTHON)
#     bin/approve.sh
#     manifest.json      python + jev-ultrafast versions, build date, archs
#
# Chrome is NOT bundled: browser-harness drives the user's installed Google Chrome over CDP.
#
# The runtime is built once into build/runtime/<arch>/ and reused until the lockfile,
# the runner or the vendored source changes (a stamp file records what it was built from).
#
# Usage: scripts/bundle-runtime.sh [--into <Navi.app>] [--universal] [--force] [--cache <dir>]
#   --into      copy the runtime into that app bundle (Xcode's Release post-build phase does this)
#   --universal also build the x86_64 tree (cross-installed with uv; not importable on this Mac)
#   --force     rebuild the cache even if the stamp matches
set -euo pipefail
setopt null_glob      # rm of an absent pattern is not an error
SELF="$0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/jev-ultrafast"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# python-build-standalone release (https://github.com/astral-sh/python-build-standalone).
# Bump both together; the tarball is checked against the release's SHA256SUMS.
PBS_TAG="20260901"
PY_VERSION="3.12.14"
PY_MINOR="3.12"
PBS_BASE="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"

CACHE="$ROOT/build/runtime"
INTO=""
UNIVERSAL=0
FORCE=0
while (( $# )); do
  case "$1" in
    --into) INTO="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    --force) FORCE=1; shift ;;
    --cache) CACHE="$2"; shift 2 ;;
    -h|--help) sed -n 2,22p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HOST_ARCH="$(uname -m)"          # arm64 | x86_64
[[ "$HOST_ARCH" == "arm64" ]] && HOST_PBS_ARCH="aarch64" || HOST_PBS_ARCH="x86_64"
ARCHS=("$HOST_PBS_ARCH")
if (( UNIVERSAL )); then
  [[ "$HOST_PBS_ARCH" == "aarch64" ]] && ARCHS+=("x86_64") || ARCHS+=("aarch64")
fi

mkdir -p "$CACHE/downloads"
say() { echo "▸ $*"; }

# --- 1. Download + verify ----------------------------------------------------------
fetch_python() {   # $1 = aarch64|x86_64 → prints tarball path
  local arch="$1"
  local name="cpython-${PY_VERSION}+${PBS_TAG}-${arch}-apple-darwin-install_only.tar.gz"
  local dl="$CACHE/downloads/$name"
  local sums="$CACHE/downloads/SHA256SUMS-${PBS_TAG}"
  if [[ ! -f "$dl" ]]; then
    say "Downloading $name" >&2
    curl -fsSL --retry 3 -o "$dl.part" "$PBS_BASE/${name/+/%2B}"     # GitHub wants the + encoded
    mv "$dl.part" "$dl"
  fi
  [[ -f "$sums" ]] || curl -fsSL --retry 3 -o "$sums" "$PBS_BASE/SHA256SUMS"
  local expected actual
  expected="$(grep " $name\$" "$sums" | awk '{print $1}')"
  actual="$(shasum -a 256 "$dl" | awk '{print $1}')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "SHA-256 mismatch for $name (expected '$expected', got $actual) — deleting; run again" >&2
    rm -f "$dl"
    exit 1
  fi
  echo "$dl"
}

# --- 2. Dependency list from the vendored lockfile ---------------------------------
REQ="$CACHE/requirements.txt"
export_requirements() {
  command -v uv >/dev/null || { echo "uv is required to read vendor/jev-ultrafast/uv.lock (brew install uv)" >&2; exit 1; }
  (cd "$VENDOR" && uv export --frozen --no-dev --no-emit-project --no-hashes --quiet -o "$REQ")
}

# What the cache was built from: any change here forces a rebuild.
stamp_for() {   # $1 = arch
  local upstream; upstream="$(cat "$VENDOR/UPSTREAM_COMMIT" 2>/dev/null || echo unknown)"
  local srchash; srchash="$(find "$VENDOR/jev_ultrafast" -type f -name '*.py' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
  echo "pbs=${PY_VERSION}+${PBS_TAG} arch=$1 lock=$(shasum -a 256 "$VENDOR/uv.lock" | awk '{print $1}') upstream=$upstream src=$srchash script=$(shasum -a 256 "$SELF" | awk '{print $1}')"
}

# --- 3. Build one architecture's tree into $CACHE/<arch>/python ---------------------
build_tree() {   # $1 = aarch64|x86_64
  local arch="$1" out="$CACHE/$1" want
  want="$(stamp_for "$arch")"
  if (( ! FORCE )) && [[ -f "$out/.stamp" ]] && [[ "$(cat "$out/.stamp")" == "$want" ]] && [[ -x "$out/python/bin/python${PY_MINOR}" ]]; then
    say "Runtime cache for $arch is current ($out)"
    return
  fi
  local tarball; tarball="$(fetch_python "$arch")"
  say "Building $arch runtime in $out"
  rm -rf "$out"; mkdir -p "$out"
  tar -xzf "$tarball" -C "$out"          # → $out/python
  local PY="$out/python/bin/python${PY_MINOR}"
  local SITE="$out/python/lib/python${PY_MINOR}/site-packages"
  local native=0
  [[ "$arch" == "$HOST_PBS_ARCH" ]] && native=1

  export_requirements
  if (( native )); then
    # Installs into that interpreter's own site-packages (it is not a venv, hence --system).
    uv pip install --quiet --python "$PY" --system --break-system-packages --no-cache -r "$REQ"
  else
    local plat="x86_64-apple-darwin"; [[ "$arch" == "aarch64" ]] && plat="aarch64-apple-darwin"
    uv pip install --quiet --python-platform "$plat" --python-version "$PY_VERSION" --only-binary :all: \
      --target "$SITE" --no-cache -r "$REQ"
  fi

  # jev-ultrafast itself: the vendored package source, not an editable .pth into the repo.
  rm -rf "$SITE/jev_ultrafast"
  cp -R "$VENDOR/jev_ultrafast" "$SITE/jev_ultrafast"

  # Strip what a runtime never needs (about 60% of the tarball).
  local L="$out/python/lib/python${PY_MINOR}"
  rm -rf "$L/test" "$L/idlelib" "$L/tkinter" "$L/turtledemo" "$L/ensurepip" "$L/pydoc_data" "$L/config-${PY_MINOR}-darwin"
  rm -f "$L/lib-dynload/_tkinter"*.so "$L/lib-dynload/_test"*.so "$L/lib-dynload/xxlimited"*.so
  rm -rf "$SITE"/pip "$SITE"/pip-*.dist-info "$SITE"/setuptools "$SITE"/setuptools-*.dist-info "$SITE"/_distutils_hack "$SITE"/distutils-precedence.pth
  rm -rf "$SITE"/wheel "$SITE"/wheel-*.dist-info "$SITE"/pkg_resources
  rm -rf "$out/python/include" "$out/python/share" "$out/python/lib/pkgconfig" "$out/python/lib/"*.a
  # bin/python3.12 is statically linked (nothing references libpython) and Tcl/Tk only serve tkinter.
  rm -rf "$out/python/lib/libpython"*.dylib "$out/python/lib/"{tcl,tk,itcl,thread,tdbc,sqlite}* "$out/python/lib/libtcl"* "$out/python/lib/libtk"* "$out/python/lib/Tk"*
  find "$out/python/bin" -mindepth 1 -maxdepth 1 ! -name "python${PY_MINOR}" ! -name "python3" ! -name "python" -exec rm -f {} +
  find "$SITE" -type d \( -name tests -o -name test -o -name testing \) -prune -exec rm -rf {} +
  find "$out/python" -type d -name __pycache__ -prune -exec rm -rf {} +
  find "$out/python" -type f -name '*.pyc' -delete

  # Pre-compile bytecode with hash-based validation: the bundle is sealed by codesign, so
  # Python must never write __pycache__ into it (Navi also runs it with -B), and unchecked
  # hashes mean mtimes after ditto/DMG round-trips do not invalidate anything.
  if (( native )); then
    "$PY" -B -m compileall -q --invalidation-mode unchecked-hash "$L" >/dev/null
  elif [[ "$HOST_PBS_ARCH" == "aarch64" ]] && arch -x86_64 /usr/bin/true 2>/dev/null; then
    arch -x86_64 "$PY" -B -m compileall -q --invalidation-mode unchecked-hash "$L" >/dev/null || true
  fi

  # Ad-hoc sign every Mach-O so the tree runs as-is; release.sh re-signs with Developer ID.
  sign_tree "$out/python" "-"

  if (( native )); then
    local v; v="$("$PY" -I -B -c 'import sys, jev_ultrafast, browser_harness, cdp_use, httpx, websockets, certifi; print(sys.version.split()[0])')"
    say "Runtime $arch OK · Python $v · $(du -sh "$out/python" | awk '{print $1}')"
  else
    say "Runtime $arch built (cross-installed; not importable on this Mac) · $(du -sh "$out/python" | awk '{print $1}')"
  fi
  echo "$want" > "$out/.stamp"
}

# Signs every Mach-O under $1 with identity $2 (extra codesign flags in $3…).
sign_tree() {
  local dir="$1" identity="$2"; shift 2
  find "$dir" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 \
    | while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then codesign --force --sign "$identity" "$@" "$f" 2>&1 | grep -v 'replacing existing signature' || true; fi
      done
}

for a in "${ARCHS[@]}"; do build_tree "$a"; done

# --- 4. Assemble into the app --------------------------------------------------------
[[ -n "$INTO" ]] || { say "Runtime cache ready in $CACHE (pass --into <Navi.app> to bundle it)"; exit 0; }
[[ -d "$INTO/Contents" ]] || { echo "not an app bundle: $INTO" >&2; exit 1; }
RT="$INTO/Contents/Resources/browser-runtime"
say "Bundling runtime into $RT"
rm -rf "$RT"; mkdir -p "$RT/bin"
tree_name() { [[ "$1" == "aarch64" ]] && echo "python-arm64" || echo "python-x86_64"; }
for a in "${ARCHS[@]}"; do ditto "$CACHE/$a/python" "$RT/$(tree_name "$a")"; done
HOST_TREE="$RT/$(tree_name "$HOST_PBS_ARCH")"
cp "$ROOT/scripts/ultrafast/navi_runner.py" "$RT/navi_runner.py"
cp "$ROOT/scripts/ultrafast/doctor.sh" "$ROOT/scripts/ultrafast/approve.sh" "$RT/bin/"
chmod +x "$RT/bin/"*.sh
"$HOST_TREE/bin/python${PY_MINOR}" -I -B -m compileall -q --invalidation-mode unchecked-hash "$RT/navi_runner.py" >/dev/null || true
cat > "$RT/manifest.json" <<EOF
{
  "python": "${PY_VERSION}",
  "python_build_standalone": "${PBS_TAG}",
  "archs": [$(printf '"%s",' "${ARCHS[@]}" | sed 's/,$//')],
  "jev_ultrafast_upstream": "$(cat "$VENDOR/UPSTREAM_COMMIT" 2>/dev/null | tr -d '\n' || echo unknown)",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
say "Bundled · $(du -sh "$RT" | awk '{print $1}') · $(find "$RT" -type f | wc -l | tr -d ' ') files"
