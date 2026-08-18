#!/usr/bin/env bash
# Verify every vendored skill against skills-lock.json.
#
#   bash .agents/skills/vendor/verify.sh          # check
#   bash .agents/skills/vendor/verify.sh --write  # re-record committedHash
#
# `computedHash` records what the fetch tool hashed upstream. It does NOT match
# the committed bytes, because the tool injects a `metadata:` block after
# hashing. `committedHash` is the sha256 of the committed file, so a local edit
# to a vendored skill fails this check.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
lock="$root/skills-lock.json"
write=0
[ "${1:-}" = "--write" ] && write=1

command -v jq >/dev/null || { echo "verify.sh needs jq"; exit 2; }

dir="$(jq -r '.vendorDir' "$lock")"
[ "$dir" != "null" ] || { echo "skills-lock.json has no vendorDir"; exit 2; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

fail=0
names="$(jq -r '.skills | keys[]' "$lock")"

# Every lock entry must have a file with the recorded hash.
while IFS= read -r name; do
  file="$root/$dir/$name/SKILL.md"
  if [ ! -f "$file" ]; then
    echo "MISSING  $dir/$name/SKILL.md is in the lock but not on disk"
    fail=1
    continue
  fi
  want="$(jq -r --arg n "$name" '.skills[$n].committedHash // ""' "$lock")"
  got="$(sha "$file")"
  if [ "$write" = 1 ]; then
    tmp="$(mktemp)"
    jq --arg n "$name" --arg h "$got" '.skills[$n].committedHash = $h' "$lock" > "$tmp"
    mv "$tmp" "$lock"
    continue
  fi
  if [ -z "$want" ]; then
    echo "UNRECORDED  $name has no committedHash; run verify.sh --write"
    fail=1
  elif [ "$want" != "$got" ]; then
    echo "MODIFIED  $dir/$name/SKILL.md"
    echo "          expected $want"
    echo "          actual   $got"
    fail=1
  fi
done <<< "$names"

# Every file on disk must have a lock entry.
while IFS= read -r file; do
  name="$(basename "$(dirname "$file")")"
  grep -qx "$name" <<< "$names" || { echo "UNTRACKED  $dir/$name is not in skills-lock.json"; fail=1; }
done < <(find "$root/$dir" -name SKILL.md)

if [ "$write" = 1 ]; then
  echo "recorded committedHash for $(wc -l <<< "$names" | tr -d ' ') vendored skills"
  exit 0
fi
[ "$fail" = 0 ] && echo "ok: $(wc -l <<< "$names" | tr -d ' ') vendored skills match skills-lock.json"
exit "$fail"
