#!/usr/bin/env bash
#
# Assemble a self-contained `makit` CLI so the desktop app can ship it inside
# `makit.app/Contents/Resources/makit/` (the resolver's preferred, zero-install
# path — see app/lib/desktop/daemon/daemon_lifecycle.dart). No repo, no global
# Node, and no `tsx` are required at runtime.
#
# Bundle layout (self-contained, relocatable):
#   <target>/
#     node               # the official Node runtime (nodejs.org build)
#     dist/…             # compiled server (tsc output)
#     node_modules/…     # prod-only, hoisted deps (pnpm deploy)
#     makit              # POSIX shim: exec ./node ./dist/src/index.js "$@"
#
# We deliberately fetch the *official* nodejs.org binary rather than copying the
# build host's `node`: Homebrew's node is dynamically linked against
# @rpath/libnode.dylib + ICU and is NOT relocatable. The official build links
# only system frameworks, so it runs from anywhere inside the .app bundle.
#
# The shim keeps the daemon self-respawn model intact: service.ts spawns
# `execPath [entry, "serve", …]`, which here is `<bundle>/node <bundle>/dist/
# src/index.js serve …`.
#
# Usage:
#   scripts/bundle-makit-cli.sh [TARGET_DIR]
#     TARGET_DIR defaults to server/build/cli-bundle.
#
# Env overrides:
#   NODE_VERSION   pinned Node runtime to bundle (default below; must satisfy
#                  server/package.json engines: node >=22.13).
#   NODE_ARCH      darwin arch to fetch: arm64 (default) or x64.
#
# NOTE: bundles a single-arch Node. A universal (arm64+x86_64) app needs a
# per-arch copy or a lipo'd binary; that is a follow-up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
TARGET="${1:-$SERVER_DIR/build/cli-bundle}"
# Absolutize before we cd into SERVER_DIR, so a relative TARGET stays anchored
# to the caller's cwd rather than server/.
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
NODE_VERSION="${NODE_VERSION:-22.20.0}"
NODE_ARCH="${NODE_ARCH:-arm64}"

echo "==> Compiling server (tsc) …"
cd "$SERVER_DIR"
pnpm install --frozen-lockfile
pnpm build

echo "==> Collecting prod dependencies (pnpm deploy) …"
DEPLOY_DIR="$(mktemp -d)"
trap 'rm -rf "$DEPLOY_DIR"' EXIT
pnpm deploy --filter=@makit/server --prod --legacy "$DEPLOY_DIR"

echo "==> Fetching official Node v$NODE_VERSION ($NODE_ARCH) …"
NODE_PKG="node-v$NODE_VERSION-darwin-$NODE_ARCH"
NODE_TMP="$(mktemp -d)"
trap 'rm -rf "$DEPLOY_DIR" "$NODE_TMP"' EXIT
curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$NODE_PKG.tar.gz" \
  | tar xz -C "$NODE_TMP"

echo "==> Assembling bundle at $TARGET …"
rm -rf "$TARGET"
mkdir -p "$TARGET"
cp -R "$SERVER_DIR/dist" "$TARGET/dist"
cp -R "$DEPLOY_DIR/node_modules" "$TARGET/node_modules"
cp "$NODE_TMP/$NODE_PKG/bin/node" "$TARGET/node"
chmod +x "$TARGET/node"

cat > "$TARGET/makit" <<'SHIM'
#!/bin/sh
# Bundled makit CLI — self-contained; needs no repo checkout or global Node.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/node" "$DIR/dist/src/index.js" "$@"
SHIM
chmod +x "$TARGET/makit"

echo "==> Done: $TARGET/makit"
echo "    $("$TARGET/makit" --version 2>/dev/null || echo '(run: '"$TARGET"'/makit --help)')"
