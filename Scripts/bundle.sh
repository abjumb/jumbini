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

# Sparkle framework, if SwiftPM downloaded it. Embedded into Contents/Frameworks
# with ditto (not cp) so the framework's internal symlinks — Resources, Headers,
# XPCServices, Autoupdate — survive the copy. The Autoupdate helper and the XPC
# services live inside the framework, so there is nothing else to copy.
#
# The app links Sparkle via @rpath/Sparkle.framework/Versions/B/Sparkle, so the
# executable needs a runpath pointing at Contents/Frameworks. SwiftPM already
# embedded its own .build/... rpath; this one is what makes the shipped bundle
# self-contained.
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP/Contents/MacOS/Jumbini"
fi

# Ad-hoc sign so macOS is happy running it locally. The Sparkle framework is
# already ad-hoc signed by Sparkle, so it needs no treatment for a local run.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP — launch with: open $APP"
