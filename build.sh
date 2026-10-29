#!/usr/bin/env bash
# Build BTT Workbench with lazbuild.
#
#   ./build.sh            tests, CLI, shared library and GUI, then run tests
#   ./build.sh <x.lpi>... just those projects
#   ./build.sh --win64 [<x.lpi>...]
#                         Windows 64-bit .exe files (default: CLI and GUI);
#                         needs FPC's win64 units
#   ./build.sh --universal [<x.lpi>...]
#                         macOS only: build for aarch64 and x86_64 and join
#                         them with lipo (default: tests, CLI and GUI), then
#                         run the tests natively and under Rosetta; needs
#                         the x86_64-darwin cross-compiler
#
# On macOS the GUI is also put in an app bundle, bin/BTT Workbench.app
# (icon src/gui/BttWorkbench.icns, translations in Contents/Resources,
# .tstudio as a document type), signed ad hoc. The shared library
# (src/lib, for Android) is not built there, and
# MACOSX_DEPLOYMENT_TARGET defaults to 11.0. fpcupdeluxe's fpc.cfg gives
# native builds -WM10.15, which wins over it: so the arm64 slice says 10.15
# (arm64 Macs all run 11 or later) and the x86_64 slice 11.0. Do not force
# -WM11.0 on arm64: Apple's ld 1167 crashes linking the GUI with it. The script runs under the
# system bash 3.2 and BSD sed.
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
# PATH is reset to the FPC bin dir for this host (e.g. x86_64-linux,
# aarch64-darwin) + /usr/bin:/bin: a linuxbrew ld earlier on PATH breaks FPC
# links.

set -euo pipefail
cd "$(dirname "$0")"

LAZ_ROOT="${LAZ_ROOT:-$HOME/fpcupdeluxe}"
LAZBUILD="${LAZBUILD:-$LAZ_ROOT/lazarus/lazbuild}"
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
HOST_CPU=$(uname -m)
[[ $HOST_CPU == arm64 ]] && HOST_CPU=aarch64
export PATH="$LAZ_ROOT/fpc/bin/$HOST_CPU-$HOST_OS:/usr/bin:/bin"
if [[ $HOST_OS == darwin ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
fi

if [[ ! -x "$LAZBUILD" ]]; then
  echo "error: lazbuild not found at $LAZBUILD (set LAZ_ROOT or LAZBUILD)" >&2
  exit 1
fi

WIN64=0
UNIVERSAL=0
if [[ "${1:-}" == "--win64" ]]; then
  WIN64=1
  shift
elif [[ "${1:-}" == "--universal" ]]; then
  if [[ $HOST_OS != darwin ]]; then
    echo "error: --universal is for macOS" >&2
    exit 2
  fi
  UNIVERSAL=1
  shift
fi

RUN_TESTS=0
if [[ $# -eq 0 ]]; then
  if [[ $WIN64 -eq 1 ]]; then
    set -- src/cli/btw.lpi src/gui/BttWorkbench.lpi
  elif [[ $HOST_OS == darwin ]]; then
    set -- tests/TestCore.lpi src/cli/btw.lpi src/gui/BttWorkbench.lpi
    RUN_TESTS=1
  else
    set -- tests/TestCore.lpi src/cli/btw.lpi src/lib/btw.lpi src/gui/BttWorkbench.lpi
    RUN_TESTS=1
  fi
fi

# Each CPU to build for; empty means lazbuild's default (the host's)
CPUS=("")
if [[ $UNIVERSAL -eq 1 ]]; then
  CPUS=(aarch64 x86_64)
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
  # ${a[@]+...}: bash 3.2 (macOS) treats an empty array as unset under set -u
  for f in ${TEMP_LPIS[@]+"${TEMP_LPIS[@]}"}; do
    rm -f "$f" "${f%.lpi}.lps" "${f%.lpi}.ico"
  done
}
trap cleanup EXIT

# A copy of the .lpi with the version numbers filled in, beside it.
versioned_lpi() {
  local lpi=$1 major minor rev copy
  IFS=. read -r major minor rev <<< "$RELEASE"
  copy="$(dirname "$lpi")/.$(basename "$lpi" .lpi)-build.lpi"
  sed -e '/<MajorVersionNr/d' -e '/<MinorVersionNr/d' \
      -e '/<RevisionNr/d' -e '/<BuildNr/d' \
      -e "s|<UseVersionInfo Value=\"True\"/>|<UseVersionInfo Value=\"True\"/><MajorVersionNr Value=\"$major\"/><MinorVersionNr Value=\"$minor\"/><RevisionNr Value=\"$rev\"/><BuildNr Value=\"$BTW_BUILD\"/>|" \
      -e "s|ProductVersion=\"[^\"]*\"|ProductVersion=\"$RELEASE+$BTW_BUILD\"|" \
      "$lpi" > "$copy"
  # lazbuild takes the program icon from the .ico named like the .lpi
  [[ -f "${lpi%.lpi}.ico" ]] && cp "${lpi%.lpi}.ico" "${copy%.lpi}.ico"
  TEMP_LPIS+=("$copy")
  echo "$copy"
}

# bin/BTT Workbench.app around the GUI program $1 (already built)
make_app() {
  local exe=$1 app="bin/BTT Workbench.app" po
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$exe" "$app/Contents/MacOS/btt-workbench"
  cp src/gui/BttWorkbench.icns "$app/Contents/Resources/"
  for po in locale/*/btt-workbench.po; do
    [[ -e "$po" ]] || continue
    mkdir -p "$app/Contents/Resources/$(dirname "$po")"
    cp "$po" "$app/Contents/Resources/$po"
  done
  printf 'APPL????' > "$app/Contents/PkgInfo"
  # CFBundleVersion must be numbers: the build; Finder shows "0.2.0 (51)"
  # NSPrincipalClass must be LCL's TCocoaApplication: LCL makes NSApp from
  # it, and a plain NSApplication never runs TThread.Synchronize or queued
  # calls (the GUI hung on "Working..." until a mouse event)
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>btt-workbench</string>
  <key>CFBundleIdentifier</key><string>org.wycliffeassociates.btt-workbench</string>
  <key>CFBundleName</key><string>BTT Workbench</string>
  <key>CFBundleDisplayName</key><string>BTT Workbench</string>
  <key>CFBundleIconFile</key><string>BttWorkbench</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$RELEASE</string>
  <key>CFBundleVersion</key><string>$BTW_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MACOSX_DEPLOYMENT_TARGET</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>TCocoaApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>BTT-Writer project package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key>
      <array><string>org.wycliffeassociates.tstudio</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.wycliffeassociates.tstudio</string>
      <key>UTTypeDescription</key><string>BTT-Writer project package</string>
      <key>UTTypeConformsTo</key>
      <array><string>public.zip-archive</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>tstudio</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
  plutil -lint -s "$app/Contents/Info.plist"
  codesign --force -s - "$app" 2> /dev/null
  echo "$app"
}

# The program a project makes: <Target><Filename>, relative to the .lpi
target_of() {
  local lpi=$1 target
  target=$(sed -n '/<Target>/,/<\/Target>/s|.*<Filename Value="\([^"]*\)".*|\1|p' "$lpi")
  echo "$(dirname "$lpi")/$target"
}

for lpi in "$@"; do
  build=$lpi
  if grep -q '<VersionInfo>' "$lpi"; then
    build=$(versioned_lpi "$lpi")
  fi
  for cpu in "${CPUS[@]}"; do
    args=(${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"})
    if [[ -n $cpu ]]; then
      echo "== $lpi ($cpu)"
      args+=(--cpu="$cpu")
    else
      echo "== $lpi"
    fi
    if ! "$LAZBUILD" -q ${args[@]+"${args[@]}"} "$build" > "lib/build.log" 2>&1; then
      grep -E '(Error|Fatal):' lib/build.log >&2 || cat lib/build.log >&2
      exit 1
    fi
    if [[ $UNIVERSAL -eq 1 ]]; then
      mkdir -p "lib/$cpu-darwin"
      mv -f "$(target_of "$lpi")" "lib/$cpu-darwin/"
    fi
  done
  if [[ $UNIVERSAL -eq 1 ]]; then
    exe=$(target_of "$lpi")
    name=$(basename "$exe")
    lipo -create -output "$exe" "lib/aarch64-darwin/$name" "lib/x86_64-darwin/$name"
    lipo -info "$exe"
  fi
  if [[ $HOST_OS == darwin && $(basename "$lpi") == BttWorkbench.lpi ]]; then
    make_app "$(target_of "$lpi")"
  fi
done

if [[ $RUN_TESTS -eq 1 ]]; then
  if [[ $UNIVERSAL -eq 1 ]]; then
    echo "== tests (aarch64)"
    arch -arm64 ./bin/TestCore | tail -1
    echo "== tests (x86_64, Rosetta)"
    arch -x86_64 ./bin/TestCore | tail -1
  else
    echo "== tests"
    ./bin/TestCore | tail -1
  fi
fi
