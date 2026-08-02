#!/usr/bin/env bash
# Films the mobile parity tour on a booted iOS simulator.
#
# Records the simulator screen with `simctl io recordVideo` while
# integration_test/tour/mobile_parity_tour.dart drives the UI, then re-encodes
# the result to a shareable mp4 with ffmpeg.
#
# Usage: tool/record-tour.sh [output.mp4]
set -euo pipefail

OUT="${1:-/tmp/mobile-parity-tour.mp4}"
RAW="$(mktemp -t makit-tour.XXXXXX).mov"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE_ID="dev.getmakit.app"
FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter || true)}"

if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found — set MAKIT_FLUTTER_BIN or add flutter to PATH" >&2
  exit 1
fi

DEVICE_ID="$(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
ids=[x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"]
print(ids[0] if ids else "")')"

if [[ -z "$DEVICE_ID" ]]; then
  echo "no booted simulator - boot one in Simulator.app first" >&2
  exit 1
fi
echo "recording on $DEVICE_ID"

# The tour needs a first-run app: a previous e2e run leaves paired credentials in
# the keychain, which sends the app to a dead server instead of the demo door.
xcrun simctl uninstall "$DEVICE_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true

REC_PID=""
cleanup() {
  # SIGINT (not SIGKILL): simctl only finalises the movie container on a clean
  # stop, so a killed recorder leaves an unplayable file.
  if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
    kill -INT "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Drive the UI in the background. `flutter test -d` spends its first ~20s on the
# Xcode build and install, which is dead footage, so the recorder is started only
# once the app is actually running on the device (below).
TOUR_LOG="$(mktemp -t makit-tour-log.XXXXXX)"
(cd "$APP_DIR" && "$FLUTTER_BIN" test --no-pub \
  -d "$DEVICE_ID" integration_test/tour/mobile_parity_tour.dart) \
  >"$TOUR_LOG" 2>&1 &
TOUR_PID=$!

app_running() {
  # `flutter test` prints the test name once the app is up on the device and the
  # harness has connected, which is exactly when there is something to film.
  grep -q 'mobile parity tour' "$TOUR_LOG" 2>/dev/null
}

echo "waiting for the app to launch..."
for _ in $(seq 1 180); do
  app_running && break
  # Bail out early if the tour died during build/install.
  kill -0 "$TOUR_PID" 2>/dev/null || break
  sleep 1
done

if app_running; then
  xcrun simctl io "$DEVICE_ID" recordVideo --codec h264 --force "$RAW" &
  REC_PID=$!
else
  echo "app never launched - see $TOUR_LOG" >&2
fi

set +e
wait "$TOUR_PID"
TOUR_STATUS=$?
set -e
cat "$TOUR_LOG" | grep -vE '^\[makit\] ws connect' || true

# The app exits during teardown, so stop straight away rather than filming the
# springboard.
cleanup
REC_PID=""

if [[ ! -s "$RAW" ]]; then
  echo "recording produced no file" >&2
  exit 1
fi

ffmpeg -y -loglevel error -i "$RAW" -vf "scale=trunc(iw/4)*2:trunc(ih/4)*2" -r 30 \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT"
rm -f "$RAW"

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
[[ $TOUR_STATUS -eq 0 ]] || echo "note: the tour itself failed (exit $TOUR_STATUS)" >&2
exit $TOUR_STATUS
