#!/usr/bin/env bash
# Make the macOS app icon, src/gui/BttWorkbench.icns, from btt-wb-icon.svg
# (the same drawing as the Windows .ico files). macOS only: sips renders
# the SVG at each size (it keeps the transparency) and iconutil packs
# them. The .icns is committed, so builds do not need this; run it again
# after changing the SVG.
#
#   tools/make-icns.sh

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $(uname -s) != Darwin ]]; then
  echo "error: needs macOS (sips and iconutil)" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/BttWorkbench.iconset"
mkdir "$SET"

# name size: each size rendered from the drawing, not scaled down
for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 \
            128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  name=${spec%%:*}
  size=${spec##*:}
  sips -s format png -z "$size" "$size" btt-wb-icon.svg --out "$SET/icon_$name.png" > /dev/null
done

iconutil -c icns -o src/gui/BttWorkbench.icns "$SET"
echo "src/gui/BttWorkbench.icns"
