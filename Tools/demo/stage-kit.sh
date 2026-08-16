#!/bin/bash
# Copies everything the capture account needs into /Users/Shared, because it
# cannot read this repo — home directories are 0700.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KIT="/Users/Shared/jumbini-demo"
APP="$ROOT/build/Jumbini.app"

[ -d "$APP" ] || { echo "stage: no app at $APP — run Scripts/bundle.sh first" >&2; exit 1; }

# A previous kit's out/ can hold footage nobody copied back yet. Four of the
# nine shots — thermal zoomies, the build party, the battery whine, sleep
# and wake — cannot be reproduced on cue, so silently wiping them on a
# routine re-stage (e.g. to pick up an app rebuild) would be expensive.
# `[ -d ... ]` failing (kit or out/ missing — the common, clean-machine
# case) must not itself trip `set -e`; nesting these as `if` conditions,
# rather than chaining them with `&&` into one statement whose overall
# non-zero status could be read as script failure, keeps that path silent.
if [ -d "$KIT/out" ]; then
  if [ -n "$(ls -A "$KIT/out" 2>/dev/null)" ]; then
    if [ "${JUMBINI_STAGE_FORCE:-}" != "1" ]; then
      cat >&2 <<EOF
stage: $KIT/out already has footage in it — copy it back to this repo before
stage: re-staging, or this run will delete it. Some of these shots (thermal
stage: zoomies, the build party, the battery whine, sleep and wake) cannot
stage: be re-shot on cue, so losing them is expensive.
stage: to re-stage anyway and discard whatever is in out/, re-run with:
stage:   JUMBINI_STAGE_FORCE=1 Tools/demo/stage-kit.sh
EOF
      exit 1
    fi
    echo "stage: JUMBINI_STAGE_FORCE=1 set — discarding footage already in $KIT/out" >&2
  fi
fi

rm -rf "$KIT"
mkdir -p "$KIT/Tools/demo" "$KIT/Sources/Jumbini/Resources"

cp -R "$APP" "$KIT/Jumbini.app"
cp -R "$HERE/shots" "$KIT/Tools/demo/"
# spritefilm via rsync, not cp -R: Tools/demo/spritefilm/.build is a 254MB
# local build cache with absolute paths baked into it. .gitignore hides it
# from git, but a plain `cp -R` does not know about .gitignore — only
# rsync's --exclude does, so this is how we keep it out of a world-readable
# directory.
rsync -a --exclude='.build' "$HERE/spritefilm/" "$KIT/Tools/demo/spritefilm/"
cp "$HERE/capture.sh" "$HERE/stills.sh" "$HERE/stage-windows.applescript" \
   "$HERE/animations.json" "$KIT/Tools/demo/"
cp -R "$ROOT/Sources/Jumbini/Resources/jumba" "$KIT/Sources/Jumbini/Resources/"
cp "$HERE/README.md" "$KIT/README.md"

# Everyone can read and run it; only the staging user can change it.
chmod -R a+rX "$KIT"

# capture.sh writes its recordings under $KIT/out (it does `mkdir -p
# "$OUT/raw"`, where $OUT defaults from $JUMBINI_DEMO_OUT). That mkdir runs
# as the capture account — a different user than whoever staged this kit —
# so out/ has to stay writable by everyone even though the rest of the kit
# is read-only. This has to run AFTER the recursive chmod above, or that
# chmod clobbers it right back to read-only.
mkdir -p "$KIT/out"
chmod a+rwx "$KIT/out"

cat <<EOF
stage: kit ready at $KIT

Now, in the capture account:
  1. Log in (single display, nothing else running).
  2. Terminal: cd $KIT && JUMBINI_APP=$KIT/Jumbini.app JUMBINI_DEMO_OUT=$KIT/out/clips Tools/demo/capture.sh
  3. Grant Screen Recording when asked, then run it again.
  4. Output lands in $KIT/out — copy it back and review every clip.
EOF
