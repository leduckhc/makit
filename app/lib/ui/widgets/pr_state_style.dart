import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'icon_glyph.dart';

/// How a worktree's pull-request state is drawn: the glyph, its tint, and the
/// AA-safe tint for an accompanying label.
class PrStateStyle {
  const PrStateStyle(this.glyph, this.color, {Color? textColor})
    : textColor = textColor ?? color;

  /// Glyph for the state — render with `glyph.build(size:, color:)`.
  final IconGlyph glyph;

  /// Tint for the glyph (and any wash behind it) — icons only need 3:1.
  final Color color;

  /// Tint for a label next to the glyph. Same as [color] unless the vivid hue
  /// misses WCAG AA as small text (see [MakitSemanticText]).
  final Color textColor;
}

/// The closed-PR mark: Phosphor ships no closed-pull-request glyph, so this is
/// an in-house SVG drawn on Phosphor's 256 grid. It ships in the full weight
/// range — `git-pull-request-closed-{thin,light,regular,bold,fill}.svg`, all on
/// the same grid with the weight carried by stroke width (8/12/16/24 per
/// Phosphor) — and this is the Light one, because every glyph the app renders is
/// `PhosphorIconsLight`. Point at a heavier sibling only alongside a heavier
/// Phosphor set, or the marker reads bolder than its neighbours.
const kClosedPrAsset = 'assets/icons/git-pull-request-closed-light.svg';

/// The icon + colour for a worktree whose pull request is [pr] (null when the
/// worktree has none).
///
/// Single source of truth for every PR-state glyph — the desktop sidebar row,
/// the composer's status pill, the window title strip and the mobile worktree
/// pill all read from here so a merged/closed PR can't keep rendering as a live
/// one in one of them. States follow `gh pr view --json state`, matched
/// case-insensitively:
///   OPEN   → pull-request symbol, brand accent (live work),
///   MERGED → merge symbol, [kPrMerged] purple (landed; worktree is prunable),
///   CLOSED → [kClosedPrAsset], `colorScheme.error` (abandoned),
///   none / unrecognised → the plain branch icon, muted.
PrStateStyle prStateStyle(ColorScheme cs, PullRequest? pr) =>
    switch (pr?.state.toUpperCase()) {
      'OPEN' => PrStateStyle(
        const IconGlyph.font(PhosphorIconsLight.gitPullRequest),
        cs.primary,
      ),
      'MERGED' => PrStateStyle(
        const IconGlyph.font(PhosphorIconsLight.gitMerge),
        kPrMerged,
        textColor: cs.prMergedText,
      ),
      'CLOSED' => PrStateStyle(const IconGlyph.svg(kClosedPrAsset), cs.error),
      _ => PrStateStyle(
        const IconGlyph.font(PhosphorIconsLight.gitBranch),
        cs.outline,
      ),
    };

/// Colour for a PR's aggregate CI verdict ([PullRequest.checkRollup]).
///
/// Shared with [prCheckBucketColor] so the pill's verdict tint and the
/// per-check list can't disagree. GitHub's own check hues (they coincide with
/// the diff palette but mean something different, so they stay literal here
/// rather than borrowing `kDiffAdd`/`kDiffDel`).
Color prRollupColor(ColorScheme cs, String rollup) => switch (rollup) {
  'pass' => const Color(0xFF3FB950),
  'fail' => const Color(0xFFF85149),
  'pending' => const Color(0xFFD29922),
  _ => cs.outline,
};

/// Colour for a single check bucket ([PrCheck.bucket]). A cancelled check reads
/// as a failure — it did not pass and the user must act.
Color prCheckBucketColor(ColorScheme cs, String bucket) => switch (bucket) {
  'pass' => const Color(0xFF3FB950),
  'fail' || 'cancel' => const Color(0xFFF85149),
  'pending' => const Color(0xFFD29922),
  _ => cs.outline, // skipping / unknown
};

/// Human status word for a check bucket.
String prCheckBucketLabel(String bucket) => switch (bucket) {
  'pass' => 'passed',
  'fail' => 'failed',
  'cancel' => 'cancelled',
  'pending' => 'pending',
  'skipping' => 'skipped',
  _ => bucket,
};

/// Leading status glyph for a check bucket.
IconData prCheckBucketIcon(String bucket) => switch (bucket) {
  'pass' => PhosphorIconsLight.checkCircle,
  'fail' || 'cancel' => PhosphorIconsLight.xCircle,
  'pending' => PhosphorIconsLight.clock,
  'skipping' => PhosphorIconsLight.minusCircle,
  _ => PhosphorIconsLight.circleDashed,
};

/// Sort rank for a check bucket: failures float to the top so the most obvious
/// issues are easiest to spot, then in-flight, then skipped, then passing.
int _bucketRank(String bucket) => switch (bucket) {
  'fail' || 'cancel' => 0,
  'pending' => 1,
  'skipping' => 2,
  _ => 3,
};

/// Checks sorted by [_bucketRank], stable within a bucket (preserves the
/// server's original order for ties).
List<PrCheck> sortPrChecks(List<PrCheck> checks) {
  final indexed = [for (var i = 0; i < checks.length; i++) (i, checks[i])];
  indexed.sort((a, b) {
    final byRank = _bucketRank(a.$2.bucket).compareTo(_bucketRank(b.$2.bucket));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
