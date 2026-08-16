#!/bin/bash
# The six landing-page stills. Three are rendered offline from the sprite art;
# three are screenshots of live UI and need the app running.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${JUMBINI_DEMO_OUT:-$ROOT/demo-assets/stills}"
FILM=(swift run --package-path "$HERE/spritefilm" spritefilm)

mkdir -p "$OUT"
cd "$ROOT"

echo "stills: hero"
"${FILM[@]}" still --pose idle --facing south --scale 6 --out "$OUT/hero@2x.png"

echo "stills: rotations contact sheet"
"${FILM[@]}" contact --pose idle --scale 3 --out "$OUT/rotations.png"

echo "stills: coats, side by side"
"${FILM[@]}" pair --pose idle --facing south --coat classic --coat2 shaggy \
  --scale 5 --out "$OUT/coats.png"

echo
echo "stills: the remaining three are screenshots of live UI and cannot be rendered."
echo "stills: with Jumbini running:"
echo "stills:   1. wardrobe.png  — open the Wardrobe menu, then: screencapture -iw $OUT/wardrobe.png"
echo "stills:   2. menubar.png   — open the menu bar menu, then: screencapture -iw $OUT/menubar.png"
echo "stills:   3. jumbini-cam.png — press ⌥⇧J, then paste the clipboard into Preview and save"
echo "stills: done. Offline stills are in $OUT"
