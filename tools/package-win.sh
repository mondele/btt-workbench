#!/usr/bin/env bash
# Make the Windows installer from the win64 build in bin/:
#
#   dist/btt-workbench-<version>-win64-setup.exe
#
# (installer/btt-workbench.nsi says what it installs.)
#
#   tools/package-win.sh   (after ./build.sh --win64; tools/release.sh calls it)
#
# Needs makensis (apt install nsis).

set -euo pipefail
cd "$(dirname "$0")/.."
umask 022

for f in bin/btt-workbench.exe bin/btw.exe lib/version.stamp; do
  [[ -e "$f" ]] || { echo "error: $f not found; run ./build.sh --win64 first" >&2; exit 1; }
done
command -v makensis >/dev/null ||
  { echo "error: makensis not found (apt install nsis)" >&2; exit 1; }

VERSION=$(cut -d' ' -f1 lib/version.stamp)
# Windows wants four numbers: 0.2.0+51 -> 0.2.0.51
VERSION4="${VERSION%%+*}.${VERSION##*+}"
OUT="$PWD/dist/btt-workbench-$VERSION-win64-setup.exe"
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT

for f in btt-workbench.exe btw.exe; do
  cp "bin/$f" "$SRC/"
  strip "$SRC/$f"
done
cp README.md CHANGELOG.md LICENSE "$SRC/"
for po in locale/*/btt-workbench.po; do
  [[ -e "$po" ]] || continue
  install -D -m 644 "$po" "$SRC/$po"
done

mkdir -p dist
rm -f "$OUT"
makensis -V2 -DVERSION="$VERSION" -DVERSION4="$VERSION4" -DSRC="$SRC" \
  -DOUTFILE="$OUT" installer/btt-workbench.nsi
echo "dist/$(basename "$OUT")"
