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
"$FLUTTER_BIN" analyze --fatal-infos > /tmp/pino-analyze.log 2>&1
analyze_exit=$?
set -e
if (( analyze_exit != 0 )); then
  red "  ✗ analyze found issues — see /tmp/pino-analyze.log"
  fail=1
else
  green "  ✓ analyze clean"
fi

# ------------------------------------------------------------ 4. format check
step "4. dart format --set-exit-if-changed ."
if "$DART_BIN" format --set-exit-if-changed --output=none . >/dev/null 2>&1; then
  green "  ✓ formatted"
else
  yellow "  ! files need formatting — run: dart format ."
  warn=1
fi

# --------------------------------------------------------- 5. outdated check
# Dart/pub does not ship a built-in advisory scanner equivalent to
# `npm audit` or `pnpm audit`. We run `pub outdated` to flag stale deps
# (a key advisory indicator) and rely on pub.dev's per-package advisory
# tab for the rest. If you want machine-checked advisories, run a
# third-party tool like `dart pub global activate osv_scanner`.
step "5. dart pub outdated (advisory proxy)"
set +e
outdated_out=$("$DART_BIN" pub outdated --no-color 2>&1)
set -e
if echo "$outdated_out" | grep -qE "^[a-z_].*[0-9]\.[0-9]"; then
  yellow "  ! some packages have newer versions on pub.dev — review:"
  echo "$outdated_out" | tail -20
  warn=1
else
  green "  ✓ no outdated direct dependencies"
fi

# --------------------------------------------------------- 6. dependency_overrides
step "6. No unjustified dependency_overrides"
if grep -A1 "^dependency_overrides:" pubspec.yaml | grep -q "^  [a-zA-Z]"; then
  yellow "  ! pubspec.yaml has dependency_overrides — verify each has a comment justification"
  grep -B1 -A20 "^dependency_overrides:" pubspec.yaml || true
  warn=1
else
  green "  ✓ no dependency_overrides"
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
