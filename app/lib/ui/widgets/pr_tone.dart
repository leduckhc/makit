/// How a [PrTone] is drawn. One file so the desktop bar, the mobile worktree row
/// and the PR detail sheet cannot tint the same fact differently — which is
/// exactly what went wrong before (see `prPillColors`'s docstring: an open
/// failing PR read red in a session and brand-green on the home list).
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'pr_signals.dart';
import 'pr_state_style.dart';

/// The colour for a tone.
///
/// `attention` borrows GitHub's own pending amber rather than the app's
/// `kStatusCaution` orange, because these facts sit beside CI colours and an
/// orange that is *nearly* the amber of a running check reads as a third,
/// meaningless hue.
Color prToneColor(ColorScheme cs, PrTone tone) => switch (tone) {
  PrTone.blocking => kCheckFail,
  PrTone.attention => kCheckPending,
  PrTone.quiet => cs.outline,
  PrTone.landed => cs.prMergedText,
};

/// The status dot — the bar's only graphic, so it carries two things at once:
/// hue for the verdict, and an arc for how many checks have reported.
///
/// The arc is deliberately determinate. A check rollup is a *count* (4 of 12
/// reported), so an indeterminate spinner would overstate what is unknown: the
/// count is known, only the outcome is not.
class PrToneDot extends StatelessWidget {
  const PrToneDot({
    super.key,
    required this.tone,
    this.progress,
    this.hollow = false,
  });

  final PrTone tone;

  /// Fraction of checks that have reported, or null for a plain dot.
  final double? progress;

  /// Draw a ring instead of a disc — used when there is no PR yet, so "nothing
  /// to report" is visibly different from "reported, and fine".
  final bool hollow;

  static const double _size = 9;
  static const double _ringSize = 11;

  @override
  Widget build(BuildContext context) {
    final color = prToneColor(Theme.of(context).colorScheme, tone);
    final p = progress;
    if (p != null) {
      return SizedBox(
        width: _ringSize,
        height: _ringSize,
        child: CircularProgressIndicator(
          value: p.clamp(0.0, 1.0),
          strokeWidth: 2.5,
          color: color,
          backgroundColor: color.withValues(alpha: 0.22),
        ),
      );
    }
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? null : color,
        border: hollow ? Border.all(color: color, width: 1.5) : null,
      ),
    );
  }
}
