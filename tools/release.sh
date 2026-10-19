#!/usr/bin/env bash
# Build a release of BTT Workbench: Linux and Windows programs, stripped
# and packed under the version name in dist/:
#
#   dist/btt-workbench-<version>-linux-x86_64.tar.gz   btt-workbench, btw
#   dist/btt-workbench-<version>-win64.zip             btt-workbench.exe, btw.exe
#
# each with README.md, CHANGELOG.md, LICENSE and the translations
# (locale/*/*.po). The version is <release>+<build> (see build.sh). A
# release is built from committed work only; --allow-modified overrides
# that for a trial.
#
#   tools/release.sh [--allow-modified]

set -euo pipefail
cd "$(dirname "$0")/.."

ALLOW_MODIFIED=0
[[ "${1:-}" == "--allow-modified" ]] && ALLOW_MODIFIED=1

if [[ $ALLOW_MODIFIED -eq 0 ]] && ! git diff --quiet HEAD --; then
  echo "error: uncommitted changes; commit them first (or --allow-modified for a trial)" >&2
  exit 1
fi

./build.sh                # Linux: tests, CLI, library, GUI
./build.sh --win64        # Windows: CLI and GUI

VERSION=$(cut -d' ' -f1 lib/version.stamp)
COMMIT=$(cut -d' ' -f2 lib/version.stamp)
NAME="btt-workbench-$VERSION"
mkdir -p dist

# $1: folder name, then the programs to put in it
stage() {
  local dir="dist/$1" f po
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  for f in "$@"; do
    cp "bin/$f" "$dir/"
    strip "$dir/$f"
  done
  cp README.md CHANGELOG.md LICENSE "$dir/"
  for po in locale/*/btt-workbench.po; do
    [[ -e "$po" ]] || continue
    mkdir -p "$dir/$(dirname "$po")"
    cp "$po" "$dir/$po"
  done
}

LINUX="$NAME-linux-x86_64"
WINDOWS="$NAME-win64"
stage "$LINUX" btt-workbench btw
stage "$WINDOWS" btt-workbench.exe btw.exe
rm -f "dist/$LINUX.tar.gz" "dist/$WINDOWS.zip"
tar -C dist -czf "dist/$LINUX.tar.gz" "$LINUX"
(cd dist && zip -qr "$WINDOWS.zip" "$WINDOWS")
rm -rf "dist/$LINUX" "dist/$WINDOWS"

echo
echo "Release $VERSION ($COMMIT):"
(cd dist && sha256sum "$LINUX.tar.gz" "$WINDOWS.zip" | tee "$NAME.sha256")
echo
echo "To mark it in git:  git tag -a v${VERSION%%+*} -m \"BTT Workbench $VERSION\" && git push origin v${VERSION%%+*}"
