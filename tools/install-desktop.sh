#!/usr/bin/env bash
# Register BTT Workbench with the Linux desktop for the current user:
# a .tstudio file type (application/x-tstudio) and a launcher, so that
# double-clicking a .tstudio opens btt-workbench on the import check.
#
#   tools/install-desktop.sh            use this checkout's bin/btt-workbench
#   tools/install-desktop.sh /path/bin  use an installed binary instead
#   tools/install-desktop.sh --remove   undo
#
# Writes only under ~/.local/share (no sudo). BTT-Writer itself registers
# no MIME type for .tstudio and ignores files passed to it, so nothing of
# BTT-Writer's is replaced.

set -euo pipefail

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
MIME_XML="$DATA/mime/packages/btt-workbench-tstudio.xml"
DESKTOP="$DATA/applications/btt-workbench.desktop"
MIME_TYPE="application/x-tstudio"

refresh() {
  update-mime-database "$DATA/mime" >/dev/null 2>&1 || true
  update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$MIME_XML" "$DESKTOP"
  refresh
  echo "removed $MIME_XML and $DESKTOP"
  exit 0
fi

BIN_DIR="${1:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || true)}"
EXE="$BIN_DIR/btt-workbench"
if [[ ! -x "$EXE" ]]; then
  echo "error: $EXE not found; run ./build.sh first or pass the bin dir" >&2
  exit 1
fi

mkdir -p "$(dirname "$MIME_XML")" "$(dirname "$DESKTOP")"

cat > "$MIME_XML" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="$MIME_TYPE">
    <comment>BTT-Writer project package</comment>
    <sub-class-of type="application/zip"/>
    <glob pattern="*.tstudio" weight="60"/>
  </mime-type>
</mime-info>
EOF

# Exec quoting per the Desktop Entry spec: the path is quoted, %f is the file.
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=BTT Workbench
Comment=Technician's toolbox for BTT-Writer projects
Exec="$EXE" tstudio-import %F
TryExec=$EXE
Terminal=false
Categories=Utility;
MimeType=$MIME_TYPE;
EOF

refresh
xdg-mime default btt-workbench.desktop "$MIME_TYPE"

echo "registered $MIME_TYPE -> $EXE"
echo "default for .tstudio: $(xdg-mime query default "$MIME_TYPE")"
