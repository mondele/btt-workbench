#!/usr/bin/env bash
# Regenerate locale/btt-workbench.pot from the .rsj files lazbuild writes
# for every unit with resourcestrings. Run ./build.sh first.
#
# Usage: tools/extract-pot.sh [LIB_DIR] [OUT_POT]
#   LIB_DIR defaults to lib/x86_64-linux (all of cli/, gui/, tests/, libbtw/)
#   OUT_POT defaults to locale/btt-workbench.pot
#
# Needs rstconv (ships with FPC) and msguniq/msgcat (gettext).
# To start or update a translation:
#   mkdir -p locale/fr && msginit -i locale/btt-workbench.pot -o locale/fr/btt-workbench.po -l fr
#   msgmerge -U locale/fr/btt-workbench.po locale/btt-workbench.pot

set -euo pipefail
cd "$(dirname "$0")/.."

LIB_DIR="${1:-lib/x86_64-linux}"
OUT_POT="${2:-locale/btt-workbench.pot}"
LAZ_ROOT="${LAZ_ROOT:-$HOME/fpcupdeluxe}"
RSTCONV="$(command -v rstconv || echo "$LAZ_ROOT/fpc/bin/x86_64-linux/rstconv")"

if [[ ! -d "$LIB_DIR" ]]; then
  echo "error: $LIB_DIR not found; run ./build.sh first" >&2
  exit 1
fi

# One .rsj per unit; the same unit is compiled into several targets, so
# keep the first copy of each.
declare -A SEEN
RSJ_FILES=()
while IFS= read -r -d '' f; do
  unit=$(basename "$f" .rsj)
  [[ -n "${SEEN[$unit]:-}" ]] && continue
  SEEN[$unit]=1
  RSJ_FILES+=("$f")
done < <(find "$LIB_DIR" -name '*.rsj' -print0 | sort -z)

if [[ ${#RSJ_FILES[@]} -eq 0 ]]; then
  echo "error: no .rsj files under $LIB_DIR" >&2
  exit 1
fi

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/raw" "$TMPD/unit"
for rsj in "${RSJ_FILES[@]}"; do
  unit=$(basename "$rsj" .rsj)
  "$RSTCONV" -i "$rsj" -o "$TMPD/raw/$unit.po" -f po -c utf-8 >/dev/null
  # The same English text can appear under two keys in one unit; msgcat
  # refuses duplicates, so collapse each unit first.
  msguniq --use-first "$TMPD/raw/$unit.po" -o "$TMPD/unit/$unit.po"
done

mkdir -p "$(dirname "$OUT_POT")"
msgcat --use-first "$TMPD"/unit/*.po \
  | sed -e 's/^"Language: .*$/"Language: \\n"/' \
        -e '1,/^$/s|^"Project-Id-Version: .*$|"Project-Id-Version: btt-workbench\\n"|' \
  > "$OUT_POT"

COUNT=$(grep -c '^msgid "' "$OUT_POT" || true)
echo "wrote $OUT_POT ($((COUNT - 1)) strings from ${#RSJ_FILES[@]} units)"
