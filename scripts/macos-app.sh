#!/usr/bin/env bash
#
# One-stop macOS build: compiles the Flutter app (debug or release), embeds the
# self-contained `makit` CLI into Contents/Resources/makit/ (incrementally —
# skipped when the server sources are unchanged), and optionally opens the app.
#
# Usage:
#   scripts/macos-app.sh [debug|release] [--open] [--skip-build]
#
#     debug|release   Flutter build mode (default: debug).
#     --open          launch the built .app when done.
#     --skip-build    don't run `flutter build macos`; just (re)embed the CLI
#                     into the existing .app (and open it with --open).
#
# Examples:
#   scripts/macos-app.sh --open                 # debug build + CLI + launch
#   scripts/macos-app.sh release --open         # release build + CLI + launch
#   scripts/macos-app.sh debug --skip-build     # refresh embedded CLI only
#
# Incremental embed: everything the CLI bundle derives from (server sources,
# lockfiles, tsconfig, the bundle script, pinned NODE_VERSION/NODE_ARCH) is
# fingerprinted into a stamp file inside the bundle; same fingerprint + bundle
# present → the slow assemble step (pnpm install/tsc/Node download) is skipped.
#
# NOTE (release distribution): this does NOT codesign/notarize. For shipping,
# follow BUILD_AND_DEPLOY.md — the bundled node/makit must be signed with
# BundledNode.entitlements after embedding.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Args ----------------------------------------------------------------------
MODE="debug"
OPEN=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    debug|release) MODE="$arg" ;;
    --open)        OPEN=1 ;;
    --skip-build)  SKIP_BUILD=1 ;;
    *) echo "usage: scripts/macos-app.sh [debug|release] [--open] [--skip-build]" >&2
       exit 2 ;;
  esac
done

# Capitalized product dir: Debug / Release.
MODE_DIR="$(tr '[:lower:]' '[:upper:]' <<< "${MODE:0:1}")${MODE:1}"
APP="$ROOT/app/build/macos/Build/Products/$MODE_DIR/makit.app"

FLUTTER="${FLUTTER:-$(command -v flutter)}"
[[ -x "$FLUTTER" ]] || {
  echo "macos-app: flutter not found (set \$FLUTTER)" >&2; exit 1; }

# --- 1. Build the Flutter app ----------------------------------------------------
if [[ "$SKIP_BUILD" == 0 ]]; then
  echo "==> flutter build macos --$MODE"
  (cd "$ROOT/app" && "$FLUTTER" build macos "--$MODE")
fi

if [[ ! -d "$APP" ]]; then
  echo "macos-app: no .app at $APP (build failed or --skip-build without a prior build)" >&2
  exit 1
fi

# --- 2. Embed the makit CLI (incremental) ---------------------------------------
TARGET="$APP/Contents/Resources/makit"
STAMP="$TARGET/.fingerprint"
NODE_VERSION="${NODE_VERSION:-22.20.0}"
NODE_ARCH="${NODE_ARCH:-arm64}"

fingerprint() {
  {
    echo "node=$NODE_VERSION-$NODE_ARCH"
    find "$ROOT/server/src" -type f \( -name '*.ts' -o -name '*.json' \) \
      ! -name '*.test.ts' -print0 | sort -z | xargs -0 shasum -a 256
    shasum -a 256 \
      "$ROOT/server/package.json" \
      "$ROOT/server/tsconfig.json" \
      "$ROOT/scripts/bundle-makit-cli.sh"
    shasum -a 256 "$ROOT/pnpm-lock.yaml" "$ROOT/server/pnpm-lock.yaml" \
      2>/dev/null || true
  } | shasum -a 256 | cut -d' ' -f1
}

WANT="$(fingerprint)"
HAVE="$(cat "$STAMP" 2>/dev/null || true)"

if [[ "$WANT" == "$HAVE" && -x "$TARGET/makit" && -x "$TARGET/node" ]]; then
  echo "==> embedded CLI up to date — skipping assemble."
else
  echo "==> embedding makit CLI into $TARGET …"
  NODE_VERSION="$NODE_VERSION" NODE_ARCH="$NODE_ARCH" \
    "$ROOT/scripts/bundle-makit-cli.sh" "$TARGET"
  echo "$WANT" > "$STAMP"
fi

# --- 3. Open ---------------------------------------------------------------------
echo "==> ready: $APP"
if [[ "$OPEN" == 1 ]]; then
  open "$APP"
fi
