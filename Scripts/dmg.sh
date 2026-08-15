#!/bin/bash
# Package Jumbini.app into a distributable DMG (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh

STAGE="build/dmg-stage"
DMG="build/Jumbini.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Jumbini.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Jumbini" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG"
