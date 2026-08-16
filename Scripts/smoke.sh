#!/bin/bash
# Launch the bundled app and prove it survives startup.
#
# bundle.sh proves the .app can be *assembled*. Nothing proved it runs, and the
# gap was not theoretical: every release from v3.0 to v4.4 was built, tested,
# signed, notarized and published while crashing about a second into launch on
# every Mac except the one that built it.
#
# The cause is worth knowing, because it is exactly the shape of bug this
# script exists to catch. SwiftPM's generated `Bundle.module` looks beside
# Bundle.main.bundleURL and then at the absolute .build path of whichever
# machine compiled the binary. That second path is the developer's own
# directory, so a locally assembled app found its resources and worked
# perfectly, while the identical bundle trapped everywhere else. Every check in
# the pipeline passed. None of them started the binary.
#
# So the check here is deliberately dumb: start it, wait, is it still there.
# Startup traps -- a nil unwrap, a failed precondition, a resource bundle that
# cannot be found -- all land within the first second or so, comfortably inside
# the window. It does not need to know what it is looking for.
#
# Usage:
#   ./Scripts/smoke.sh                       # smoke test build/Jumbini.app
#   ./Scripts/smoke.sh /path/to/Jumbini.app
#   SMOKE_SECONDS=15 ./Scripts/smoke.sh      # wait longer before declaring it alive

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Jumbini.app}"
SECS="${SMOKE_SECONDS:-8}"

die() { echo "error: $*" >&2; exit 1; }

[ -d "$APP" ] || die "no app bundle at $APP (run Scripts/bundle.sh first)"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || die "no Info.plist in $APP"

NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
[ -n "$NAME" ] || die "could not read CFBundleExecutable from $PLIST"

BIN="$APP/Contents/MacOS/$NAME"
[ -x "$BIN" ] || die "no executable at $BIN"

# ---------------------------------------------------------------------------
# The resource bundle, checked separately.
#
# The launch test below cannot see this one: an *empty* resource bundle still
# resolves, so the app starts happily, stays up, and simply draws nothing. That
# would sail through a liveness check while shipping an invisible dog.
# ---------------------------------------------------------------------------

RES_COUNT=0
for bundle in "$APP"/Contents/Resources/*.bundle; do
  [ -d "$bundle" ] || continue
  RES_COUNT=$(( RES_COUNT + $(find "$bundle" -type f -name '*.png' | wc -l) ))
done
[ "$RES_COUNT" -gt 0 ] \
  || die "no sprites found in any .bundle under $APP/Contents/Resources
       The resource bundle is missing or empty. bundle.sh copies it out of
       .build/release; check that \`swift build -c release\` emitted one."
echo "    $RES_COUNT sprite(s) in the resource bundle"

# ---------------------------------------------------------------------------
# Launch it.
# ---------------------------------------------------------------------------

LOG="$(mktemp -t jumbini-smoke)"
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

# Note which crash report was newest *before* launching, so that if the app
# dies we report the one this run produced rather than a stale one from an
# earlier attempt. On a fresh runner there is usually none at all.
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
BEFORE="$(ls -t "$CRASH_DIR/$NAME"-*.ips 2>/dev/null | head -1 || true)"

echo "    launching $BIN"
"$BIN" >"$LOG" 2>&1 &
PID=$!

for (( i = 1; i <= SECS; i++ )); do
  sleep 1
  if kill -0 "$PID" 2>/dev/null; then
    continue
  fi

  # It exited on its own. For an LSUIElement agent app that runs until it is
  # told to quit, any exit at all is a failure -- clean status included.
  STATUS=0
  wait "$PID" || STATUS=$?
  PID=""

  echo >&2
  echo "error: $NAME exited after ${i}s with status $STATUS." >&2
  echo "       A menu bar agent should still be running. This is a startup crash." >&2

  if [ -s "$LOG" ]; then
    echo >&2
    echo "--- output ---" >&2
    cat "$LOG" >&2
  fi

  # The .ips holds the faulting backtrace, which is the difference between
  # "it crashed" and "it crashed in setUpStatusItem resolving Bundle.module".
  #
  # ReportCrash writes it asynchronously, a beat after the process is already
  # gone, so looking the instant we notice the exit finds nothing. Poll briefly
  # rather than sleeping a fixed amount: usually it is there by the first check.
  AFTER=""
  for (( wait_ips = 0; wait_ips < 5; wait_ips++ )); do
    AFTER="$(ls -t "$CRASH_DIR/$NAME"-*.ips 2>/dev/null | head -1 || true)"
    [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ] && break
    sleep 1
  done
  if [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then
    echo >&2
    echo "--- crash report: $AFTER ---" >&2
    python3 - "$AFTER" >&2 <<'PY' || true
import json, sys

# An .ips is a one-line JSON header followed by a JSON body.
with open(sys.argv[1], encoding="utf-8") as fh:
    fh.readline()
    report = json.load(fh)

exc = report.get("exception", {})
print("exception: %s  signal: %s" % (exc.get("type"), exc.get("signal")))

images = report.get("usedImages", [])
thread = report.get("threads", [])[report.get("faultingThread", 0)]
for frame in thread.get("frames", [])[:12]:
    name = images[frame["imageIndex"]].get("name", "?")
    print("  %-24s %s" % (name, frame.get("symbol", "")))
PY
  fi

  exit 1
done

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""

echo "OK: $NAME stayed up for ${SECS}s"
