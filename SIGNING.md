# Signing and notarizing Jumbini

Jumbini is signed with a Developer ID certificate and notarized by Apple. Someone
downloads `Jumbini.dmg`, double-clicks it, and it opens — no warning, no
override, no instructions. Before this, macOS refused it on first launch and a
fair number of people concluded it was malware and deleted it.

This document is the runbook: how it was set up, how to cut a release, and how to
redo any of it when a certificate expires or a key goes missing.

> **Current setup.** Identity `Developer ID Application: Alexander Wenson
> (MT2EH3GD49)`, certificate valid to **16 August 2031**. Notarization uses an
> App Store Connect **Team Key** with the Developer role. Local releases read
> credentials from `.env.release`, which is excluded via `.git/info/exclude` and
> must never be committed.

**Cost:** $99/year for the Apple Developer Program. There is no free path —
notarization requires a Developer ID certificate, which requires a paid
membership.

**Time:** an afternoon, most of which is waiting for Apple to approve the
enrollment.

---

## Step 1 — Enroll in the Apple Developer Program

Not yet done, so start here; everything else is blocked on it.

1. Go to <https://developer.apple.com/programs/enroll/> and sign in with your
   Apple ID.
2. Enroll as an **Individual** (a company enrollment needs a D-U-N-S number and
   is much slower — you do not need one for this).
3. Pay the $99. Enrollment now commonly redirects you to the Apple Developer
   app for government-ID verification rather than finishing in the browser.
4. Wait. Individual enrollment usually clears in 24–48 hours; identity
   verification occasionally drags it out longer.

Two things to know before you commit:

- **Your legal name becomes public.** For an individual enrollment, the
  certificate's common name — the name Gatekeeper shows users — is your real
  name, not "Jumbini". It appears in `codesign` output and in the "verified
  developer" string macOS displays.
- **It renews annually.** A lapsed membership does *not* revoke your
  certificate — revocation is a separate thing Apple does in response to abuse,
  and that one does kill already-shipped apps. What a lapse actually costs you:
  portal access, and the ability to notarize. Everything already released keeps
  working, but you can't ship anything new even though the key still exists.

Once you're approved, note your **Team ID** from
<https://developer.apple.com/account> → Membership details. It looks like
`AB12CD34EF`.

---

## Step 2 — Create the Developer ID Application certificate

This is the key that says "this build came from me."

**If you already have Xcode:**

1. Xcode → Settings → Accounts → add your Apple ID → select the team →
   **Manage Certificates…**
2. Click **+** → **Developer ID Application**.

Xcode generates the private key in your login keychain and fetches the
certificate.

**If you don't** — and the rest of this repo is deliberately Xcode-free, so
don't install 15 GB just for this — do it by hand:

1. Keychain Access → Certificate Assistant → **Request a Certificate From a
   Certificate Authority…** → enter your email and name, choose **Saved to
   disk**. This creates the private key in your keychain and a `.certSigningRequest`
   file.
2. Upload that CSR at
   <https://developer.apple.com/account/resources/certificates> → **+** →
   **Developer ID Application**.
3. Download the resulting `.cer` and double-click it to install.

> Apple caps you at **5 Developer ID Application certificates** per account, so
> don't generate them casually.

> Only the **Account Holder** can create Developer ID certificates. On an
> individual account that's you, so this is a non-issue.

**Verify it landed:**

```bash
security find-identity -v -p codesigning
```

You want a line like:

```
1) A1B2C3... "Developer ID Application: Your Name (AB12CD34EF)"
```

That whole quoted string — including the team ID in parentheses — is your
`SIGN_IDENTITY`.

> **Back up the private key now.** Keychain Access → My Certificates → select
> the cert → right-click → Export → `.p12` with a strong password. Store it in
> a password manager. If you lose the key you cannot re-download it; you have to
> revoke and reissue, and every future build signs as a "different" developer.

---

## Step 3 — Create an App Store Connect API key

This is what `notarytool` authenticates with. An API key beats an app-specific
password here: it doesn't break when you change your Apple ID password, it works
identically on your Mac and in CI, and it's revocable on its own.

1. Go to <https://appstoreconnect.apple.com/access/integrations/api>
2. **Team Keys** tab → **+**
3. Name it something like `jumbini-notarization`, give it the **Developer**
   role, and generate.
4. **Download the `.p8` immediately.** Apple lets you download it exactly once.
   Put it somewhere sane, e.g. `~/.appstoreconnect/private_keys/`, and back it
   up alongside the `.p12`.

You now have three values:

| Value | Where it's shown | Looks like |
|---|---|---|
| **Key ID** | in the key's row | `ABCD123456` |
| **Issuer ID** | above the key list | `00000000-0000-0000-0000-000000000000` |
| **`.p8` file** | the one-time download | `AuthKey_ABCD123456.p8` |

---

## Step 4 — Release from your Mac

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (AB12CD34EF)"
export APPLE_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABCD123456.p8"
export APPLE_API_KEY_ID="ABCD123456"
export APPLE_API_ISSUER_ID="00000000-0000-0000-0000-000000000000"

./Scripts/release.sh
```

It builds, signs inside-out, builds and signs the DMG, submits to Apple, waits,
staples the ticket, and prints a Gatekeeper assessment. Expect a few minutes at
the "Submitting to Apple" step.

To rehearse the signing without spending a notarization round trip:

```bash
SKIP_NOTARIZE=1 ./Scripts/release.sh
```

### What the script does, and why

| Step | Why |
|---|---|
| Signs `Jumbini_Jumbini.bundle`, then the `.app` | Anything inside must be signed before the bundle that seals it; signing outside-in produces a signature that fails verification. Signing the executable separately is unnecessary — signing the bundle re-signs it in place. |
| `--options runtime` | Hardened runtime. Notarization is refused without it. |
| `--timestamp` | Secure timestamp from Apple. Also required — and it's why signatures stay valid after the certificate expires. |
| No `--entitlements` | Jumbini requests nothing privileged. Window geometry, idle time, battery and thermal state are all unrestricted reads. Adding entitlements you don't need weakens the app for no benefit. |
| Signs the `.dmg` too | So Gatekeeper can evaluate the container, not just its contents. |
| Notarizes and staples **only the DMG** | Apple's own guidance: staple the outermost container. The ticket covers everything inside, so the `.app` doesn't get its own staple and doesn't need one. |

---

## Step 5 — Wire up GitHub Actions

`.github/workflows/release.yml` does the same thing on a macOS runner when you
push a tag. It needs seven repository secrets
(Settings → Secrets and variables → Actions → New repository secret).

Generate the two base64 blobs on your Mac:

```bash
# Export the cert from Keychain Access as cert.p12 first, then:
base64 -i cert.p12 | pbcopy                          # → MACOS_CERT_P12_BASE64
base64 -i AuthKey_ABCD123456.p8 | pbcopy             # → APPLE_API_KEY_P8_BASE64
```

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | base64 of the exported `.p12` |
| `MACOS_CERT_PASSWORD` | the password you set when exporting it |
| `SIGN_IDENTITY` | `Developer ID Application: Your Name (AB12CD34EF)` |
| `APPLE_API_KEY_P8_BASE64` | base64 of the `.p8` |
| `APPLE_API_KEY_ID` | `ABCD123456` |
| `APPLE_API_ISSUER_ID` | the issuer UUID |
| `SPARKLE_ED25519_KEY` | the base64 seed in `.sparkle-ed25519-key` |

Then:

```bash
git tag v4.1
git push origin v4.1
```

The workflow runs the test suite, imports the certificate into a throwaway
keychain, builds, signs, notarizes, staples, and attaches the DMG to a **draft**
release so you can look at it before it goes public.

---

## Step 6 — Actually verify it worked

Local checks pass on machines that already trust you, which makes them
misleading. The only test that counts is a download.

```bash
# 1. The signature is a real Developer ID one
codesign -dv --verbose=4 build/Jumbini.app 2>&1 | grep -E 'Authority|TeamIdentifier|flags'
#    expect: Authority=Developer ID Application: ...
#            flags=0x10000(runtime)      <- hardened runtime is on

# 2. The ticket is attached
xcrun stapler validate build/Jumbini.dmg

# 3. Gatekeeper's verdict
spctl --assess --type open --context context:primary-signature -vv build/Jumbini.dmg
#    expect: source=Notarized Developer ID
```

Then the real test:

1. Upload the DMG somewhere and download it **through a browser**, so it picks
   up the `com.apple.quarantine` attribute. Copying it over AirDrop or a USB
   stick does not reproduce what your users get.
2. Double-click. It should just open.
3. Ideally, try it on a Mac that has never had Jumbini on it.

To confirm the quarantine flag is actually present on your downloaded copy:

```bash
xattr -p com.apple.quarantine ~/Downloads/Jumbini.dmg
```

If that prints nothing, the file was never quarantined and your test proved
nothing.

---

## When it goes wrong

**`status: Invalid` from notarytool.** The submission log is the only place
Apple explains itself. `release.sh` fetches it automatically on failure; you can
also pull it by hand:

```bash
xcrun notarytool log <submission-id> \
  --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID"
```

The usual culprits are a missing hardened runtime, a missing timestamp, or an
unsigned nested binary.

**`The signature does not include a secure timestamp`.** `--timestamp` needs to
reach Apple's timestamp server. Check the network, then re-sign.

**`errSecInternalComponent` in CI.** The `security set-key-partition-list` step
didn't take. Without it codesign tries to raise an interactive prompt that
nothing on a headless runner can answer.

**"Jumbini is damaged and can't be opened."** Almost always still-unsigned or
still-unnotarized, not actual corruption. Run the Step 6 checks against the
exact file the user downloaded.

**Certificate expired.** Developer ID certificates last five years. Because the
signatures are timestamped, everything you already shipped keeps working; you
just need a new certificate to sign new builds.

### Actually hit during setup

Keeping these because they cost real time and will cost it again.

**`security import` says the password is wrong, and it isn't.** Homebrew's
OpenSSL 3 defaults `pkcs12 -export` to AES-256-CBC with a SHA-256 MAC. Apple's
`security` can't parse that and reports it as a password failure. Diagnose with
`openssl pkcs12 -in devid.p12 -noout -info` — if it shows `MAC: sha256` and
`AES-256-CBC`, that's the problem, not your password. Re-export with `-legacy`:

```bash
openssl pkcs12 -export -legacy -inkey devid.key -in devid.pem -out devid.p12 \
  -name "Developer ID Application"
```

A correct file shows `MAC: sha1` and `RC2-40-CBC`. Reading it back with
`openssl -info` afterwards throws `RC2-40-CBC unsupported` — ignore that, it's
OpenSSL 3 refusing to load the legacy provider for *reading*. macOS reads it
fine, which is the only thing that matters. `/usr/bin/openssl` (LibreSSL)
produces a compatible file by default if `-legacy` isn't available.

**HTTP 401 Unauthenticated from notarytool.** Credentials, not the DMG. Check
for a placeholder that never got substituted before anything else:

```bash
echo "${#APPLE_API_KEY_ID}"      # must be 10
echo "${#APPLE_API_ISSUER_ID}"   # must be 36
```

Then smoke-test auth without spending a submission — `xcrun notarytool history`
with the same three arguments. `No submission history.` is success.

**The portal hands you four `.cer` files and only one is yours.** The others are
Apple's intermediate and root CAs. Identify yours by subject:

```bash
openssl x509 -inform DER -in "some.cer" -noout -subject
# yours: CN=Developer ID Application: <name> (TEAMID)
```

**Certificate Assistant is in the macOS menu bar**, not inside the Keychain
Access window — which is why the `openssl` route above is the one documented
here.

---

## Auto-update (Sparkle)

Jumbini updates itself with Sparkle. The app checks an appcast feed in the
background once a day, offers the update, and Sparkle's `Autoupdate` helper
installs it. Everything lives in three places:

- **`Scripts/Info.plist`** — `SUFeedURL` (where the appcast lives), `SUPublicEDKey`
  (the EdDSA public key that signs updates), and `SUEnableAutomaticChecks`.
- **`Sources/Jumbini/AppDelegate.swift`** — creates the updater and wires a
  "Check for Updates…" menu item to it.
- **`Scripts/bundle.sh` / `Scripts/release.sh`** — embed `Sparkle.framework`
  (from the SwiftPM artifact) and re-sign it inside-out. The framework ships
  *ad-hoc* signed, so `release.sh` must re-sign it with the Developer ID —
  Library Validation (part of the hardened runtime) refuses to load a framework
  whose team doesn't match the app's.

### The EdDSA key

Sparkle signs every update archive with an ed25519 key so a compromised server
can't substitute a fake update. There is one key pair:

| Half | Where it lives | Never commit |
|---|---|---|
| Public | `SUPublicEDKey` in `Scripts/Info.plist` | (safe to commit) |
| Private | `.sparkle-ed25519-key` (gitignored), or the login keychain, or the `SPARKLE_ED25519_KEY` GitHub secret | **never commit** |

The private key is a base64 ed25519 seed. It was generated during setup and
written to `.sparkle-ed25519-key`; the same value goes in the password manager
alongside the `.p12`. To rotate or regenerate, Sparkle's `generate_keys` tool
does the keychain dance:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys    # prints a new SUPublicEDKey
```

Put the new public key in `Info.plist` and the new seed in `.sparkle-ed25519-key`.

### Publishing an update

The release workflow does this automatically: after `release.sh` builds and
signs the DMG, it copies it into the `gh-pages` history, runs `appcast.sh`
(which signs the DMG and emits `appcast.xml` plus delta files), and pushes the
result to GitHub Pages. `SUFeedURL` points at
`https://abjumb.github.io/jumbini/appcast.xml`, so once Pages is enabled there
is nothing to do beyond `git tag v4.1 && git push origin v4.1`.

**One-time setup** (before the first release):

1. Add `SPARKLE_ED25519_KEY` to the repository secrets (the value in
   `.sparkle-ed25519-key`).
2. Enable GitHub Pages: Settings → Pages → Source → **Deploy from a branch**,
   branch `gh-pages`.

   Leave it there. `SUFeedURL` is compiled into every copy of the app that has
   ever shipped, so pointing Pages at a different branch or folder takes the
   feed offline for everyone already running Jumbini — they cannot be updated
   to a build that knows the new address. Anything else that wants to live at
   `abjumb.github.io/jumbini` (the download page in `docs/`, for instance)
   belongs *in* the `gh-pages` branch alongside `appcast.xml`, not in place of
   it. The release workflow rebuilds that branch from its own contents each
   time, so files published there survive.

To publish by hand instead (e.g. to a different host):

```bash
./Scripts/appcast.sh build/        # writes build/appcast.xml + *.delta files
```

`appcast.sh` signs the DMG with the key (env var first, then
`.sparkle-ed25519-key`, then the keychain) and writes the appcast plus delta
files for faster incremental updates. Upload `appcast.xml`, the `*.delta`
files, and the DMG to whatever host `SUFeedURL` points at. Change `SUFeedURL`
in `Info.plist` if you host it elsewhere — the URL the DMGs are advertised at
is derived from it (its directory), so the two cannot drift apart. To publish
somewhere else just once without touching `Info.plist`, set
`SPARKLE_DOWNLOAD_URL_PREFIX`.

> **The trailing slash on that prefix is load-bearing.** `generate_appcast`
> resolves each archive name *relative to* the prefix, so
> `https://abjumb.github.io/jumbini` + `Jumbini-4.2.dmg` becomes
> `https://abjumb.github.io/Jumbini-4.2.dmg` — the last path segment is
> replaced rather than appended to, and every download 404s. This is how v4.2
> shipped. `appcast.sh` now appends the slash itself, repairs enclosure URLs
> left over from a broken run, and refuses to finish if any archive present on
> disk is advertised at the wrong URL. The release workflow then fetches the
> published feed and downloads the DMG behind it before the release is
> considered good, so the failure can no longer be silent.

The feed URL must be HTTPS (Apple's App Transport Security) and the archive
must be the same signed-and-notarized DMG you distribute, so Sparkle's
signature check and Gatekeeper both pass.

---

## What this does not do

- It does not sandbox the app or prepare it for the Mac App Store. Those are a
  different, much larger piece of work, and sandboxing would likely break
  window-walking.
- It does not remove the Apple Silicon restriction.
