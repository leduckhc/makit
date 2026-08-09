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

"$FLUTTER_BIN" test integration_test/tour/ports_shots.dart -d "$SIM_ID" >"$LOG" 2>&1 &
TEST_PID=$!
trap 'kill "$TEST_PID" 2>/dev/null || true' EXIT INT TERM

# Follow the log and shoot on each marker. `SHOT DONE` (or the test exiting) ends
# the loop; a missing marker is reported rather than silently producing nothing.
shots=0
while kill -0 "$TEST_PID" 2>/dev/null; do
  while IFS= read -r line; do
    case "$line" in
      *"SHOT DONE"*) break 2 ;;
      *"SHOT "*)
        name="$(printf '%s' "$line" | sed -E 's/.*SHOT ([A-Za-z0-9_.-]+).*/\1/')"
        # A beat, so the hold's first frames (and any dialog animation) are done.
        sleep 1.2
        xcrun simctl io "$SIM_ID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 \
          && { shots=$((shots + 1)); printf '  shot %-26s %s\n' "$name" "$OUT/$name.png"; } \
          || echo "  FAILED to capture $name" >&2
        ;;
    esac
  done < <(tail -n +1 -f "$LOG")
done

wait "$TEST_PID" 2>/dev/null || true
echo "captured $shots screenshots into $OUT"
[ "$shots" -gt 0 ] || { echo "no screenshots captured — check $LOG" >&2; exit 1; }
