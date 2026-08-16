#!/bin/bash
# Records the landing-page clips. Runs unattended in the capture account.
#
#   ./capture.sh            # every shot
#   ./capture.sh climb      # one shot
#
# Needs a built Jumbini.app, ffmpeg, and THREE one-time grants in System
# Settings > Privacy & Security, all of them for whatever terminal runs this:
#
#   Screen Recording            — without it every frame is black.
#   Automation > TextEdit       — the staged windows are driven by Apple
#   Automation > Finder           Events, and macOS asks separately for each
#                                 target app. Unattended, an ungranted one
#                                 stalls on a consent dialog nobody is
#                                 watching, so both are pre-flighted below.
#
# Everything else it uses (plutil, perl, osascript, screencapture, shortcuts)
# ships with macOS. There is deliberately no Swift or python3 dependency: the
# hero sheets and stills are rendered in the authoring account by stills.sh,
# not here.
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

# ---------------------------------------------------------------------------
# The recording window vs. the dog's clock
#
# DemoDriver's t=0 used to be applicationDidFinishLaunching, and this script
# launched the app, slept two seconds, and only then started screencapture. Two
# consequences, both real:
#
#   * every beat before t=2 was never recorded. That is the ONLY beat in
#     thermal.json (fansUp at 1.0) and build-party.json (buildFinished at 1.5),
#     and the opening beat of the other seven shots.
#   * driver.onFinish calls NSApp.terminate at t=duration, roughly two seconds
#     before `screencapture -V "$duration"` stopped, so every clip ended on a
#     dogless desktop.
#
# Now the recorder starts first and the driver is handed an absolute instant
# for its t=0 (JUMBINI_DEMO_START), so the two clocks share an origin instead
# of racing. Per take, in wall time:
#
#   t_rec                        screencapture launched
#   t_rec + WARMUP               its frame 0. Unknown up front, measured after.
#   t_rec + LEAD                 the dog's t=0. LEAD covers BOTH screencapture's
#                                warm-up and the app's launch + scene build,
#                                which run concurrently inside it.
#   t_rec + LEAD + D             the driver finishes and terminates the app
#   t_rec + LEAD + D + TAIL      screencapture stops
#
# So the file holds LEAD + D + TAIL seconds, and the encode takes exactly D of
# them starting (LEAD - WARMUP) in. WARMUP is measured, not assumed: since
# `screencapture -V N` writes N seconds of content, everything the process
# spent beyond N is warm-up plus finalisation, and attributing the lot to
# warm-up biases the trim early — a few frames of static desktop at the head
# rather than a lost opening beat.
#
# TAIL is what keeps the app's own termination outside the encode window; the
# clip's last frame is at D - 1/30, and the app quits at D + one driver tick.
#
# BOTH halves of LEAD are measured, not assumed. WARMUP as above; the app's
# launch is timed by polling LaunchServices for its check-in (see
# wait_for_app), which is also what pays the Gatekeeper cost once before the
# first take instead of inside it.
LEAD=3.0
TAIL=1.5

# Tenths of a second. Every poll below is bounded by this: a poll that can hang
# forever is a worse failure than the fixed sleep it replaces.
LAUNCH_CEILING=600

die() { echo "capture: $*" >&2; exit 1; }

# Wall clock with sub-second resolution. macOS `date` is whole seconds only;
# perl and Time::HiRes are both part of the base OS, unlike python3, which is
# a Command Line Tools shim and would prompt to install Xcode mid-run.
now() { /usr/bin/perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()'; }

# bash has no floats and every number in the timing above is one.
calc() { awk "BEGIN { printf \"%.3f\n\", $* }"; }

sleep_until() {
  local remaining
  remaining=$(calc "$1 - $(now)")
  if awk -v r="$remaining" 'BEGIN { exit (r > 0) ? 0 : 1 }'; then
    sleep "$remaining"
  fi
}

# LaunchServices check-in is the cheapest "it is actually up" signal that needs
# no permission at all — no Accessibility, no window-server query. A GUI app
# registers here inside NSApplicationMain, which is after dyld and after
# Gatekeeper has finished assessing the bundle: the part of a launch that can
# take seconds on a throwaway account's first run.
app_registered() {
  [ -n "$(lsappinfo find "bundleID=$BUNDLE_ID" 2>/dev/null)" ]
}

# 0 = up, 1 = the process died on the way, 2 = ceiling reached.
wait_for_app() {
  local pid="$1" ticks=0
  while [ "$ticks" -lt "$LAUNCH_CEILING" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    if app_registered; then return 0; fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  return 2
}

# LaunchServices deregisters asynchronously, so without this the next take's
# wait_for_app would return instantly against the previous take's stale
# registration and measure a launch time of nothing.
wait_for_app_gone() {
  local ticks=0
  while [ "$ticks" -lt "$LAUNCH_CEILING" ]; do
    app_registered || return 0
    sleep 0.1
    ticks=$((ticks + 1))
  done
  return 2
}

# Any die() inside the shot loop used to leave the app running, the staged
# windows open and the next run filming two dogs. Nothing in here may fail:
# it runs on the error path, where a second failure would bury the real
# diagnostic. Do Not Disturb is deliberately NOT turned back off — leaving it
# on for the session is the documented behaviour on success too.
app_pid=""
rec_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$rec_pid" ]; then kill "$rec_pid" 2>/dev/null || true; fi
  if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi
  osascript "$HERE/stage-windows.applescript" close >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

# Homebrew is installed per-machine but put on PATH per-account, by a line in
# the shell profile. A fresh capture account has no such line, so ffmpeg is
# sitting right there at /opt/homebrew/bin and still invisible — and the old
# message told the operator to install software they already have. Look in the
# usual places before believing it is missing.
if ! command -v ffmpeg >/dev/null; then
  for brew_bin in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$brew_bin/ffmpeg" ]; then
      PATH="$brew_bin:$PATH"
      export PATH
      echo "capture: found ffmpeg in $brew_bin (not on this account's PATH — using it anyway)"
      break
    fi
  done
fi

command -v ffmpeg >/dev/null || die "ffmpeg missing, and it is not in /opt/homebrew/bin or /usr/local/bin either. Run: brew install ffmpeg"
command -v ffprobe >/dev/null || die "ffprobe missing (it ships with ffmpeg, so an ffmpeg without it is a broken install). Run: brew reinstall ffmpeg"
[ -x "$BIN" ] || die "no app at $BIN. Set JUMBINI_APP to the built Jumbini.app — in the capture account it is the one staged next to this script, and there is no repo here to build one from."
mkdir -p "$RAW"

# Read from the bundle rather than hardcoded, so the readiness poll and the
# UserDefaults reset below can never drift apart from the app being filmed.
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)
[ -n "$BUNDLE_ID" ] || die "no CFBundleIdentifier in $APP/Contents/Info.plist — is that really a built Jumbini.app?"

# ---------------------------------------------------------------------------
# Automation (Apple Events) consent — the second and third permissions.
#
# Screen Recording is not the only grant this needs, though the docs used to
# say so. The first osascript aimed at TextEdit and the first aimed at Finder
# each raise their own interactive TCC dialog. Unattended, that dialog blocks
# and then the event fails with -1712 (timed out), fifteen seconds into take
# one, with the app already launched and the recorder already running.
#
# So both are probed here, with a read-only event, before anything is
# recorded. The probe still has to bound its own wait, because the very dialog
# we are trying to get ahead of would otherwise hang this script instead.
automation_probe() {
  local app="$1" query="$2" log="$RAW/.automation-probe.txt" pid waited=0
  osascript -e "tell application \"$app\" to $query" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 25 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    automation_die "$app" "it did not answer within ${waited}s, which is what a consent dialog waiting for a click looks like"
  fi
  if ! wait "$pid"; then
    automation_die "$app" "$(cat "$log" 2>/dev/null)"
  fi
  rm -f "$log"
}

automation_die() {
  die "cannot send Apple Events to $1: $2
capture: The staged windows are driven by AppleScript, so this terminal needs
capture: Automation permission for $1. Grant it in System Settings >
capture: Privacy & Security > Automation > (this terminal) > $1, then re-run.
capture: Every target app is a separate switch — TextEdit and Finder both
capture: have to be on."
}

automation_probe TextEdit "count documents"
automation_probe Finder "count windows"

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

# ---------------------------------------------------------------------------
# Pay the cold-launch cost once, outside every take.
#
# LEAD has to cover the app's launch as well as the recorder's warm-up, and the
# FIRST launch of a freshly staged bundle is the slow one: Gatekeeper assesses
# it before any of our code runs, and on a throwaway account that can take
# seconds. Landing that inside take one would mean the dog's t=0 had already
# passed by the time the scene existed, every opening beat firing in a single
# tick, and a clip that opens on an empty desktop — across all nine takes, on
# the run that matters most.
#
# So the app is launched once here WITHOUT JUMBINI_DEMO. The driver is not
# constructed (that is the gate, and it is tested), so it just sits there while
# we time it and kill it. That warms Gatekeeper AND proves the cold launch fits
# inside LEAD before a single frame is recorded.
echo "capture: warming the app — the first launch is the one that pays for Gatekeeper"
warm_start=$(now)
"$BIN" &
app_pid=$!
ready=0
wait_for_app "$app_pid" || ready=$?
case "$ready" in
  1) die "Jumbini exited immediately on a plain launch — check Console.app for a crash log" ;;
  2) die "Jumbini did not register with LaunchServices within $((LAUNCH_CEILING / 10))s of launching. Something is wrong with the bundle at $APP." ;;
esac
cold_launch=$(calc "$(now) - $warm_start")
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
app_pid=""
wait_for_app_gone \
  || die "Jumbini is still registered with LaunchServices $((LAUNCH_CEILING / 10))s after being killed — is another copy already running?"

echo "capture: cold launch took ${cold_launch}s (lead is ${LEAD}s)"
awk -v l="$cold_launch" -v lead="$LEAD" 'BEGIN { exit (l < lead) ? 0 : 1 }' \
  || die "the app takes ${cold_launch}s to launch but LEAD is ${LEAD}s, so the dog's t=0 would pass before his scene existed and every clip would open on an empty desktop. Raise LEAD at the top of this script to comfortably more than ${cold_launch}s and re-run."

original_dnd_note="Do Not Disturb is left on for the session; turn it off when you are done."
echo "capture: enabling Do Not Disturb — $original_dnd_note"
shortcuts run "Turn On Do Not Disturb" 2>/dev/null || {
  echo "capture: could not turn Do Not Disturb on automatically. The run"
  echo "capture: continues without it, so a notification banner can walk into"
  echo "capture: a take — check every clip, and re-shoot any that caught one."
}

for shot in "${shots[@]}"; do
  script="$SHOTS/$shot.json"
  [ -f "$script" ] || die "no shot script at $script"

  # plutil prints 15.000000; calc trims it to something readable that ffmpeg
  # and screencapture are both still happy with.
  duration=$(calc "$(plutil -extract duration raw -o - "$script")")
  show_cursor=$(plutil -extract showCursor raw -o - "$script" 2>/dev/null || echo false)

  echo "capture: $shot (${duration}s)"

  # A pile left by the previous take would sit in the corner of this one.
  # UserDefaults is the only state the dog persists — coat, bed, wardrobe,
  # sound-muted, and trick-training progress — and this clears all of it.
  defaults delete "$BUNDLE_ID" 2>/dev/null || true

  osascript "$HERE/stage-windows.applescript" open
  sleep 1

  cursor_flag=""
  if [ "$show_cursor" = "true" ]; then cursor_flag="-C"; fi

  # Recorder first, app second — see the timing note at the top of the file.
  rec_len=$(calc "$LEAD + $duration + $TAIL")
  t_rec=$(now)
  # shellcheck disable=SC2086
  screencapture -v $cursor_flag -V "$rec_len" "$RAW/$shot.mov" &
  rec_pid=$!

  driver_start=$(calc "$t_rec + $LEAD")
  JUMBINI_DEMO="$script" JUMBINI_DEMO_START="$driver_start" "$BIN" &
  app_pid=$!
  # Wait for the app to actually be up rather than assuming two seconds covers
  # it. t_ready is the other half of the LEAD budget, checked after the take
  # alongside the recorder's warm-up.
  ready=0
  wait_for_app "$app_pid" || ready=$?
  case "$ready" in
    1) die "Jumbini exited immediately after launch — check Console.app for a crash log" ;;
    2) die "Jumbini did not register with LaunchServices within $((LAUNCH_CEILING / 10))s while shooting $shot" ;;
  esac
  t_ready=$(now)

  # The flagship needs the window moved underneath him mid-take. These are
  # clip-relative — driver seconds, the same clock the shot's beats are on —
  # so the ride starts 6s into a 15s take and the yank lands around 8.4s.
  if [ "$shot" = "climb" ]; then
    sleep_until "$(calc "$driver_start + 6")"
    osascript "$HERE/stage-windows.applescript" move
    sleep 1
    osascript "$HERE/stage-windows.applescript" yank
  fi

  wait "$rec_pid" || die "screencapture for $shot failed — check Console.app and re-run this shot"
  t_stop=$(now)
  rec_pid=""
  [ -s "$RAW/$shot.mov" ] \
    || die "screencapture for $shot produced no output — check Console.app and re-run this shot"

  # The driver terminated the app TAIL seconds ago; this is belt and braces.
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""
  wait_for_app_gone \
    || echo "capture: WARNING Jumbini is still registered with LaunchServices after $shot — the next take may measure its launch as instant"
  osascript "$HERE/stage-windows.applescript" close

  echo "capture: encoding $shot"
  dims=$(pixel_size "$RAW/$shot.mov")
  [ "$dims" = "$probe_dims" ] \
    || die "$shot recorded at $dims but the crop was resolved against $probe_dims — the display changed mid-run. Re-run this shot."

  # Where the dog's t=0 sits in this file. screencapture -V N writes N seconds
  # of content, so anything the process spent beyond that is warm-up plus
  # finalisation; attributing all of it to warm-up over-estimates it, which
  # trims a few frames EARLY rather than into the opening beat.
  content=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW/$shot.mov")
  warmup=$(calc "($t_stop - $t_rec) - $content")
  trim=$(calc "$LEAD - $warmup")
  if awk -v t="$trim" 'BEGIN { exit (t < 0) ? 0 : 1 }'; then
    echo "capture: WARNING screencapture took ${warmup}s to start recording $shot, longer than the ${LEAD}s lead."
    echo "capture: WARNING the opening beats are off camera. Raise LEAD in this script and re-shoot $shot."
    trim=0
  fi

  # The other half of the LEAD budget. The app must be up before its own t=0 at
  # t_rec + LEAD; if it was not, the driver's clock had already started, every
  # overdue beat came out in one tick, and the clip opens on an empty desktop.
  ready_at=$(calc "$t_ready - $t_rec")
  if awk -v r="$ready_at" -v l="$LEAD" 'BEGIN { exit (r > l) ? 0 : 1 }'; then
    echo "capture: WARNING $shot's app was not up until ${ready_at}s, past its t=0 at ${LEAD}s."
    echo "capture: WARNING the opening beats fired late and all at once. Raise LEAD in this script and re-shoot $shot."
  fi
  echo "capture: $shot warm-up ${warmup}s, app ready at ${ready_at}s of a ${LEAD}s lead, trimming ${trim}s of pre-roll"

  ffmpeg -y -loglevel error -ss "$trim" -i "$RAW/$shot.mov" -t "$duration" \
    -vf "$filter" -r 30 \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 23 \
    -movflags +faststart -an "$OUT/$shot.mp4"

  ffmpeg -y -loglevel error -ss "$trim" -i "$RAW/$shot.mov" -t "$duration" \
    -vf "$filter" -r 30 \
    -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -an "$OUT/$shot.webm"

  ffmpeg -y -loglevel error -ss "$(calc "$trim + 1")" -i "$RAW/$shot.mov" \
    -vf "$filter" -frames:v 1 -q:v 3 "$OUT/$shot.jpg"

  size=$(stat -f%z "$OUT/$shot.mp4")
  if [ "$size" -gt 2097152 ]; then
    echo "capture: WARNING $shot.mp4 is $((size / 1024))KB, over the 2MB budget"
  fi
done

echo "capture: done. Clips in $OUT"
echo "capture: review each one before publishing — a spontaneous wander can"
echo "capture: walk into a take, and the fix is to re-run that shot."
