#!/usr/bin/env bash
# Workaround for Flutter issue #188060: macOS `--release` (AOT) builds crash
# with "Unexpected object (Class with illegal cid, full-aot)" in
# _window_macos.dart because the AOT tree-shaker drops the experimental
# windowing FFI structs. Forcing them to be retained with
# @pragma('vm:entry-point') fixes it.
#
# This patches the Flutter SDK in place, so it must be re-run after every
# `flutter upgrade` (and on any machine/CI that builds the macOS release).
# It is idempotent — running it twice is a no-op.
#
# Remove this script once the upstream fix lands in a Flutter stable release.
set -euo pipefail

# Locate the Flutter SDK. Xcode build phases export FLUTTER_ROOT but have no
# `flutter` on PATH; CLI use has `flutter` on PATH but not FLUTTER_ROOT. Try
# both so this works from the macOS build phase and from a terminal.
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  sdk_root="$FLUTTER_ROOT"
else
  flutter_bin="$(command -v flutter || true)"
  if [[ -z "$flutter_bin" ]]; then
    echo "error: set FLUTTER_ROOT or put flutter on PATH" >&2
    exit 1
  fi
  sdk_root="$(cd "$(dirname "$(readlink -f "$flutter_bin" 2>/dev/null || echo "$flutter_bin")")/.." && pwd)"
fi
target="$sdk_root/packages/flutter/lib/src/widgets/_window_macos.dart"

if [[ ! -f "$target" ]]; then
  echo "error: $target not found (Flutter layout changed?)" >&2
  exit 1
fi

python3 - "$target" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
classes = ["_WindowCreationRequest", "_Size", "_Offset", "_Rect", "_Constraints"]
pragma = "@pragma('vm:entry-point')"
changed = 0
for name in classes:
    decl = f"final class {name} extends Struct {{"
    if decl not in src:
        continue
    # Skip if the pragma already sits directly above the declaration.
    if re.search(re.escape(pragma) + r"\n" + re.escape(decl), src):
        continue
    src = src.replace(decl, f"{pragma}\n{decl}", 1)
    changed += 1
open(path, "w").write(src)
print(f"patched {changed} class(es); {len(classes) - changed} already patched")
PY

echo "OK: $target"
