#!/usr/bin/env bash
# Flutter app security audit. See SECURITY.md.
#
# Exit non-zero on any policy violation. Run before merge + on a weekly CI cron.

set -euo pipefail

cd "$(dirname "$0")/.."

# Resolve flutter binary — Milan keeps it off PATH at /Users/le/Work/Vibe/flutter.
FLUTTER_BIN="${FLUTTER_BIN:-/Users/le/Work/Vibe/flutter/bin/flutter}"
DART_BIN="${DART_BIN:-/Users/le/Work/Vibe/flutter/bin/dart}"

red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

fail=0
warn=0

step() { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }

# ---------------------------------------------------------------- 1. lockfile
step "1. Lockfile is committed and clean"
if [[ ! -f pubspec.lock ]]; then
  red "  ✗ pubspec.lock missing"; fail=1
else
  if ! "$FLUTTER_BIN" pub get --enforce-lockfile >/dev/null 2>&1; then
    red "  ✗ pubspec.lock would be modified by pub get (drift)"
    fail=1
  else
    green "  ✓ pubspec.lock is up to date (enforce-lockfile passed)"
  fi
fi

# --------------------------------------------------------- 2. hosted-only deps
step "2. No git: or path: dependencies"
bad=$("$DART_BIN" pub deps --style=compact 2>/dev/null \
  | grep -E "from git|from path" || true)
if [[ -n "$bad" ]]; then
  red "  ✗ non-hosted dependencies found:"
  echo "$bad" >&2
  fail=1
else
  green "  ✓ all dependencies resolve from pub.dev"
fi

# --------------------------------------------------------- 3. analysis (lint)
# --------------------------------------------------------- 3. analysis (lint)
# Strict: any analyze issue (warning/error/info) fails the gate.
# Codebase is currently zero-issues — keep it that way.
step "3. flutter analyze (strict — fail on any issue)"
set +e
"$FLUTTER_BIN" analyze --fatal-infos > /tmp/makit-analyze.log 2>&1
analyze_exit=$?
set -e
if (( analyze_exit != 0 )); then
  red "  ✗ analyze found issues — see /tmp/makit-analyze.log"
  fail=1
else
  green "  ✓ analyze clean"
fi

# ----------------------------------------------------------- 4. unit/widget tests
step "4. flutter test"
set +e
"$FLUTTER_BIN" test > /tmp/makit-test.log 2>&1
test_exit=$?
set -e
if (( test_exit != 0 )); then
  red "  ✗ tests failed — see /tmp/makit-test.log"
  tail -20 /tmp/makit-test.log >&2
  fail=1
else
  passed=$(grep -oE "All tests passed|\+[0-9]+: All tests passed!" /tmp/makit-test.log | head -1)
  count=$(grep -oE "\+[0-9]+:" /tmp/makit-test.log | tail -1 | tr -d '+:' || echo 0)
  green "  ✓ ${count:-?} tests passed"
fi

# --------------------------------------------------------- 5. E2E smoke tests
step "5. flutter integration_test (E2E smoke suite)"
set +e
if tool/e2e.sh --mode=stub >/tmp/makit-e2e.log 2>&1; then
  green "  ✓ E2E smoke tests passed (stub mode)"
else
  red "  ✗ E2E smoke tests failed — see /tmp/makit-e2e.log"
  tail -30 /tmp/makit-e2e.log >&2
  fail=1
fi
set -e

# ------------------------------------------------------------ 6. format check
step "6. dart format --set-exit-if-changed (our sources)"
# Scoped to our own sources, not `.`: cargokit (super_native_extensions, SPEC-user-attachments)
# writes a generated `build_tool_runner.dart` into `build/`, which is unformatted
# and would make this gate permanently dirty on any machine that has built once.
if "$DART_BIN" format --set-exit-if-changed --output=none \
  lib test tool integration_test >/dev/null 2>&1; then
  green "  ✓ formatted"
else
  yellow "  ! files need formatting — run: dart format lib test tool integration_test"
  warn=1
fi
# ----------------------------------------------------- 8. advisory scan (OSV)
# Dart/pub has no built-in advisory scanner (no `npm audit` equivalent), and
# `dart pub outdated --mode=security` was removed. We scan the lockfile against
# the OSV database with `osv-scanner`. If it isn't installed we fall back to a
# `pub outdated` staleness proxy and warn.
#   Install: brew install osv-scanner   (or download a pinned release binary)
step "8. osv-scanner (known-advisory scan of pubspec.lock)"
if command -v osv-scanner >/dev/null 2>&1; then
  set +e
  osv-scanner scan source --lockfile=pubspec.lock >/tmp/makit-osv.log 2>&1
  osv_exit=$?
  set -e
  if (( osv_exit != 0 )); then
    red "  ✗ osv-scanner reported advisories — see /tmp/makit-osv.log"
    tail -30 /tmp/makit-osv.log >&2
    fail=1
  else
    green "  ✓ no known advisories in the lockfile"
  fi
else
  yellow "  ! osv-scanner not installed — falling back to 'pub outdated' staleness proxy"
  yellow "    install for a real advisory scan: brew install osv-scanner"
  set +e
  outdated_out=$("$DART_BIN" pub outdated --no-color 2>&1)
  set -e
  if echo "$outdated_out" | grep -qE "^[a-z_].*[0-9]\.[0-9]"; then
    yellow "  ! some packages have newer versions on pub.dev — review:"
    echo "$outdated_out" | tail -20
  fi
  warn=1
fi

# --------------------------------------------------------- 6. dependency_overrides
step "7. No unjustified dependency_overrides"
if grep -A1 "^dependency_overrides:" pubspec.yaml | grep -q "^  [a-zA-Z]"; then
  yellow "  ! pubspec.yaml has dependency_overrides — verify each has a comment justification"
  grep -B1 -A20 "^dependency_overrides:" pubspec.yaml || true
  warn=1
else
  green "  ✓ no dependency_overrides"
fi

# ------------------------------------------------------- 9. release cooldown
# pub has no `minimumReleaseAge` (pnpm does — server/SECURITY.md §3), so we
# check that this change introduces no lockfile version younger than 3 days.
step "9. pub cooldown (no lockfile version published <3d ago)"
set +e
"$DART_BIN" run tool/pub_cooldown.dart >/tmp/makit-cooldown.log 2>&1
cooldown_exit=$?
set -e
# `dart run` prefixes stdout with "Running build hooks..." — strip it.
cooldown_msg=$(tail -1 /tmp/makit-cooldown.log | sed 's/.*Running build hooks\.\.\.//')
if (( cooldown_exit == 0 )); then
  green "  ✓ ${cooldown_msg}"
elif (( cooldown_exit == 2 )); then
  red "  ✗ cooldown could not be verified — ${cooldown_msg}"
  red "    (offline? this gate fails closed — see SECURITY.md §8)"
  fail=1
else
  red "  ✗ cooldown violation — see SECURITY.md §8"
  tail -10 /tmp/makit-cooldown.log >&2
  fail=1
fi

# ------------------------------------------------- 10. rust toolchain present
# super_clipboard (SPEC-user-attachments §4.3) is implemented in Rust. Quoting the package:
# "If you don't have Rust installed, the plugin will automatically download
# precompiled binaries for target platform." Those binaries are fetched at build
# time and are NOT covered by pubspec.lock's sha256 hashes (SECURITY.md §3/§4),
# so the only way to keep the supply chain hash-verified is to compile from
# source — which the plugin's build integration does automatically IF rustup is
# detected. Hence: rustup present is a hard requirement while this dep exists.
step "10. Rust toolchain present (super_clipboard builds from source)"
if ! grep -q "^  super_clipboard:" pubspec.lock; then
  green "  ✓ super_clipboard not locked — check not applicable"
elif command -v rustup >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  green "  ✓ rustup + cargo on PATH ($(rustup --version 2>/dev/null | head -1))"
else
  red "  ✗ super_clipboard is locked but rustup/cargo is not on PATH"
  red "    Without it the plugin downloads precompiled binaries that"
  red "    pubspec.lock does not hash-verify. Install: https://rustup.rs"
  red "    (see SECURITY.md and docs/specs/…SPEC-user-attachments…§4.3)"
  fail=1
fi

# ----------------------------------------------------------------- summary
printf "\n"
if (( fail )); then
  red "FAIL: one or more security checks failed."
  exit 1
elif (( warn )); then
  yellow "PASS with warnings."
  exit 0
else
  green "PASS: all security checks clean."
fi
