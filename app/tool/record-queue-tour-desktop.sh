#!/usr/bin/env bash
# Films the pending-queue tour (SPEC-35/36) on the **macOS desktop** surface.
#
# Counterpart to tool/record-queue-tour.sh, which films the iOS simulator with
# `simctl io recordVideo`. There is no such backdoor for a real Mac window, and
# a plain `screencapture -v` / `ffmpeg -f avfoundation` needs a Screen Recording
# grant the calling terminal usually does not have (it hangs on the prompt).
# So the camera here is **cua-driver**, which records via ScreenCaptureKit under
# its OWN grant (CuaDriver.app) — see .agents/skills/makit-computer-use/SKILL.md.
#
# Like the iOS tour this needs a LIVE server: the queue only exists while an
# agent is busy, and every step goes over the real wire. It boots
# server/test/e2e-server.ts with the StubAdapter (deterministic, keyless).
#
# Usage: tool/record-queue-tour-desktop.sh [output.mp4]
set -euo pipefail

OUT="${1:-/tmp/makit-pending-queue-desktop.mp4}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_DIR="$ROOT/server"
APP_DIR="$ROOT/app"
# Overridable: 9787 is the shared e2e port, so a run in ANOTHER worktree holds
# it and this one dies at startup ("port is already in use").
PORT="${MAKIT_E2E_PORT:-9787}"
BEARER="e2e-token"
# NOT under /tmp: cua-driver's path-scope check rejects an output dir whose
# ancestor is a symlink (/tmp → /private/tmp) with
# `protected_resource_scope_invalid`, and the `recording` CLI wrapper reports
# that as a successful start with no video.
REC_DIR="$HOME/cua-trajectories/makit-queue-desktop-$(date +%s)"

FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found — set MAKIT_FLUTTER_BIN or add flutter to PATH" >&2
  exit 1
fi
CUA_BIN="${MAKIT_CUA_DRIVER_CMD:-$(command -v cua-driver || true)}"
if [[ -z "$CUA_BIN" ]]; then
  echo "cua-driver not found — install it (see the makit-computer-use skill)" >&2
  exit 1
fi

# Recording is per-daemon-process state, so the daemon must be up, and it must
# hold the Screen Recording grant or the mp4 comes out empty.
if ! "$CUA_BIN" permissions status 2>/dev/null | grep -q "Screen Recording: ✅"; then
  echo "cua-driver lacks the Screen Recording grant — run: cua-driver permissions grant" >&2
  exit 1
fi

MAKIT_HOME="$(mktemp -d -t makit-queue-desktop-home.XXXXXX)"
export MAKIT_HOME
SERVER_LOG="$(mktemp -t makit-queue-desktop-server.XXXXXX.log)"
SERVER_PID=""
RECORDING=0

cleanup() {
  if (( RECORDING )); then
    "$CUA_BIN" stop_recording '{}' >/dev/null 2>&1 || true
    RECORDING=0
  fi
  if [[ -n "$SERVER_PID" ]]; then
    pkill -f "e2e-server.ts --mode stub --port $PORT --project $ROOT" >/dev/null 2>&1 || true
  fi
  rm -rf "$MAKIT_HOME" >/dev/null 2>&1 || true
  rm -f "$SERVER_LOG" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

(
  cd "$SERVER_DIR"
  pnpm exec tsx test/e2e-server.ts --mode stub --port "$PORT" --project "$ROOT"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

READY_JSON=""
for _ in {1..300}; do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "stub server exited before ready; log:" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  READY_JSON="$(grep -m1 '"ready":true' "$SERVER_LOG" || true)"
  [[ -n "$READY_JSON" ]] && break
  sleep 0.1
done
if [[ -z "$READY_JSON" ]]; then
  echo "timed out waiting for the stub server; log:" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi
FP="$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(j.fp ?? "")' <<<"$READY_JSON")"
if [[ -z "$FP" ]]; then
  echo "server ready line carried no cert fingerprint; log:" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi
echo "stub server ready on :$PORT"

mkdir -p "$REC_DIR"
# The raw tool, NOT `cua-driver recording start`: the CLI wrapper leaves
# `video_active: false` (verified via get_recording_state) and reports a
# successful start anyway, so the run ends with turn folders and no mp4.
"$CUA_BIN" start_recording "{\"output_dir\":\"$REC_DIR\",\"record_video\":true}" >/dev/null
RECORDING=1
echo "recording → $REC_DIR"

# `flutter test -d macos` launches the app but often fails to foreground it
# ("Failed to foreground app; open returned 1"), which would film whatever is on
# top instead. Keep raising it in the background for the length of the run.
# Frame the shot: the test window opens small and wherever macOS puts it, so a
# full-screen capture is mostly the developer's other windows. Front it, plant it
# at a known frame, and record that frame for the ffmpeg crop below.
#
# Everything here matches on the *pid* of the debug binary, never on the app
# name: a developer running the real Makit.app has a second window also called
# "Makit", and an app-name match would front — or worse, MOVE — their window.
WIN_X=40
WIN_Y=60
WIN_W=1280
WIN_H=860
FRAME_FILE="$REC_DIR/window-frame.json"
(
  # 240 tries, not 60: the macOS build+launch can eat a minute on its own, and a
  # loop that expires first leaves the recorder filming the developer's desktop.
  #
  # Every substitution here ends in `|| true`. Under `set -euo pipefail` a
  # `pgrep | head` pipeline that matches nothing fails the whole assignment, and
  # this subshell died on its FIRST iteration — before the app had even launched
  # — which is why the window was never found in any run.
  for _ in $(seq 1 240); do
    PID="$(pgrep -f "Build/Products/Debug/Makit.app/Contents/MacOS/Makit" | head -1 || true)"
    # Diagnosable on failure: without this, "no window frame" gives no clue
    # whether the process, the window, or set_window_frame was the problem.
    echo "$(date +%T) pid=${PID:-none}" >>"$REC_DIR/window-hunt.log"
    if [[ -n "$PID" ]]; then
      "$CUA_BIN" bring_to_front "{\"pid\":$PID}" >/dev/null 2>&1 || true
      WID="$("$CUA_BIN" list_windows '{}' 2>/dev/null \
        | PID="$PID" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
            try{const j=JSON.parse(s);
              // Largest AREA, min 200x200: the app also owns a 1512x33 menu-bar
              // window, which a width-only test matched — the run then filmed a
              // 34px sliver of the top of the screen.
              const ws=(j.windows??[]).filter(w=>String(w.pid)===process.env.PID&&w.layer===0&&(w.bounds?.width??0)>200&&(w.bounds?.height??0)>200);
              ws.sort((a,b)=>(b.bounds.width*b.bounds.height)-(a.bounds.width*a.bounds.height));
              process.stdout.write(String(ws[0]?.window_id??""));}catch{}
          })' || true)"
      echo "$(date +%T) pid=$PID wid=${WID:-none}" >>"$REC_DIR/window-hunt.log"
      if [[ -n "$WID" ]]; then
        "$CUA_BIN" set_window_frame \
          "{\"pid\":$PID,\"window_id\":$WID,\"x\":$WIN_X,\"y\":$WIN_Y,\"width\":$WIN_W,\"height\":$WIN_H}" \
          >/dev/null 2>&1 || true
        # ALWAYS read the geometry back, never trust the requested frame. A run
        # that wrote the *requested* rectangle cropped 1280x860 out of the
        # developer's desktop — browser, terminals, everything — because the move
        # reported success while the window stayed where it was. The crop must
        # describe where this pid's window actually IS.
        sleep 1
        "$CUA_BIN" list_windows '{}' 2>/dev/null \
          | PID="$PID" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
              try{const j=JSON.parse(s);
                // Largest AREA, min 200x200: the app also owns a 1512x33 menu-bar
                // window, which a width-only test matched — the run then filmed a
                // 34px sliver of the top of the screen.
                const ws=(j.windows??[]).filter(w=>String(w.pid)===process.env.PID&&w.layer===0&&(w.bounds?.width??0)>200&&(w.bounds?.height??0)>200);
                ws.sort((a,b)=>(b.bounds.width*b.bounds.height)-(a.bounds.width*a.bounds.height));
                if(ws[0])process.stdout.write(JSON.stringify(ws[0].bounds));}catch{}
            })' >"$FRAME_FILE" || true
        break
      fi
    fi
    sleep 1
  done
) &
FOCUS_PID="$!"

TOUR_LOG="$REC_DIR/tour.log"
set +e
(
  cd "$APP_DIR"
  "$FLUTTER_BIN" test --no-pub \
    -d macos \
    --dart-define=MAKIT_TEST_HOST=127.0.0.1 \
    --dart-define=MAKIT_TEST_PORT="$PORT" \
    --dart-define=MAKIT_TEST_BEARER="$BEARER" \
    --dart-define=MAKIT_TEST_FP="$FP" \
    integration_test/tour/desktop_pending_queue_tour.dart 2>&1 | tee "$TOUR_LOG"
  exit "${PIPESTATUS[0]}"
)
TOUR_STATUS=$?
set -e
kill "$FOCUS_PID" >/dev/null 2>&1 || true

sleep 1
"$CUA_BIN" stop_recording '{}' >/dev/null 2>&1 || true
RECORDING=0

RAW="$REC_DIR/recording.mp4"
# `stop_recording` returns before the file is finalised: the mp4's `moov` atom is
# written last, so an immediate copy yields a same-size file ffmpeg cannot open
# ("moov atom not found"). Wait until it actually demuxes.
for _ in $(seq 1 60); do
  [[ -s "$RAW" ]] && ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW" >/dev/null 2>&1 && break
  sleep 1
done
if ! ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW" >/dev/null 2>&1; then
  echo "cua-driver produced no readable video at $RAW" >&2
  exit 1
fi
# Crop to the window frame recorded above, scaled for a Retina capture (the mp4
# comes back in backing-store pixels; window bounds are logical points).
CROP=""
if [[ -s "$FRAME_FILE" ]]; then
  REC_W="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$RAW" 2>/dev/null || echo 0)"
  DESK_W="$("$CUA_BIN" list_windows '{}' 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(Math.round((j.windows??[]).reduce((m,w)=>Math.max(m,(w.bounds?.x??0)+(w.bounds?.width??0)),0))));}catch{process.stdout.write("0")}})' || echo 0)"
  CROP="$(REC_W="$REC_W" DESK_W="$DESK_W" node -e 'const fs=require("fs");
    const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const rw=Number(process.env.REC_W)||0, dw=Number(process.env.DESK_W)||0;
    const k=(rw>0&&dw>0&&rw/dw>=1.5)?2:1;
    const r=n=>Math.max(2,Math.round(n*k/2)*2);
    process.stdout.write(`${r(b.width)}:${r(b.height)}:${r(b.x)}:${r(b.y)}`);' "$FRAME_FILE" 2>/dev/null || true)"
fi
# Fail CLOSED. A full-display capture of someone's Mac is not a fallback: this
# script once shipped a recording of the developer's own windows (including an
# unrelated app with personal data) because the window lookup expired and the
# uncropped file was kept "so there is something". Without a verified window
# frame the footage is destroyed instead.
if [[ -z "$CROP" ]]; then
  # Delete the VIDEO, keep the hunt log: the previous version removed the whole
  # directory and took the only evidence of why the window was never found.
  rm -f "$RAW" "$OUT"
  echo "window hunt log: $REC_DIR/window-hunt.log" >&2
  echo "could not locate the Makit test window — footage DELETED rather than" >&2
  echo "kept, because an uncropped capture films the whole desktop." >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  rm -f "$RAW"
  echo "ffmpeg is required to crop the capture to the app window" >&2
  exit 1
fi
ffmpeg -y -loglevel error -i "$RAW" -vf "crop=$CROP" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT"
# The uncropped original contains everything else that was on screen; it is not
# an artifact anyone asked for.
rm -f "$RAW"

if [[ $TOUR_STATUS -ne 0 ]]; then
  echo "tour failed (status $TOUR_STATUS); footage kept at $OUT" >&2
  exit "$TOUR_STATUS"
fi
echo "wrote $OUT"
