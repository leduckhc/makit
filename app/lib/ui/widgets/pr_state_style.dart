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
