#!/bin/bash
# make-dmg.sh <OpenNotch.app> <out.dmg> — a drag-to-Applications disk image (hdiutil only).
set -euo pipefail
APP="$1"; OUT="$2"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "OpenNotch" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "DMG: $OUT"
