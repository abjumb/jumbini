#!/bin/bash
# Copies everything the capture account needs into /Users/Shared, because it
# cannot read this repo — home directories are 0700.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KIT="/Users/Shared/jumbini-demo"
APP="$ROOT/build/Jumbini.app"

[ -d "$APP" ] || { echo "stage: no app at $APP — run Scripts/bundle.sh first" >&2; exit 1; }

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
