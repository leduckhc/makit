import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';

/// How a worktree's pull-request state is drawn: the glyph, its tint, and the
/// AA-safe tint for an accompanying label.
class PrStateStyle {
  const PrStateStyle.font(this.icon, this.color, {Color? textColor})
    : asset = null,
      textColor = textColor ?? color;

  const PrStateStyle.asset(this.asset, this.color, {Color? textColor})
    : icon = null,
      textColor = textColor ?? color;

  /// Glyph for the state.
  final IconData? icon;

  /// SVG asset for a glyph not provided by Phosphor.
  final String? asset;

  /// Tint for the glyph (and any wash behind it) — icons only need 3:1.
  final Color color;

  /// Tint for a label next to the glyph. Same as [color] unless the vivid hue
  /// misses WCAG AA as small text (see [MakitSemanticText]).
  final Color textColor;

  Widget buildIcon({double? size, Color? color}) {
    final resolvedColor = color ?? this.color;
    final asset = this.asset;
    if (asset != null) {
      return SvgPicture.asset(
        asset,
        key: ValueKey(asset),
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(resolvedColor, BlendMode.srcIn),
      );
    }
    return Icon(icon, size: size, color: resolvedColor);
  }
}

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
///   CLOSED → prohibit sign, `colorScheme.error` (abandoned; deliberately not
///            the `xCircle` used by the composer's "CI failing" chip),
///   none / unrecognised → the plain branch icon, muted.
PrStateStyle prStateStyle(ColorScheme cs, PullRequest? pr) => switch (pr?.state
    .toUpperCase()) {
  'OPEN' => PrStateStyle.font(PhosphorIconsLight.gitPullRequest, cs.primary),
  'MERGED' => PrStateStyle.font(
    PhosphorIconsLight.gitMerge,
    kPrMerged,
    textColor: cs.prMergedText,
  ),
  'CLOSED' => PrStateStyle.asset(
    'assets/icons/git-pull-request-closed.svg',
    cs.error,
  ),
  _ => PrStateStyle.font(PhosphorIconsLight.gitBranch, cs.outline),
};
