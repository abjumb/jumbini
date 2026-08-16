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

# ---------------------------------------------------------------------------
# Crop geometry
#
# In screen POINTS, top-left origin, converted to pixels at runtime against
# the resolution screencapture actually writes. The previous version hardcoded
# pixels and multiplied by two for Retina; on the 1x 1920x1080 display this kit
# is shot on that asked ffmpeg for a 3200x1800 window of a 1920x1080 frame, and
# every encode died with:
#
#   [Parsed_crop_0] Invalid too big or non positive size for width '3200'
#
# after the take was recorded and the app killed, so the take was lost. Dropping
# the *2 did not fix it either: 200+900 = 1100 overflows a 1080-tall screen, and
# ffmpeg does not reject that — the crop filter silently clamps y to 180 and
# frames 20pt above where the author meant. Silent is worse than loud, which is
# why the fit is now checked here rather than left to ffmpeg.
#
# THE DEFAULT IS THE WHOLE SCREEN, and that is a conclusion, not laziness.
# What has to stay in frame, in points on a 1920x1080 display:
#
#   staged TextEdit window     x  320..1180  y 260..760   stage-windows: open
#     ...after `move`          x  488..1348  y 260..760   12 steps of 14pt
#     ...after `yank`          x  900..1760  y 260..760
#   staged Finder window       x 1240..1900  y 420..860
#   his bed                    x ~1560..1800 y ~880..980  PetScene.swift:132,
#                                  home.maxX-240, home.minY+150 — bottom right
#   the treat box              x ~1810..1900 y ~885..985  PetScene.swift:141
#   zoomies                    THE ENTIRE SCREEN. PetScene.swift:1168-1173
#                                  bounces him off 0..size.width/height, and
#                                  the scene is the union of every display.
#   thrown toys, the fetch ball, piles — clamped only by `margin` against
#                                  those same full-scene bounds.
#
# Union of the staged content alone is x 320..1900, y 260..985 — 1580x725,
# already flush against the right edge with 20pt to spare. Add zoomies, which
# is the whole of thermal.json, and any crop cuts the dog out of his own clip.
# So the smallest honest crop on this display is 0,0 1920x1080: the screen.
# Cropping would buy a marginally tighter frame at the risk of beheading the
# flagship, and 1920 -> 1440 is an exact 0.75 downscale of an exact 16:9 frame
# (delivering 1440x810), so there is nothing to gain by cropping either.
#
# Override per run with JUMBINI_CROP_X/Y/W/H if a particular shot wants a
# tighter frame. The validation below is what stops a bad override from being
# discovered nine takes later.
CROP_X="${JUMBINI_CROP_X:-0}"
CROP_Y="${JUMBINI_CROP_Y:-0}"
CROP_W="${JUMBINI_CROP_W:-0}"   # 0 means "out to the right edge"
CROP_H="${JUMBINI_CROP_H:-0}"   # 0 means "down to the bottom edge"
DELIVER_W="${JUMBINI_DELIVER_W:-1440}"

die() { echo "capture: $*" >&2; exit 1; }

command -v ffmpeg >/dev/null || die "ffmpeg missing. Run: brew install ffmpeg"
command -v ffprobe >/dev/null || die "ffprobe missing (it ships with ffmpeg). Run: brew install ffmpeg"
[ -x "$BIN" ] || die "no app at $BIN. Set JUMBINI_APP to the built Jumbini.app — in the capture account it is the one staged next to this script, and there is no repo here to build one from."
mkdir -p "$RAW"

# "1920,1080" for the video stream of a .mov.
pixel_size() {
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$1"
}

# The main display's size in POINTS. "Resolution:" is pixels; "UI Looks like:"
# is what AppKit, AppleScript window bounds and this crop are all measured in.
# Needs no permission of any kind, unlike asking the window server.
screen_points() {
  system_profiler SPDisplaysDataType 2>/dev/null \
    | awk '/UI Looks like/ { for (i = 1; i <= NF; i++) if ($i == "like:") { print $(i+1), $(i+3); exit } }'
}

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

# ---------------------------------------------------------------------------
# Resolve the crop against what screencapture actually writes.
#
# The permission probe above is a real recording of the real display, so it
# answers the only question that matters — how many pixels a take will have —
# one second into the run, rather than after the first take has been recorded
# and the app killed. That ordering is the whole point: a geometry error found
# here costs a second, and found later costs a take that (thermal, build
# party, battery, sleep) cannot be re-shot on cue.
probe_dims=$(pixel_size "$probe")
rm -f "$probe"
case "$probe_dims" in
  [0-9]*,[0-9]*) ;;
  *) die "could not read the probe recording's pixel size (got '$probe_dims') — ffprobe or screencapture output looks broken" ;;
esac
pixel_w=${probe_dims%,*}
pixel_h=${probe_dims#*,}

points="${JUMBINI_SCREEN_POINTS:-$(screen_points)}"
point_w=${points%% *}
point_h=${points##* }
case "${point_w:-x}:${point_h:-x}" in
  [0-9]*:[0-9]*) ;;
  *) die "could not read the display's size in points from system_profiler (got '$points'). Pass it yourself: JUMBINI_SCREEN_POINTS='1920 1080' Tools/demo/capture.sh" ;;
esac

# One awk pass, because every number here is a float and bash has no floats.
# Sizes and offsets are rounded DOWN to even pixels: an odd crop against 4:2:0
# chroma is an argument with ffmpeg nobody wants to have mid-run.
geometry=$(awk -v px="$pixel_w" -v py="$pixel_h" -v tw="$point_w" -v th="$point_h" \
               -v cx="$CROP_X" -v cy="$CROP_Y" -v cw="$CROP_W" -v ch="$CROP_H" '
  function even(v) { v = int(v); return v - (v % 2) }
  BEGIN {
    sx = px / tw; sy = py / th
    if (sx - sy > 0.01 || sy - sx > 0.01) {
      print "ERR the display reports " px "x" py " pixels over " tw "x" th " points, which is not a single backing scale — set JUMBINI_SCREEN_POINTS to the real point size"
      exit
    }
    if (cw <= 0) cw = tw - cx
    if (ch <= 0) ch = th - cy
    x = even(cx * sx); y = even(cy * sx)
    w = even(cw * sx); h = even(ch * sx)
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > px || y + h > py) {
      print "ERR crop " cw "x" ch "+" cx "+" cy " points is " w "x" h "+" x "+" y \
            " pixels, which does not fit inside the " px "x" py " frame screencapture records. Fix JUMBINI_CROP_X/Y/W/H (points, top-left origin) and re-run."
      exit
    }
    printf "%d %d %d %d %g", w, h, x, y, sx
  }')
case "$geometry" in
  "ERR "*) die "${geometry#ERR }" ;;
  "") die "could not compute the crop geometry" ;;
esac
read -r crop_w crop_h crop_x crop_y backing_scale <<<"$geometry"

if [ "$crop_x" -eq 0 ] && [ "$crop_y" -eq 0 ] \
   && [ "$crop_w" -eq "$pixel_w" ] && [ "$crop_h" -eq "$pixel_h" ]; then
  # No crop filter at all rather than a no-op crop=W:H:0:0 — one less thing
  # between the recording and the encoder.
  filter="scale=${DELIVER_W}:-2:flags=lanczos"
else
  filter="crop=${crop_w}:${crop_h}:${crop_x}:${crop_y},scale=${DELIVER_W}:-2:flags=lanczos"
fi

echo "capture: ${pixel_w}x${pixel_h} pixels over ${point_w}x${point_h} points (${backing_scale}x)"
echo "capture: filter $filter"

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
  dims=$(pixel_size "$RAW/$shot.mov")
  [ "$dims" = "$probe_dims" ] \
    || die "$shot recorded at $dims but the crop was resolved against $probe_dims — the display changed mid-run. Re-run this shot."

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
