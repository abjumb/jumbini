#!/bin/bash
# Build, Developer ID sign, notarize and staple Jumbini.dmg.
#
# This is the script that produces a DMG a stranger can double-click. The
# unsigned path (bundle.sh / dmg.sh) still exists for local iteration; this one
# is for releases and it requires an Apple Developer Program membership.
#
# Required environment:
#   SIGN_IDENTITY         "Developer ID Application: Your Name (TEAMID)"
#   APPLE_API_KEY_PATH    path to the App Store Connect .p8 private key
#   APPLE_API_KEY_ID      the key's ID (10 chars)
#   APPLE_API_ISSUER_ID   the issuer UUID from App Store Connect
#
# See SIGNING.md for how to obtain all four.
#
# Usage:
#   ./Scripts/release.sh                 # full run: sign, notarize, staple
#   SKIP_NOTARIZE=1 ./Scripts/release.sh # sign only (fast; for testing signing)

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Jumbini.app"
DMG="build/Jumbini.dmg"
STAGE="build/dmg-stage"

# ---------------------------------------------------------------------------
# Preflight. Fail loudly and early — a half-signed DMG that silently skipped
# notarization is worse than no DMG, because it looks finished.
# ---------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this must run on macOS"
command -v codesign >/dev/null || die "codesign not found (install Xcode Command Line Tools)"
command -v xcrun    >/dev/null || die "xcrun not found (install Xcode Command Line Tools)"
xcrun notarytool --version >/dev/null 2>&1 || die "notarytool not available; update Xcode Command Line Tools"

: "${SIGN_IDENTITY:?set SIGN_IDENTITY, e.g. \"Developer ID Application: Your Name (TEAMID)\"}"

# Confirm the identity actually exists in a keychain before doing 90 seconds of
# work. `security find-identity -v -p codesigning` lists only valid ones.
# Command substitution rather than a pipe: `grep -q` exits on first match and
# would SIGPIPE `security`, which `pipefail` then reports as failure.
grep -qF "$SIGN_IDENTITY" <<<"$(security find-identity -v -p codesigning)" \
  || die "signing identity not found in keychain: $SIGN_IDENTITY
       run: security find-identity -v -p codesigning"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  : "${APPLE_API_KEY_PATH:?set APPLE_API_KEY_PATH (path to the .p8 key)}"
  : "${APPLE_API_KEY_ID:?set APPLE_API_KEY_ID}"
  : "${APPLE_API_ISSUER_ID:?set APPLE_API_ISSUER_ID}"
  [ -f "$APPLE_API_KEY_PATH" ] || die "no .p8 key at APPLE_API_KEY_PATH: $APPLE_API_KEY_PATH"

  # Check the shape of both credentials before building. notarytool only sees
  # them at the very end, so a stray character costs a full build, a signature
  # and a timestamp round trip before it surfaces -- and on a macOS runner that
  # is billed at 10x. Both of these have already shipped broken once: quotes
  # wrapped around the key ID, and a non-UUID issuer.
  #
  # Quotes are the common failure. `gh secret set APPLE_API_KEY_ID "ABC123"`
  # stores the quotes when the shell doesn't strip them, and the value becomes
  # literally "ABC123". Trim them and carry on rather than fail: the intent is
  # unambiguous, and a release should not die over a paste artifact.
  #
  # Keep the characters these two credentials are allowed to contain, rather
  # than listing the ones to strip. Both alphabets are strict -- hex, hyphens
  # and uppercase alphanumerics -- so an allowlist covers every wrapper
  # (straight quotes, smart quotes, backticks, zero-width spaces) without
  # needing to anticipate it.
  #
  # Deliberately `tr -dc` and not a bash bracket expression: in bash 3.2, which
  # is what /bin/bash still is on macOS and on GitHub's runners, a bracket
  # expression containing multibyte characters like " " is read as a byte
  # RANGE and silently deletes digits. That turned a valid issuer UUID into
  # 'a6f3e7-f4-4a4-f-f74bb' on CI while testing clean under a newer bash.
  for _var in APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
    _val="${!_var}"
    _trimmed="$(printf '%s' "$_val" | LC_ALL=C tr -dc 'A-Za-z0-9-')"
    if [ "$_trimmed" != "$_val" ]; then
      echo "    (trimmed quotes/whitespace from $_var)"
      printf -v "$_var" '%s' "$_trimmed"
    fi
    [ -n "$_trimmed" ] || die "$_var is empty after trimming quotes and whitespace"
  done

  # The issuer is a UUID; the key ID is the 10-character alphanumeric from the
  # App Store Connect key table. Anything else is a mixed-up or mangled value.
  [[ "$APPLE_API_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "APPLE_API_ISSUER_ID is not a UUID: '$APPLE_API_ISSUER_ID'
       Copy the Issuer ID from App Store Connect > Users and Access >
       Integrations > App Store Connect API (above the key table)."

  [[ "$APPLE_API_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "APPLE_API_KEY_ID does not look like a key ID: '$APPLE_API_KEY_ID'
       Expected 10 alphanumeric characters, e.g. ABCD123456 -- the 'Key ID'
       column in App Store Connect, not the issuer UUID or the filename."
fi

# ---------------------------------------------------------------------------
# 1. Build the .app  (bundle.sh ad-hoc signs it; we overwrite that below)
# ---------------------------------------------------------------------------

echo "==> Building $APP"
Scripts/bundle.sh

[ -d "$APP" ] || die "bundle.sh did not produce $APP"

# ---------------------------------------------------------------------------
# 2. Sign, inside out.
#
# Nested bundles must be signed before the bundle that contains them, because
# signing the outer one seals whatever it finds inside. --force replaces the
# ad-hoc signature bundle.sh applied.
#
#   --options runtime   hardened runtime. Notarization REQUIRES this.
#   --timestamp         secure timestamp from Apple's server. Also required.
#                       This is the one signing step that needs network access.
#
# No --entitlements: Jumbini asks for nothing. Window geometry
# (CGWindowListCopyWindowInfo), idle time (CGEventSource), power (IOPS*) and
# thermal state are all unprivileged reads. If you ever add an entitlement,
# pass --entitlements to the app signing call only.
# ---------------------------------------------------------------------------

echo "==> Signing with: $SIGN_IDENTITY"

# The SwiftPM resource bundle, if bundle.sh copied one in. No --options runtime:
# it holds PNGs and WAVs, no Mach-O, so hardened runtime has nothing to apply to.
# It still has to be signed BEFORE the app, or the app's seal over it breaks.
#
# Only sign it if it carries an Info.plist. codesign identifies a directory as a
# bundle by that file alone, and without one it refuses the whole directory with
# "bundle format unrecognized, invalid, or unsuitable". Which SwiftPM emits is
# toolchain-dependent: Swift 6.4 writes Contents/Info.plist, the Swift 6.1 on
# GitHub's macos-15 runners writes none at all. Signing it unconditionally means
# the release builds on the developer's Mac and dies on CI.
#
# Skipping is safe rather than merely expedient. The bundle has no Mach-O, so
# there is no code in it to sign, and `codesign` on the .app below seals every
# file underneath it — a modified sprite still fails --verify --deep --strict as
# "a sealed resource is missing or invalid". Notarization does not require nested
# resource bundles to carry their own signature.
RESOURCE_BUNDLE="$APP/Contents/Resources/Jumbini_Jumbini.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  if [ -f "$RESOURCE_BUNDLE/Contents/Info.plist" ] || [ -f "$RESOURCE_BUNDLE/Info.plist" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$RESOURCE_BUNDLE"
  else
    echo "    (resource bundle has no Info.plist; leaving it to the app's seal)"
  fi
fi

# The Sparkle framework ships ad-hoc signed from SwiftPM, so it must be re-signed
# with our Developer ID — not just for tidiness, but because Library Validation
# (part of the hardened runtime we sign the app with) refuses to load a
# framework whose Team ID doesn't match the app's. An ad-hoc signature has no
# team at all, so leaving it would crash the app on launch.
#
# Signed inside-out: the XPC services and helper tools first, the framework
# bundle last so it seals them. --preserve-metadata keeps Sparkle's identifiers
# and entitlements (the Autoupdate helper carries a com.apple.application-
# identifier) while the signature itself is replaced. Requirements are NOT
# preserved — an ad-hoc signature's designated requirement is anchored to its
# cdhash, which a re-sign changes, so preserving it would make the result fail
# its own verification.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
    [ -d "$xpc" ] || continue
    codesign --force --timestamp --options runtime \
      --preserve-metadata=identifier,entitlements \
      --sign "$SIGN_IDENTITY" "$xpc"
  done
  codesign --force --timestamp --options runtime \
    --preserve-metadata=identifier,entitlements \
    --sign "$SIGN_IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
  if [ -d "$SPARKLE/Versions/B/Updater.app" ]; then
    codesign --force --timestamp --options runtime \
      --preserve-metadata=identifier,entitlements \
      --sign "$SIGN_IDENTITY" "$SPARKLE/Versions/B/Updater.app"
  fi
  codesign --force --timestamp --options runtime \
    --preserve-metadata=identifier,entitlements \
    --sign "$SIGN_IDENTITY" "$SPARKLE"
fi

# Signing the bundle re-signs Contents/MacOS/Jumbini in place — that is where the
# bundle's CodeDirectory lives. Signing the executable separately first would be
# overwritten here anyway, and would cost an extra timestamp round trip.
codesign --force --timestamp --options runtime \
         --sign "$SIGN_IDENTITY" "$APP"

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# --verify checks signature integrity, not the two things notarization actually
# rejects builds for. Catch those here rather than after a round trip to Apple.
#
# Capture once into a variable rather than piping into `grep -q`: grep exits the
# instant it matches, codesign is still writing, gets SIGPIPE and exits 141, and
# pipefail reports that as failure -- on a signature that was perfectly fine.
SIG_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)

grep -q 'flags=.*runtime' <<<"$SIG_INFO" \
  || die "hardened runtime flag is not set on $APP"
grep -q 'Timestamp=' <<<"$SIG_INFO" \
  || die "no secure timestamp on $APP (could not reach Apple's timestamp server?)"

# ---------------------------------------------------------------------------
# 2b. Prove the signed app actually starts.
#
# Everything above this line inspects the bundle without ever running it, which
# is how v3.0 through v4.4 all shipped crashing on launch. Deliberately placed
# before notarization: a build that cannot start should not reach Apple, and
# must not reach gh-pages, where the release workflow publishes it as the
# update every existing install will download.
#
# The signed app is what gets tested, not the ad-hoc one bundle.sh made --
# hardened runtime and the Developer ID signature are both in force here, so a
# crash caused by signing itself has nowhere to hide either.
# ---------------------------------------------------------------------------

echo "==> Smoke testing the signed app"
Scripts/smoke.sh "$APP"

# ---------------------------------------------------------------------------
# 3. Build the DMG and sign it too.
#
# The DMG gets its own signature so Gatekeeper can evaluate the container
# itself, not just what is inside it.
# ---------------------------------------------------------------------------

echo "==> Building $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto, not cp -R: this copy happens after signing and before the hash Apple
# notarizes, and ditto is Apple's supported way to move a signed bundle intact.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Jumbini" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo
  echo "Signed (notarization skipped): $DMG"
  echo "This DMG will still be refused on a machine that has never seen it."
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Notarize the DMG.
#
# Submit the outermost container. Apple's guidance is to notarize and staple
# the outermost container only — the ticket covers everything inside it, so
# the .app does not get its own staple and does not need one.
#
# --wait blocks until Apple returns a terminal status, typically a few minutes.
# --timeout caps it: notarytool waits FOREVER by default, and Apple's notary
# service does occasionally stall for hours. Better to fail than to hang a
# release (or burn 6 hours of CI minutes) waiting on it.
# ---------------------------------------------------------------------------

echo "==> Submitting to Apple for notarization (this usually takes a few minutes)"

set +e
SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG" \
  --key "$APPLE_API_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait --timeout 45m 2>&1)
SUBMIT_STATUS=$?
set -e

echo "$SUBMIT_OUTPUT"

# notarytool exits non-zero on submission failure, but a submission can also
# succeed at the transport level and come back Invalid or Rejected. Check both.
# Anything that is not explicitly Accepted is treated as failure.
if [ $SUBMIT_STATUS -ne 0 ] || ! grep -qE '^ *status: Accepted' <<<"$SUBMIT_OUTPUT"; then
  # `|| true` matters: on an auth failure there is no submission id at all, and
  # a bare failing grep under `set -e` would kill the script right here — before
  # printing the error below or fetching the log that explains it.
  SUBMISSION_ID=$(grep -Eo '\bid: [0-9a-fA-F-]{36}' <<<"$SUBMIT_OUTPUT" | awk 'NR==1{print $2}' || true)
  echo >&2
  echo "error: notarization did not succeed." >&2
  if [ -n "${SUBMISSION_ID:-}" ]; then
    echo "Fetching the log — this is the only place Apple says WHY:" >&2
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER_ID" >&2 || true
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Staple, so the DMG validates without a network round trip.
# ---------------------------------------------------------------------------

echo "==> Stapling the ticket to $DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ---------------------------------------------------------------------------
# 6. Prove it. This is roughly what the user's Mac will conclude.
# ---------------------------------------------------------------------------

echo
echo "==> Gatekeeper assessment"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo
echo "Done: $DMG"
echo "Verify end to end by uploading it somewhere, downloading it in a browser"
echo "(so it picks up the quarantine flag), and double-clicking it."
