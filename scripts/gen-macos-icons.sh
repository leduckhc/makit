#!/usr/bin/env bash
# Regenerate the macOS AppIcon set from assets/makit-icon-macos.svg.
# flutter_launcher_icons does not cover macOS, so this is done by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/assets/makit-icon-macos.svg"
OUT="$ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)" >&2; exit 1; }

for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$size" -h "$size" "$SRC" -o "$OUT/app_icon_$size.png"
done

echo "wrote app_icon_{16,32,64,128,256,512,1024}.png to $OUT"
