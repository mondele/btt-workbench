#!/usr/bin/env bash
# Build a release of BTT Workbench: Linux and Windows programs, stripped
# and packed under the version name in dist/:
#
#   dist/btt-workbench-<version>-linux-x86_64.tar.gz   btt-workbench, btw
#   dist/btt-workbench-<version>-win64.zip             btt-workbench.exe, btw.exe
#
# each with README.md, CHANGELOG.md, LICENSE and the translations
# (locale/*/*.po), and the installers made from the same files:
#
#   dist/btt-workbench_<version>_amd64.deb             tools/package-deb.sh
#   dist/btt-workbench-<version>-win64-setup.exe       tools/package-win.sh
#
# On macOS it makes instead
#
#   dist/btt-workbench-<version>-macos.dmg             BTT Workbench.app
#
# a disk image with the universal app (btw inside it, in Contents/MacOS),
# a link to Applications to drag it onto, README.md, CHANGELOG.md, LICENSE
# and a note on opening an app that is not notarized. The version is
# <release>+<build> (see build.sh). A release is built from committed work
# only; --allow-modified overrides that for a trial.
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

if [[ $(uname -s) == Darwin ]]; then
  ./build.sh --universal  # tests (both CPUs), CLI, GUI and the app bundle
  VERSION=$(cut -d' ' -f1 lib/version.stamp)
  COMMIT=$(cut -d' ' -f2 lib/version.stamp)
  NAME="btt-workbench-$VERSION-macos"
  APP="BTT Workbench.app"
  STAGE="dist/$NAME"
  mkdir -p dist
  rm -rf "$STAGE" "dist/$NAME.dmg"
  mkdir -p "$STAGE"
  cp -R "bin/$APP" "$STAGE/"
  cp bin/btw "$STAGE/$APP/Contents/MacOS/btw"
  # strip both, then sign again: stripping breaks the (ad hoc) signature
  strip "$STAGE/$APP/Contents/MacOS/btt-workbench" "$STAGE/$APP/Contents/MacOS/btw" \
    2> >(grep -v 'invalidate the code signature' >&2)
  codesign --force -s - "$STAGE/$APP/Contents/MacOS/btw" 2> /dev/null
  codesign --force -s - "$STAGE/$APP" 2> /dev/null
  codesign --verify --strict "$STAGE/$APP"
  ln -s /Applications "$STAGE/Applications"
  cp README.md CHANGELOG.md LICENSE "$STAGE/"
  cat > "$STAGE/Read me first.txt" <<'TXT'
BTT Workbench for macOS (Apple Silicon and Intel, macOS 11 or later)

Install: drag BTT Workbench onto Applications.

The app is not notarized by Apple, so the first time macOS will refuse to
open it ("cannot be opened" or "could not verify"). To open it anyway:

  1. Open BTT Workbench once and close the message.
  2. Open System Settings > Privacy & Security, scroll down, and click
     "Open Anyway" next to BTT Workbench. Confirm with your password.

Or, in Terminal:

  xattr -dr com.apple.quarantine "/Applications/BTT Workbench.app"

After that it opens normally. Double-clicking a .tstudio file opens it in
BTT Workbench's import, which checks it first; nothing changes until you
press Run.

The command-line program, btw, is inside the app. To use it in Terminal:

  sudo mkdir -p /usr/local/bin
  sudo ln -sf "/Applications/BTT Workbench.app/Contents/MacOS/btw" /usr/local/bin/btw

BTT Workbench needs git, which macOS offers to install (with the Xcode
Command Line Tools) the first time git is used, or: xcode-select --install
TXT
  hdiutil create -quiet -volname "BTT Workbench ${VERSION%%+*}" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "dist/$NAME.dmg"
  rm -rf "$STAGE"
  echo
  echo "Release $VERSION ($COMMIT):"
  (cd dist && shasum -a 256 "$NAME.dmg" | tee "$NAME.sha256")
  echo
  echo "To mark it in git:  git tag -a v${VERSION%%+*} -m \"BTT Workbench $VERSION\" && git push origin v${VERSION%%+*}"
  exit 0
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

DEB=$(tools/package-deb.sh)
SETUP=$(tools/package-win.sh)

echo
echo "Release $VERSION ($COMMIT):"
(cd dist && sha256sum "$LINUX.tar.gz" "$WINDOWS.zip" "$(basename "$DEB")" \
  "$(basename "$SETUP")" | tee "$NAME.sha256")
echo
echo "To mark it in git:  git tag -a v${VERSION%%+*} -m \"BTT Workbench $VERSION\" && git push origin v${VERSION%%+*}"
