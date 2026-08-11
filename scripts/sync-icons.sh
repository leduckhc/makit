#!/usr/bin/env bash
#
# sync-icons.sh — vendor the glyphs from the phosphor_extras source repo.
#
# WHY VENDOR RATHER THAN DEPEND
#   phosphor_extras is the source of truth: geometry is generated there and its
#   invariants are checked there. It is not yet a git dependency because it has no
#   published remote, and a `path:` dependency pointing outside this repo would
#   break CI and the cloud VM, which both run `flutter pub get` on a fresh clone.
#   So the built SVGs are committed here and this script keeps them honest.
#   Once the source repo is pushed, this becomes a `git:` dependency in
#   app/pubspec.yaml and this script goes away.
#
# USAGE
#   scripts/sync-icons.sh            # copy glyphs in
#   scripts/sync-icons.sh --check    # fail if the vendored copies have drifted
#
#   PHOSPHOR_EXTRAS_DIR=/path/to/repo scripts/sync-icons.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${PHOSPHOR_EXTRAS_DIR:-$ROOT/../phosphor_extras}"
DEST="$ROOT/app/assets/icons"

# Only the glyphs this app actually renders. Pulling the whole set would ship
# weights nothing references, and a Flutter asset directory is bundled wholesale.
GLYPHS=(
	git-pull-request-closed-thin
	git-pull-request-closed-light
	git-pull-request-closed-regular
	git-pull-request-closed-bold
	git-pull-request-closed-fill
	forgejo-light
	gitea-light
)

die() {
	printf 'sync-icons: %s\n' "$1" >&2
	exit 1
}

# Arguments are validated before anything is copied: `[ "$1" = --check ]` alone left a
# misspelled `--chek` as check_only=false, so a command meant to VERIFY vendored assets
# silently overwrote them instead.
check_only=false
case "${1:-}" in
	--check) check_only=true ;;
	"") ;;
	*) die "unknown argument: $1 (usage: sync-icons.sh [--check])" ;;
esac
[ "$#" -le 1 ] || die "too many arguments (usage: sync-icons.sh [--check])"

[ -d "$SRC/icons" ] || die "no glyphs at $SRC/icons — set PHOSPHOR_EXTRAS_DIR to the phosphor_extras checkout"


drifted=0
for name in "${GLYPHS[@]}"; do
	from="$SRC/icons/$name.svg"
	to="$DEST/$name.svg"
	[ -f "$from" ] || die "missing source glyph: $from"
	if [ ! -f "$to" ] || ! cmp -s "$from" "$to"; then
		if $check_only; then
			printf '  drifted: %s\n' "$name.svg"
			drifted=$((drifted + 1))
		else
			cp "$from" "$to"
			printf '  updated: %s\n' "$name.svg"
		fi
	fi
done

if $check_only; then
	[ "$drifted" -eq 0 ] || die "$drifted vendored glyph(s) differ from $SRC/icons — run scripts/sync-icons.sh"
	printf 'sync-icons: %d glyphs match the source repo\n' "${#GLYPHS[@]}"
else
	printf 'sync-icons: %d glyphs in sync\n' "${#GLYPHS[@]}"
fi
