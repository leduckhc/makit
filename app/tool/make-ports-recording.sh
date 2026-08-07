#!/usr/bin/env bash
# Assemble the ports-popover recording from the frames captured by
# `test/sim/ports_record_test.dart` into GIFs that GitHub renders inline.
#
#   1. server:  pnpm exec tsx tool/capture-ports-snapshot.ts <repo> 3 > /tmp/ports-snapshot.json
#   2. app:     PORTS_RECORD=1 flutter test --no-pub --update-goldens test/sim/ports_record_test.dart
#   3. app:     tool/make-ports-recording.sh   (writes ../docs/media/*.gif)
#
# GIF, not MP4: GitHub renders a committed .gif inline from a raw URL, but a
# committed .mp4 only downloads (video must go through their web uploader).
set -euo pipefail
cd "$(dirname "$0")/.."

FPS=12
WIDTH=900          # frames are captured at dpr 2; halve for a sane file size
OUT=../docs/media
mkdir -p "$OUT"

for theme in light dark; do
  src="test/sim/frames/$theme"
  [ -d "$src" ] || { echo "no frames for $theme — run the record test first" >&2; exit 1; }

  # Two-pass palette: a single global palette keeps the tinted pills from
  # dithering into mush, which is exactly what the recording is meant to show.
  palette="$(mktemp -t portspal).png"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -framerate "$FPS" -i "$src/f%03d.png" \
    -vf "scale=$WIDTH:-2:flags=lanczos,palettegen=stats_mode=diff" "$palette"

  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -framerate "$FPS" -i "$src/f%03d.png" -i "$palette" \
    -lavfi "scale=$WIDTH:-2:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
    -loop 0 "$OUT/ports-popover-$theme.gif"
  rm -f "$palette"

  printf '%-34s %s\n' "$OUT/ports-popover-$theme.gif" "$(du -h "$OUT/ports-popover-$theme.gif" | cut -f1)"
done
