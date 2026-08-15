#!/bin/bash
# Generate the Sparkle appcast (and delta updates) from the DMG(s) in build/.
#
# Sparkle signs every update archive with an EdDSA (ed25519) key. The public
# half lives in Scripts/Info.plist as SUPublicEDKey; this script signs with the
# private half, which it looks up in order of preference:
#
#   1. $SPARKLE_ED25519_KEY       the base64 seed, e.g. from a GitHub secret
#   2. .sparkle-ed25519-key       the file written by the key-generation step
#   3. your login keychain        (Sparkle's own default; what generate_keys uses)
#
# Usage:
#   ./Scripts/appcast.sh                      # appcast for build/Jumbini.dmg
#   SPARKLE_ED25519_KEY=... ./Scripts/appcast.sh
#   ./Scripts/appcast.sh /path/to/updates     # appcast for a whole folder
#
# The output (appcast.xml + *.delta files) lands alongside the archives and is
# what you upload to wherever SUFeedURL points. See SIGNING.md.

set -euo pipefail
cd "$(dirname "$0")/.."

SRC_DIR="${1:-build}"
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://abjumb.github.io/jumbini}"

# The tools ship inside SwiftPM's Sparkle binary artifact. Make sure it exists
# (this also guarantees the version the app links against is the one signing).
swift package resolve >/dev/null
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
  echo "error: generate_appcast not found at $GENERATE_APPCAST" >&2
  exit 1
fi

[ -d "$SRC_DIR" ] || { echo "error: no such directory: $SRC_DIR" >&2; exit 1; }

echo "==> Generating appcast for $SRC_DIR"

if [ -n "${SPARKLE_ED25519_KEY:-}" ]; then
  # The key arrives on stdin because that keeps it off the process list and out
  # of the command line. `--ed-key-file -` reads a single line from stdin.
  printf '%s\n' "$SPARKLE_ED25519_KEY" \
    | "$GENERATE_APPCAST" --ed-key-file - --download-url-prefix "$DOWNLOAD_PREFIX" "$SRC_DIR"
elif [ -f ".sparkle-ed25519-key" ]; then
  "$GENERATE_APPCAST" --ed-key-file ".sparkle-ed25519-key" \
    --download-url-prefix "$DOWNLOAD_PREFIX" "$SRC_DIR"
else
  # Falls back to the login keychain, the same place generate_keys puts the
  # private key. Requires an interactive keychain prompt on first use.
  echo "    (no SPARKLE_ED25519_KEY or .sparkle-ed25519-key; using the login keychain)"
  "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_PREFIX" "$SRC_DIR"
fi

echo
echo "Upload appcast.xml (and the .delta files) from $SRC_DIR to the host"
echo "that SUFeedURL points at, then upload the DMG(s) too."
