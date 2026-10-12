#!/usr/bin/env bash
# Build BTT Workbench with lazbuild.
#
#   ./build.sh            tests, CLI, shared library and GUI, then run tests
#   ./build.sh <x.lpi>... just those projects
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

RUN_TESTS=0
if [[ $# -eq 0 ]]; then
  set -- tests/TestCore.lpi src/cli/btw.lpi src/lib/btw.lpi src/gui/BttWorkbench.lpi
  RUN_TESTS=1
fi

mkdir -p lib
WS_ARG=()
[[ -n "${LCL_WS:-}" ]] && WS_ARG=(--ws="$LCL_WS")

for lpi in "$@"; do
  echo "== $lpi"
  if ! "$LAZBUILD" -q "${WS_ARG[@]}" "$lpi" > "lib/build.log" 2>&1; then
    grep -E '(Error|Fatal):' lib/build.log >&2 || cat lib/build.log >&2
    exit 1
  fi
done

if [[ $RUN_TESTS -eq 1 ]]; then
  echo "== tests"
  ./bin/TestCore | tail -1
fi
