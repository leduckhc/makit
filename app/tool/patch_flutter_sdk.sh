#!/usr/bin/env bash
# Patches the local Flutter SDK to work around two upstream bugs that make
# `flutter build/run` on macOS noisy or broken. Both are cosmetic/tooling
# issues — the app itself is fine.
#
# Because it patches the SDK in place, it must run after every `flutter
# upgrade`. It is idempotent — running it twice is a no-op — and the macOS
# Xcode build phase runs it automatically, so a plain `flutter run/build macos`
# self-heals.
#
# Remove this script once both fixes land in a Flutter stable release.
#
# 1. #188060 — macOS `--release` (AOT) crashes with "illegal cid, full-aot" in
#    _window_macos.dart because the tree-shaker drops experimental windowing
#    FFI structs. Fix: force-retain them with @pragma('vm:entry-point').
#
# 2. #182400 — impellerc compiles runtime shaders (e.g. liquid_glass_renderer)
#    to SkSL even on iOS/macOS where Skia is never used. The tool already
#    retries without SkSL and succeeds, but still dumps the entire SkSL
#    compiler stderr (hundreds of lines) on every build. Fix: downgrade that
#    dump from printError to printTrace so it only shows with `-v`; the concise
#    one-line "incompatible with SkSL" warning is kept.
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

window_file="$sdk_root/packages/flutter/lib/src/widgets/_window_macos.dart"
shader_file="$sdk_root/packages/flutter_tools/lib/src/build_system/tools/shader_compiler.dart"

# --- Fix 1: AOT windowing structs (#188060) ---------------------------------
if [[ -f "$window_file" ]]; then
  python3 - "$window_file" <<'PY'
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
    if re.search(re.escape(pragma) + r"\n" + re.escape(decl), src):
        continue
    src = src.replace(decl, f"{pragma}\n{decl}", 1)
    changed += 1
open(path, "w").write(src)
print(f"[188060] patched {changed} class(es); {len(classes) - changed} already patched")
PY
else
  echo "warn: $window_file not found (Flutter layout changed?)" >&2
fi

# --- Fix 2: silence irrelevant SkSL shader dump (#182400) -------------------
shader_changed=0
if [[ -f "$shader_file" ]]; then
  shader_changed=$(python3 - "$shader_file" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
old = (
    "          'shader will not load when running with the Skia backend.',\n"
    "        );\n"
    "        _logger.printError('impellerc failure: ${result.stderr}');"
)
new = (
    "          'shader will not load when running with the Skia backend.',\n"
    "        );\n"
    "        _logger.printTrace('impellerc failure: ${result.stderr}');"
)
if old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print(1)
else:
    print(0)
PY
)
  if [[ "$shader_changed" == "1" ]]; then
    echo "[182400] silenced SkSL stderr dump (kept one-line warning)"
    # The flutter tool runs from a cached snapshot that is NOT invalidated by a
    # source edit (only by git-revision/pubspec changes). Delete it so the next
    # `flutter` invocation recompiles the tool from the patched source.
    rm -f "$sdk_root/bin/cache/flutter_tools.snapshot" \
          "$sdk_root/bin/cache/flutter_tools.stamp"
  else
    echo "[182400] already patched"
  fi
else
  echo "warn: $shader_file not found (Flutter layout changed?)" >&2
fi

echo "OK: patched Flutter SDK at $sdk_root"
