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
RESOURCE_BUNDLE="$APP/Contents/Resources/Jumbini_Jumbini.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$RESOURCE_BUNDLE"
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
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'flags=.*runtime' \
  || die "hardened runtime flag is not set on $APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Timestamp=' \
  || die "no secure timestamp on $APP (could not reach Apple's timestamp server?)"

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
