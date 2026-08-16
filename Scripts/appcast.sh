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
# The URL the DMGs are advertised at comes from SUFeedURL in Scripts/Info.plist
# (its directory), so hosting moves with that one value. Override it for a
# one-off publish elsewhere with SPARKLE_DOWNLOAD_URL_PREFIX; a trailing slash
# is added for you either way, because its absence silently breaks every
# download (see the note above DOWNLOAD_PREFIX).
#
# The output (appcast.xml + *.delta files) lands alongside the archives and is
# what you upload to wherever SUFeedURL points. See SIGNING.md.

set -euo pipefail
cd "$(dirname "$0")/.."

SRC_DIR="${1:-build}"
INFO_PLIST="Scripts/Info.plist"

# Where the DMGs are downloaded from is not an independent fact: the archives
# sit next to appcast.xml, so the prefix is just SUFeedURL with the filename
# taken off. Deriving it means the two can never drift, and it makes the
# promise in SIGNING.md true — changing SUFeedURL really does move both.
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" 2>/dev/null || true)"
case "$FEED_URL" in
  https://*/*) ;;
  *) echo "error: could not read a usable SUFeedURL from $INFO_PLIST (got '${FEED_URL:-}')" >&2
     exit 1 ;;
esac

# The trailing slash is load-bearing. generate_appcast resolves each archive
# name *relative to* this prefix, so ".../jumbini" + "Jumbini-4.2.dmg" resolves
# to ".../Jumbini-4.2.dmg" — the last path segment is replaced rather than
# appended to, and every download 404s. Verified against generate_appcast:
# without the slash it emits https://abjumb.github.io/Jumbini-4.2.dmg (404),
# with it https://abjumb.github.io/jumbini/Jumbini-4.2.dmg (200).
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-${FEED_URL%/*}}"
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX%/}/"

if [ -n "${SPARKLE_DOWNLOAD_URL_PREFIX:-}" ]; then
  echo "==> Download prefix overridden: $DOWNLOAD_PREFIX"
else
  echo "==> Download prefix from SUFeedURL: $DOWNLOAD_PREFIX"
fi

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

APPCAST="$SRC_DIR/appcast.xml"
[ -f "$APPCAST" ] || { echo "error: generate_appcast wrote no $APPCAST" >&2; exit 1; }

# Nothing above proves the feed is actually downloadable, and a wrong URL is
# silent: Sparkle finds the update, announces it, then fails to fetch it. So
# check the output rather than trusting the input. Any archive sitting in
# SRC_DIR must be pointed at by <prefix><filename>; entries written by an
# earlier, broken run are repaired here rather than carried forward.
python3 - "$APPCAST" "$SRC_DIR" "$DOWNLOAD_PREFIX" <<'PY'
import os, re, sys

appcast, src_dir, prefix = sys.argv[1], sys.argv[2], sys.argv[3]

# Everything below joins by plain concatenation, which is only correct while the
# prefix ends in a slash. Assert it rather than silently emitting ".../jumbiniX.dmg"
# if the normalisation above is ever edited away.
if not prefix.endswith("/"):
    sys.stderr.write("error: download prefix %r must end in '/'\n" % prefix)
    sys.exit(1)

with open(appcast, encoding="utf-8") as fh:
    xml = fh.read()

repaired = []

def local(url):
    return os.path.join(src_dir, url.rsplit("/", 1)[-1])

def fix(match):
    url = match.group(1)
    want = prefix + url.rsplit("/", 1)[-1]
    if url != want and os.path.exists(local(url)):
        repaired.append((url, want))
        return 'url="%s"' % want
    return match.group(0)

patched = re.sub(r'url="([^"]+)"', fix, xml)
if patched != xml:
    with open(appcast, "w", encoding="utf-8") as fh:
        fh.write(patched)

urls = re.findall(r'url="([^"]+)"', patched)
wrong = [u for u in urls if os.path.exists(local(u)) and u != prefix + u.rsplit("/", 1)[-1]]
unverifiable = [u for u in urls if not os.path.exists(local(u))]

for was, now in repaired:
    print("    repaired %s" % was)
    print("          -> %s" % now)
for u in unverifiable:
    print("    note: %s has no local archive, leaving it alone" % u)

if wrong:
    sys.stderr.write("error: appcast enclosure URLs do not match the download prefix:\n")
    for u in wrong:
        sys.stderr.write("  - %s\n    expected %s\n" % (u, prefix + u.rsplit("/", 1)[-1]))
    sys.exit(1)

print("    %d enclosure URL(s) verified against %s" % (len(urls), prefix))
PY

echo
echo "Upload appcast.xml (and the .delta files) from $SRC_DIR to the host"
echo "that SUFeedURL points at, then upload the DMG(s) too."
