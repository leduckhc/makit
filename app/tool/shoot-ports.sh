#!/usr/bin/env bash
# Screenshot the ports surfaces on a real iOS simulator, from the real app.
#
#   tool/shoot-ports.sh [outdir]
#
# Runs `integration_test/tour/ports_shots.dart` (which enters demo mode and walks
# the ports UI) and captures a PNG each time the camera path prints `SHOT <name>`.
# The pass holds ~5 s per scene, so the capture lands inside the hold.
#
# Why a simulator and not a widget golden: goldens rasterise the widget tree, and
# the thing worth proving here is that the shipping app — real store, real
# protocol frames, real sheets and dialogs — actually reaches these states.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-../.qa/shots}"
mkdir -p "$OUT"
SIM_NAME="${MAKIT_SIM_NAME:-iPhone 17}"
FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter)}"

sim_id() {
  xcrun simctl list devices available | awk -v name="$SIM_NAME" '
    index($0, name) { match($0, /\([0-9A-F-]+\)/);
      if (RSTART > 0) { print substr($0, RSTART + 1, RLENGTH - 2); exit } }'
}
SIM_ID="$(sim_id)"
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM_NAME" >&2; exit 1; }
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null

LOG="$(mktemp -t makit-shoot-ports.XXXXXX.log)"
echo "sim=$SIM_ID out=$OUT log=$LOG"

# Every scene the pass is expected to reach. A missing one is a FAILURE, not a
# quiet skip: the camera path tolerates absent surfaces (it must, to keep running
# on an older build), so without this list a regression that deletes the kill
# confirm or the orphans section would still exit 0 with a handful of PNGs.
REQUIRED_SHOTS=(
  01-home-glyph 02-sheet-list 03-sheet-detail 04-sheet-danger-zone
  05-kill-confirm 06-forward-confirm 07-ports-screen 07b-docker-row
  08-orphans-section 09-kill-all-confirm 10-orphans-killed
)

"$FLUTTER_BIN" test integration_test/tour/ports_shots.dart -d "$SIM_ID" >"$LOG" 2>&1 &
TEST_PID=$!
trap 'kill "$TEST_PID" 2>/dev/null || true' EXIT INT TERM

# Follow the log by LINE OFFSET rather than `tail -f`: BSD tail has no `--pid`,
# and a blocking `tail -f` never returns to the liveness check, so a test that
# dies early used to hang this script forever. Polling cannot block, and it
# drains whatever the test wrote before it exited.
shots=0
processed=0
done_marker=0

drain() {
  local total line name
  total="$(wc -l < "$LOG" | tr -d ' ')"
  [ "$total" -gt "$processed" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *"SHOT DONE"*) done_marker=1 ;;
      *"SHOT_SKIP "*) echo "  skipped: ${line#*SHOT_SKIP }" >&2 ;;
      *"SHOT "*)
        name="$(printf '%s' "$line" | sed -E 's/.*SHOT ([A-Za-z0-9_.-]+).*/\1/')"
        # A beat, so the hold's first frames (and any dialog animation) are done.
        sleep 1.2
        if xcrun simctl io "$SIM_ID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1; then
          shots=$((shots + 1))
          printf '  shot %-26s %s\n' "$name" "$OUT/$name.png"
        else
          echo "  FAILED to capture $name" >&2
        fi
        ;;
    esac
  done < <(sed -n "$((processed + 1)),${total}p" "$LOG")
  processed="$total"
}

while :; do
  drain
  [ "$done_marker" -eq 1 ] && break
  kill -0 "$TEST_PID" 2>/dev/null || { drain; break; }
  sleep 0.3
done

wait "$TEST_PID" 2>/dev/null; test_status=$?

echo "captured $shots screenshots into $OUT"

# A missing scene is a FAILURE, not a quiet skip: the camera path tolerates absent
# surfaces (it must, to keep running against an older build), so without this
# check a regression that deleted the kill confirm or the orphans section would
# still exit 0 with a handful of PNGs.
missing=()
for name in "${REQUIRED_SHOTS[@]}"; do
  [ -s "$OUT/$name.png" ] || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "MISSING scenes (a surface the pass expects is gone): ${missing[*]}" >&2
  echo "test log: $LOG" >&2
  exit 1
fi
if [ "$test_status" -ne 0 ]; then
  echo "the camera path itself failed (exit $test_status) — see $LOG" >&2
  exit "$test_status"
fi
echo "all ${#REQUIRED_SHOTS[@]} expected scenes present"
