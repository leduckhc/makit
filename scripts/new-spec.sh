#!/usr/bin/env bash
#
# Create a spec file whose name cannot clash with another worktree's.
#
# The id is the clock, not a counter. Nothing has to be claimed, so two branches
# drafted in the same hour stay distinct with no coordination. See
# docs/specs/README.md#spec-naming for why the old sequential numbers failed.
#
# Usage:
#   scripts/new-spec.sh "cli as client"        # a spec
#   scripts/new-spec.sh --plan cli-as-client   # its plan, on the parent's stamp
#   scripts/new-spec.sh --review cli-as-client # its review, likewise
#
# A sibling shares its parent's timestamp so the two sort together. The parent
# must already exist; that is what makes the sibling's stamp knowable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPECS="$ROOT/docs/specs"

KIND="spec"
case "${1:-}" in
  --plan)   KIND="PLAN";   shift ;;
  --review) KIND="REVIEW"; shift ;;
  -h|--help|"")
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

[[ $# -ge 1 ]] || { echo "new-spec: name a slug or a title" >&2; exit 2; }

# Slugify: lowercase, spaces and underscores to hyphens, drop the rest.
slug="$(printf '%s' "$*" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[ _]+/-/g; s/[^a-z0-9-]//g; s/-+/-/g; s/^-//; s/-$//')"

[[ -n "$slug" ]] || { echo "new-spec: that title leaves an empty slug" >&2; exit 2; }

if [[ "$KIND" == "spec" ]]; then
  # A slug is the readable id, so it must stay unique on its own.
  if existing="$(ls "$SPECS" | grep -E "^[0-9]{8}-[0-9]{6}-SPEC-${slug}\.md$" || true)"; then
    if [[ -n "$existing" ]]; then
      echo "new-spec: slug already taken by $existing" >&2
      exit 1
    fi
  fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  target="$SPECS/$stamp-SPEC-$slug.md"
  title="$slug"
  cat > "$target" <<EOF
# SPEC-$slug — $title

**Status:** drafted · **Priority:** P? · **Surface:**
**Depends on:**

---

## Goal

## Decisions

| | decision | why |
|---|---|---|
| **D1** | | |

## Non-goals

## Verification
EOF
else
  parent="$(ls "$SPECS" | grep -E "^[0-9]{8}-[0-9]{6}-SPEC-${slug}\.md$" || true)"
  if [[ -z "$parent" ]]; then
    echo "new-spec: no spec named SPEC-$slug — create the spec first" >&2
    exit 1
  fi
  stamp="${parent%%-SPEC-*}"
  target="$SPECS/$stamp-SPEC-$slug-$KIND.md"
  [[ ! -e "$target" ]] || { echo "new-spec: $target exists" >&2; exit 1; }
  cat > "$target" <<EOF
# SPEC-$slug — $(printf '%s' "$KIND" | tr '[:upper:]' '[:lower:]')

**Spec:** [./$parent](./$parent)

---
EOF
fi

echo "${target#"$ROOT"/}"
