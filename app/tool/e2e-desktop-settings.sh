#!/usr/bin/env bash
set -euo pipefail

# Per-repo Settings e2e on the real macOS app (SPEC-per-repo-settings T6.2).
#
# Sibling of e2e-desktop.sh, and deliberately much smaller: that harness boots a
# real daemon control socket because it is testing the control plane. This one
# needs no daemon at all. What it proves is the composition inside the app --
#
#   reposProvider -> sectionsFor() -> nav pane -> RepositorySettingsPage -> rows
#
# -- and the daemon-side behaviour it would otherwise duplicate is already covered
# by the server tests (repo_settings*, router, git). Routing it through the socket
# would add infrastructure for no extra coverage, so the repo snapshot is stubbed
# at `reposProvider`, which is exactly the seam `SettingsWindow` reads.
#
# macOS-only: this is the desktop shell, so the harness targets the `macos`
# device rather than a simulator.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"

FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found — set MAKIT_FLUTTER_BIN or add flutter to PATH" >&2
  exit 1
fi
FLUTTER_BIN_DIR="$(cd "$(dirname "$FLUTTER_BIN")" && pwd)"

cd "$APP_DIR"
PATH="$FLUTTER_BIN_DIR:$PATH" "$FLUTTER_BIN" test \
  -d macos \
  integration_test/desktop/settings_repo_test.dart \
  "$@"
