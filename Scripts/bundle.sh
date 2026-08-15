#!/bin/bash
# Build the release binary and assemble Jumbini.app (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Jumbini.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Jumbini "$APP/Contents/MacOS/Jumbini"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

# App icon (Finder / Dock / DMG).
if [ -f "icon/jumbini-cream.icns" ]; then
  cp icon/jumbini-cream.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM resource bundle (sprites), if present.
if [ -d ".build/release/Jumbini_Jumbini.bundle" ]; then
  cp -R ".build/release/Jumbini_Jumbini.bundle" "$APP/Contents/Resources/"
fi

# Ad-hoc sign so macOS is happy running it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP — launch with: open $APP"
