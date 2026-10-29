#!/usr/bin/env bash
# Make a Debian package of the Linux build in bin/:
#
#   dist/btt-workbench_<version>_amd64.deb
#
# Installs the programs to /opt/btt-workbench (with README, CHANGELOG,
# LICENSE and the translations beside them, where WBI18n looks), links
# btt-workbench and btw into /usr/bin, and adds a menu entry, the icon and
# the .tstudio file type (double-click opens the import check). The
# system's dpkg triggers refresh the menu, icon and MIME caches, so the
# package has no maintainer scripts.
#
#   tools/package-deb.sh      (after ./build.sh; tools/release.sh calls it)
#
# Needs dpkg-deb and rsvg-convert (librsvg2-bin).

set -euo pipefail
cd "$(dirname "$0")/.."
umask 022

for f in bin/btt-workbench bin/btw lib/version.stamp; do
  [[ -e "$f" ]] || { echo "error: $f not found; run ./build.sh first" >&2; exit 1; }
done
command -v rsvg-convert >/dev/null ||
  { echo "error: rsvg-convert not found (apt install librsvg2-bin)" >&2; exit 1; }

VERSION=$(cut -d' ' -f1 lib/version.stamp)
PKG=btt-workbench
DEB="dist/${PKG}_${VERSION}_amd64.deb"
ROOT=$(mktemp -d)
chmod 755 "$ROOT"
trap 'rm -rf "$ROOT"' EXIT

OPT="$ROOT/opt/$PKG"
SHARE="$ROOT/usr/share"
mkdir -p "$OPT" "$ROOT/usr/bin" "$SHARE/applications" "$SHARE/mime/packages" \
  "$SHARE/doc/$PKG" "$SHARE/icons/hicolor/scalable/apps" "$ROOT/DEBIAN"

for f in btt-workbench btw; do
  install -m 755 "bin/$f" "$OPT/$f"
  strip "$OPT/$f"
  ln -s "/opt/$PKG/$f" "$ROOT/usr/bin/$f"
done
install -m 644 README.md CHANGELOG.md LICENSE "$OPT/"
for po in locale/*/btt-workbench.po; do
  [[ -e "$po" ]] || continue
  install -D -m 644 "$po" "$OPT/$po"
done

install -m 644 btt-wb-icon.svg "$SHARE/icons/hicolor/scalable/apps/$PKG.svg"
for size in 16 24 32 48 64 128 256; do
  dir="$SHARE/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$dir"
  rsvg-convert -w "$size" -h "$size" btt-wb-icon.svg -o "$dir/$PKG.png"
done

# Two entries: the menu one starts the program plainly; the hidden one
# takes double-clicked .tstudio files to the import check.
cat > "$SHARE/applications/$PKG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BTT Workbench
Comment=Technician's toolbox for BTT-Writer projects
Exec=/opt/$PKG/btt-workbench
Icon=$PKG
Terminal=false
Categories=Utility;
EOF
cat > "$SHARE/applications/$PKG-tstudio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BTT Workbench: import .tstudio
Comment=Import BTT-Writer project packages
Exec=/opt/$PKG/btt-workbench tstudio-import %F
Icon=$PKG
Terminal=false
NoDisplay=true
MimeType=application/x-tstudio;
EOF
cat > "$SHARE/mime/packages/$PKG-tstudio.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-tstudio">
    <comment>BTT-Writer project package</comment>
    <sub-class-of type="application/zip"/>
    <glob pattern="*.tstudio" weight="60"/>
  </mime-type>
</mime-info>
EOF

cat > "$SHARE/doc/$PKG/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: BTT Workbench
Source: https://github.com/mondele/btt-workbench

Files: *
License: MIT
$(sed 's/^$/./; s/^/ /' LICENSE)
EOF

# The t64 library packages of Ubuntu 24.04 and Debian 13 provide the old
# names, so these also install on Ubuntu 22.04 and Debian 12.
cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: amd64
Maintainer: John Wood <john_wood@wycliffeassociates.org>
Installed-Size: $(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)
Depends: git (>= 1:2.38), libgtk2.0-0, libsqlite3-0, libssl3
Section: utils
Priority: optional
Homepage: https://github.com/mondele/btt-workbench
Description: Technician's toolbox for BTT-Writer projects
 Checks, repairs, imports and uploads BTT-Writer translation projects:
 text checks, chunking and language problems, text copied between books,
 .tstudio import, WACS download and upload, and library updates.
 The desktop program is btt-workbench; the same tools run on the command
 line as btw.
EOF

mkdir -p dist
rm -f "$DEB"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB" >/dev/null
echo "$DEB"
