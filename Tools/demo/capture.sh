#!/bin/bash
# Records the landing-page clips. Runs unattended in the capture account.
#
#   ./capture.sh            # every shot
#   ./capture.sh climb      # one shot
#
# Needs: a built Jumbini.app, ffmpeg, and Screen Recording permission for
# whatever terminal is running this. Grant it once, in System Settings >
# Privacy & Security > Screen Recording, then re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SHOTS="$HERE/shots"
OUT="${JUMBINI_DEMO_OUT:-$ROOT/demo-assets/clips}"
RAW="$OUT/raw"
APP="${JUMBINI_APP:-$ROOT/build/Jumbini.app}"
BIN="$APP/Contents/MacOS/Jumbini"

# Crop applied to every clip: a 1600x900 window of the screen, offset so the
# staged windows sit inside it. Retina doubles these at capture time.
CROP_W=1600; CROP_H=900; CROP_X=200; CROP_Y=200
DELIVER_W=1440

die() { echo "capture: $*" >&2; exit 1; }

command -v ffmpeg >/dev/null || die "ffmpeg missing. Run: brew install ffmpeg"
[ -x "$BIN" ] || die "no app at $BIN. Build it with Scripts/bundle.sh first."
mkdir -p "$RAW"

# A black recording means the permission was never granted, and it is far
# better to find that out now than after nine takes. A denied recording is
# NOT an empty file — screencapture still writes a full-length, near-uniform
# black .mov — so a bare size check would pass right through a denial. Measure
# the first frame's average luma instead.
probe="$RAW/.permission-probe.mov"
screencapture -v -V 1 "$probe" >/dev/null 2>&1 || true
[ -s "$probe" ] || die "screencapture produced nothing — grant Screen Recording permission and re-run"

# The `|| true` matters: under `pipefail`, a corrupt/undecodable probe makes
# ffmpeg and/or grep exit non-zero even though cut (the rightmost command)
# exits 0, which would otherwise fail this assignment and let `set -e` kill
# the script here — before the case statement below ever runs. `|| true`
# defers the failure to the explicit, honest check that follows instead of
# leaving the operator with a bare, unexplained exit.
probe_luma=$(ffmpeg -v error -i "$probe" \
  -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
  -frames:v 1 -f null - 2>/dev/null | grep -m1 -o 'YAVG=[0-9.]\+' | cut -d= -f2) || true

case "$probe_luma" in
  ''|*[!0-9.]*)
    die "could not measure the probe recording's brightness (got '$probe_luma') — screencapture or ffmpeg output looks broken"
    ;;
esac

# True black reads YAVG 0; a limited-range black frame can read as high as
# 16. Real desktop content — even a dark wallpaper, once menu bar/dock/cursor
# chrome is counted — reads far higher (~45 measured on the authoring
# machine). 20 sits with margin above the black ceiling and well below real
# content. Erring toward a false positive here is intentional: a false
# positive fails visibly and costs a re-run, a false negative would ship
# nine black clips silently.
awk -v y="$probe_luma" 'BEGIN { exit (y > 20) ? 0 : 1 }' \
  || die "probe recording reads near-black (avg luma $probe_luma, threshold 20). Most likely: Screen Recording permission was not granted for this terminal — check System Settings > Privacy & Security > Screen Recording, enable it, and re-run. Less likely: the desktop background is unusually dark — if permission is already granted, switch to a lighter wallpaper and re-run to rule that out."

rm -f "$probe"

shots=("$@")
if [ ${#shots[@]} -eq 0 ]; then
  shots=(climb thermal build-party quiet fetch toys tricks pounce charm)
fi

# Pre-flight every requested shot's script before spending any capture time.
# A typo caught after six takes wastes six takes; caught here, it wastes
# nothing.
for shot in "${shots[@]}"; do
  [ -f "$SHOTS/$shot.json" ] || die "no shot script at $SHOTS/$shot.json"
done

original_dnd_note="Do Not Disturb is left on for the session; turn it off when you are done."
echo "capture: enabling Do Not Disturb — $original_dnd_note"
shortcuts run "Turn On Do Not Disturb" 2>/dev/null \
  || echo "capture: could not toggle DND automatically; do it by hand before continuing"

for shot in "${shots[@]}"; do
  script="$SHOTS/$shot.json"
  [ -f "$script" ] || die "no shot script at $script"

  duration=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['duration'])" "$script")
  show_cursor=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('showCursor',False))" "$script")

  echo "capture: $shot (${duration}s)"

  # A pile left by the previous take would sit in the corner of this one.
  # UserDefaults is the only state the dog persists — coat, bed, wardrobe,
  # sound-muted, and trick-training progress — and this clears all of it.
  defaults delete com.alex.jumbini 2>/dev/null || true

  osascript "$HERE/stage-windows.applescript" open
  sleep 1

  JUMBINI_DEMO="$script" "$BIN" &
  app_pid=$!
  # The scene needs to exist before the first beat lands.
  sleep 2
  kill -0 "$app_pid" 2>/dev/null \
    || die "Jumbini exited immediately after launch — check Console.app for a crash log"

  cursor_flag=""
  [ "$show_cursor" = "True" ] && cursor_flag="-C"

  # shellcheck disable=SC2086
  screencapture -v $cursor_flag -V "$duration" "$RAW/$shot.mov" &
  rec_pid=$!

  # The flagship needs the window moved underneath him mid-take.
  if [ "$shot" = "climb" ]; then
    sleep 6
    osascript "$HERE/stage-windows.applescript" move
    sleep 1
    osascript "$HERE/stage-windows.applescript" yank
  fi

  wait $rec_pid
  [ -s "$RAW/$shot.mov" ] \
    || die "screencapture for $shot produced no output — check Console.app and re-run this shot"
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  osascript "$HERE/stage-windows.applescript" close

  echo "capture: encoding $shot"
  filter="crop=${CROP_W}*2:${CROP_H}*2:${CROP_X}*2:${CROP_Y}*2,scale=${DELIVER_W}:-2:flags=lanczos"

  ffmpeg -y -loglevel error -i "$RAW/$shot.mov" \
    -vf "$filter" -r 30 \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 23 \
    -movflags +faststart -an "$OUT/$shot.mp4"

  ffmpeg -y -loglevel error -i "$RAW/$shot.mov" \
    -vf "$filter" -r 30 \
    -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -an "$OUT/$shot.webm"

  ffmpeg -y -loglevel error -ss 1 -i "$RAW/$shot.mov" \
    -vf "$filter" -frames:v 1 -q:v 3 "$OUT/$shot.jpg"

  size=$(stat -f%z "$OUT/$shot.mp4")
  if [ "$size" -gt 2097152 ]; then
    echo "capture: WARNING $shot.mp4 is $((size / 1024))KB, over the 2MB budget"
  fi
done

echo "capture: done. Clips in $OUT"
echo "capture: review each one before publishing — a spontaneous wander can"
echo "capture: walk into a take, and the fix is to re-run that shot."
