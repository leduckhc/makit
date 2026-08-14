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
#
# CONTRACT — this script exits non-zero if a patch does not apply.
# A patch that no longer matches means the bug is *back*, not fixed: the SkSL
# noise returns, or macOS `--release` crashes at launch. Both are far cheaper to
# learn about here than from a build. Anything other than "patched" or "already
# patched" is a hard failure naming the site that moved, so you can re-derive it
# (FLUTTER-BUMP-HANDOUT.md §5).
#
# Learned the hard way on Flutter 3.47.0: it moved the #182400 call site one
# nesting level deeper. The old literal-with-indentation anchor missed, and the
# script reported "already patched" on a completely unpatched file. Both fixes
# now match indentation-insensitively, and "anchor absent" is a distinct,
# loud state rather than being folded into "already patched".
#
# Covered by app/test/patch_flutter_sdk_test.dart.
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

# Both fixes are applied by one python pass: it owns locating the call sites,
# rewriting them, invalidating the flutter_tools snapshot, and deciding the exit
# code. Bash's only job is to resolve the SDK root above.
python3 - "$sdk_root" <<'PY'
import re
import sys
from pathlib import Path

sdk_root = Path(sys.argv[1])
window_file = sdk_root / "packages/flutter/lib/src/widgets/_window_macos.dart"
shader_file = (
    sdk_root
    / "packages/flutter_tools/lib/src/build_system/tools/shader_compiler.dart"
)

failures = []


def read(path):
    """Return the file's text, or None (recording a failure) if it is absent.

    A missing file is a hard failure: the patch cannot have been applied, and
    the SDK layout moving is exactly the case that needs a human.
    """
    if not path.is_file():
        failures.append(
            f"{path} not found — Flutter's layout changed; re-derive the patch"
        )
        return None
    return path.read_text()


# --- Fix 1: AOT windowing structs (#188060) ---------------------------------
# Matched on the declaration alone, so reformatting of the struct body cannot
# break it. A class that has vanished is reported by name, never as "already
# patched" — a rename means the tree-shaker drops it again and macOS --release
# crashes at launch.
CLASSES = ["_WindowCreationRequest", "_Size", "_Offset", "_Rect", "_Constraints"]
PRAGMA = "@pragma('vm:entry-point')"

src = read(window_file)
if src is not None:
    patched, already, missing = [], [], []
    for name in CLASSES:
        decl = re.compile(
            r"^(?P<indent>[ \t]*)final class " + re.escape(name) + r"\b[^\n{]*\{",
            re.MULTILINE,
        )
        m = decl.search(src)
        if m is None:
            missing.append(name)
            continue
        preceding = src[: m.start()].rstrip()
        if preceding.endswith(PRAGMA):
            already.append(name)
            continue
        src = (
            src[: m.start()]
            + f"{m.group('indent')}{PRAGMA}\n"
            + src[m.start() :]
        )
        patched.append(name)

    if patched:
        window_file.write_text(src)
    print(
        f"[188060] patched {len(patched)} class(es); {len(already)} already patched"
    )
    if missing:
        failures.append(
            "[188060] struct(s) not found: "
            + ", ".join(missing)
            + " — upstream renamed or removed them. Re-derive the patch; "
            "without it macOS --release crashes with 'illegal cid, full-aot'."
        )

# --- Fix 2: silence irrelevant SkSL shader dump (#182400) -------------------
# Anchored on the user-visible warning text and tolerant of leading whitespace,
# because the call site's nesting depth is not stable across releases (3.47.0
# moved it one level deeper). Only the dump that follows the Skia-backend
# warning is downgraded — the other `impellerc failure:` call sites are real
# errors and must keep shouting.
ANCHOR = re.compile(
    r"shader will not load when running with the Skia backend\.',\n"
    r"\s*\);\n"
    r"\s*_logger\.print(?P<level>Error|Trace)"
    r"\('impellerc failure: \$\{result\.stderr\}'\);"
)

src = read(shader_file)
if src is not None:
    m = ANCHOR.search(src)
    if m is None:
        failures.append(
            "[182400] the SkSL dump call site was not found — upstream moved or "
            "fixed it. Verify which, then re-derive or delete this fix. Left "
            "unpatched, every macOS/iOS build dumps hundreds of SkSL lines."
        )
    elif m.group("level") == "Trace":
        print("[182400] already patched")
    else:
        start, end = m.span("level")
        shader_file.write_text(src[:start] + "Trace" + src[end:])
        print("[182400] silenced SkSL stderr dump (kept one-line warning)")
        # The flutter tool runs from a cached snapshot that is NOT invalidated
        # by a source edit (only by git-revision/pubspec changes). Delete it so
        # the next `flutter` invocation recompiles the tool from the patched
        # source.
        for stale in ("flutter_tools.snapshot", "flutter_tools.stamp"):
            (sdk_root / "bin" / "cache" / stale).unlink(missing_ok=True)

if failures:
    print("", file=sys.stderr)
    for f in failures:
        print(f"error: {f}", file=sys.stderr)
    print(
        "\nSee FLUTTER-BUMP-HANDOUT.md §5. Do not assume the bug is fixed "
        "because the patch stopped applying — check upstream first.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"OK: patched Flutter SDK at {sdk_root}")
PY
