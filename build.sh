#!/usr/bin/env bash
# Build BTT Workbench with lazbuild.
#
#   ./build.sh            tests, CLI, shared library and GUI, then run tests
#   ./build.sh <x.lpi>... just those projects
#   ./build.sh --win64 [<x.lpi>...]
#                         Windows 64-bit .exe files (default: CLI and GUI);
#                         needs FPC's win64 units
#
# The version is <release>+<build> (as BTT-Writer's 1.6.0+1073): the
# release comes from src/core/WBVersion.pas, the build number is the git
# commit count, and the short commit (with -modified for uncommitted
# changes) goes along with it. They reach the compiler as BTW_BUILD and
# BTW_COMMIT, and the Windows file properties through a temporary copy of
# each .lpi that has <VersionInfo>.
#
# Environment:
#   LAZ_ROOT   fpcupdeluxe install (default ~/fpcupdeluxe)
#   LAZBUILD   lazbuild binary     (default $LAZ_ROOT/lazarus/lazbuild)
#   LCL_WS     widgetset for the GUI, e.g. qt6 (default: Lazarus default, gtk2)
#
# PATH is reset to the FPC bin dir + /usr/bin:/bin: a linuxbrew ld earlier
# on PATH breaks FPC links.

set -euo pipefail
cd "$(dirname "$0")"

LAZ_ROOT="${LAZ_ROOT:-$HOME/fpcupdeluxe}"
LAZBUILD="${LAZBUILD:-$LAZ_ROOT/lazarus/lazbuild}"
export PATH="$LAZ_ROOT/fpc/bin/x86_64-linux:/usr/bin:/bin"

if [[ ! -x "$LAZBUILD" ]]; then
  echo "error: lazbuild not found at $LAZBUILD (set LAZ_ROOT or LAZBUILD)" >&2
  exit 1
fi

WIN64=0
if [[ "${1:-}" == "--win64" ]]; then
  WIN64=1
  shift
fi

RUN_TESTS=0
if [[ $# -eq 0 ]]; then
  if [[ $WIN64 -eq 1 ]]; then
    set -- src/cli/btw.lpi src/gui/BttWorkbench.lpi
  else
    set -- tests/TestCore.lpi src/cli/btw.lpi src/lib/btw.lpi src/gui/BttWorkbench.lpi
    RUN_TESTS=1
  fi
fi

mkdir -p lib
TARGET_ARGS=()
if [[ $WIN64 -eq 1 ]]; then
  TARGET_ARGS=(--os=win64 --cpu=x86_64 --ws=win32)
elif [[ -n "${LCL_WS:-}" ]]; then
  TARGET_ARGS=(--ws="$LCL_WS")
fi

# Version
RELEASE=$(sed -n "s/^ *WorkbenchRelease = '\(.*\)';.*/\1/p" src/core/WBVersion.pas)
BTW_BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
BTW_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if ! git diff --quiet HEAD -- 2>/dev/null; then
  BTW_COMMIT="$BTW_COMMIT-modified"
fi
export BTW_BUILD BTW_COMMIT
if [[ "$(cat lib/version.stamp 2>/dev/null)" != "$RELEASE+$BTW_BUILD $BTW_COMMIT" ]]; then
  echo "$RELEASE+$BTW_BUILD $BTW_COMMIT" > lib/version.stamp
  touch src/core/WBVersion.pas   # so it is compiled again with the new values
fi
echo "== version $RELEASE+$BTW_BUILD ($BTW_COMMIT)"

TEMP_LPIS=()
cleanup() {
  local f
  for f in "${TEMP_LPIS[@]}"; do
    rm -f "$f" "${f%.lpi}.lps"
  done
}
trap cleanup EXIT

# A copy of the .lpi with the version numbers filled in, beside it.
versioned_lpi() {
  local lpi=$1 major minor rev copy
  IFS=. read -r major minor rev <<< "$RELEASE"
  copy="$(dirname "$lpi")/.$(basename "$lpi" .lpi)-build.lpi"
  sed -e '/<MajorVersionNr\|<MinorVersionNr\|<RevisionNr\|<BuildNr/d' \
      -e "s|<UseVersionInfo Value=\"True\"/>|<UseVersionInfo Value=\"True\"/><MajorVersionNr Value=\"$major\"/><MinorVersionNr Value=\"$minor\"/><RevisionNr Value=\"$rev\"/><BuildNr Value=\"$BTW_BUILD\"/>|" \
      -e "s|ProductVersion=\"[^\"]*\"|ProductVersion=\"$RELEASE+$BTW_BUILD\"|" \
      "$lpi" > "$copy"
  TEMP_LPIS+=("$copy")
  echo "$copy"
}

for lpi in "$@"; do
  echo "== $lpi"
  build=$lpi
  if grep -q '<VersionInfo>' "$lpi"; then
    build=$(versioned_lpi "$lpi")
  fi
  if ! "$LAZBUILD" -q "${TARGET_ARGS[@]}" "$build" > "lib/build.log" 2>&1; then
    grep -E '(Error|Fatal):' lib/build.log >&2 || cat lib/build.log >&2
    exit 1
  fi
done

if [[ $RUN_TESTS -eq 1 ]]; then
  echo "== tests"
  ./bin/TestCore | tail -1
fi
