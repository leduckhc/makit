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
///
/// This is the **dot/fill** hue, which only has to clear 3:1. For a *label* use
/// [prToneTextColor] (on a surface or a tint) or [onPrToneFill] (on a solid
/// fill): `kCheckFail` and `kCheckPending` are vivid tokens that miss AA as small
/// text, the same split `prStateStyle` makes between `color` and `textColor`.
Color prToneColor(ColorScheme cs, PrTone tone) => switch (tone) {
  PrTone.blocking => kCheckFail,
  PrTone.attention => kCheckPending,
  PrTone.quiet => cs.outline,
  PrTone.landed => cs.prMergedText,
};

/// The AA-safe label colour for a tone, for text on the surface or on the tone's
/// own tint.
///
/// Same hue family as [prToneColor], resolved for contrast: on the light theme
/// `kCheckFail` prints at 2.3:1 over its own 14% tint and `kCheckPending` is
/// worse. Pinned by `theme_contrast_test.dart`.
///
/// `attention` is resolved **per theme** rather than pinned to the app's caution
/// orange. Only the light theme needs the swap (`kCheckPending` is 2.1:1 there);
/// on dark it is 7.1:1 on the surface and beats the orange on every tint, so the
/// label keeps the same amber as the dot beside it. Two ambers in one sentence
/// read as two different verdicts — the exact failure mode [prToneColor]'s
/// docstring warns about (mockup §3).
Color prToneTextColor(ColorScheme cs, PrTone tone) => switch (tone) {
  PrTone.blocking => cs.diffDelText,
  PrTone.attention =>
    cs.brightness == Brightness.dark ? kCheckPending : cs.statusCautionText,
  PrTone.quiet => cs.onSurfaceVariant,
  PrTone.landed => cs.prMergedText,
};

/// Background + ink for a **direct** CTA, which is a solid fill.
///
/// Destructive ops take the scheme's error *container* rather than the CI red:
/// `kCheckFail` is the hue a failing build owns, and painting "discard this
/// worktree" in it made the one irreversible button out-shout the fact it sits
/// beside. The mockup's own destructive picture uses the muted error tint (§3
/// `closed`).
({Color bg, Color fg}) prDirectCtaFill(
  ColorScheme cs,
  PrTone tone, {
  required bool destructive,
}) => destructive
    ? (bg: cs.errorContainer, fg: cs.onErrorContainer)
    : (bg: prToneColor(cs, tone), fg: onPrToneFill(cs, tone));

/// The label colour for text on a **solid** [prToneColor] fill (the direct CTA).
///
/// Measured rather than assumed: `cs.onError` on `kCheckFail` is 3.35:1, so the
/// scheme's own pairing is not good enough here. `cs.surface`/`cs.onSurface` are
/// near-white and near-black in one order on light and the other on dark, so
/// taking whichever wins on the actual fill works for both themes.
Color onPrToneFill(ColorScheme cs, PrTone tone) =>
    inkOn(cs, prToneColor(cs, tone));

/// The readable ink for text printed on an arbitrary [fill].
///
/// `cs.onSurface`/`cs.surface` are near-white and near-black in one order on the
/// light theme and the other on the dark one, so taking whichever wins on the
/// actual fill works for both. Takes a colour rather than a [PrTone] because not
/// every filled surface comes from a tone — the confirm dialog's commit button is
/// tinted per op.
Color inkOn(ColorScheme cs, Color fill) =>
    _contrast(cs.onSurface, fill) >= _contrast(cs.surface, fill)
    ? cs.onSurface
    : cs.surface;

/// The status dot's colour — the **pull request's** verdict, not the loud fact's
/// tone (mockup §2; falls back to [prToneColor] for [PrDot.tone]).
///
/// Reads the `kCheck*` tokens rather than re-typing the literals, for the same
/// reason [prToneColor] does: these dots sit beside CI colours elsewhere in the
/// app and a near-miss hue reads as a third, meaningless verdict.
Color prDotColor(ColorScheme cs, PrDot dot, PrTone tone) => switch (dot) {
  // Grey regardless of tone: the ring means "nothing to report", so tinting it
  // would report something.
  PrDot.none => cs.outline,
  PrDot.pass => kCheckPass,
  PrDot.fail => kCheckFail,
  PrDot.pending => kCheckPending,
  PrDot.landed => cs.prMergedText,
  PrDot.muted => cs.outline,
  PrDot.tone => prToneColor(cs, tone),
};

/// `#142 · 2 checks failing` as a chip draws it: the identity in the surface ink,
/// a faint separator, then the loud fact in its own tone.
///
/// Shared by the home-row chip and the session subtitle chip because they draw the
/// *same* fragment — and having written it twice, they had drifted: both painted
/// the whole string in the tone and bolded all of it, so a merged worktree's number
/// came out purple and a failing one's red. The identity is not part of the
/// verdict; it is the same `#142` whatever CI says, which is what the desktop bar
/// has always done.
///
/// The bar itself keeps its own richer version (a dot inside the sentence, the
/// stale suffix, a bigger type ramp) — this is the chip-sized subset.
class PrFactLabel extends StatelessWidget {
  const PrFactLabel({super.key, required this.status, this.maxWidth});

  final PrStatus status;

  /// Cap the label so a long fact cannot push the row's own controls off screen;
  /// it elides instead. Null leaves it unconstrained.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = Text.rich(
      TextSpan(
        children: [
          if (status.hasPr) ...[
            TextSpan(
              text: status.identity,
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: ' · ',
              style: TextStyle(color: cs.outline.withValues(alpha: 0.55)),
            ),
          ],
          TextSpan(text: status.loud.label),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.labelXs?.copyWith(color: prToneTextColor(cs, status.tone)),
    );
    final width = maxWidth;
    if (width == null) return label;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: label,
    );
  }
}

/// WCAG relative-contrast ratio.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

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
    this.dot = PrDot.tone,
    this.progress,
  });

  /// The fallback hue, used when [dot] is [PrDot.tone]. Also what the per-fact
  /// dots in the detail list are drawn from — each row reports its own fact, so
  /// there the tone *is* the verdict.
  final PrTone tone;

  /// What the dot reports (mockup §2). See [PrDot].
  final PrDot dot;

  /// Fraction of checks that have reported, or null for a plain dot.
  final double? progress;

  static const double _size = 9;
  static const double _ringSize = 11;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = prDotColor(cs, dot, tone);
    final p = progress;
    // Both forms occupy the ring's box: the disc is the smaller of the two, and
    // letting it size the widget made the sentence twitch 2px sideways the moment
    // a build finished.
    return SizedBox(
      width: _ringSize,
      height: _ringSize,
      child: p != null && dot == PrDot.pending
          ? CircularProgressIndicator(
              value: p.clamp(0.0, 1.0),
              strokeWidth: 2.5,
              color: color,
              // The unreported remainder is *unknown*, not a faded version of the
              // arc's own colour: the mockup tracks it in the outline variant.
              backgroundColor: cs.outlineVariant,
            )
          : Center(
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dot == PrDot.none ? null : color,
                  border: dot == PrDot.none
                      ? Border.all(color: color, width: 1.5)
                      : null,
                ),
              ),
            ),
    );
  }
}
