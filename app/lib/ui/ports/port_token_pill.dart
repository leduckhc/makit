/// A terse port token (a health verdict or a reach) that carries its full
/// sentence to all three consumers the vocabulary promises can never drift
/// (SPEC-41 §"Tooltips"): the visible pill, a **long-press bubble** on touch,
/// and the **`Semantics.label`** a screen reader speaks.
///
/// It is also the one place a [PortTone] becomes colour, so a `404` is the same
/// amber in the desktop popover, both mobile sheets and the global screen
/// (mockup `open-ports.html` 111–118). Every surface renders tokens through
/// this widget; none of them may hand-pick a hue.
///
/// On desktop `Tooltip` opens on hover regardless of [TooltipTriggerMode], so
/// the same widget serves the pointer and the thumb.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'ports_vocabulary.dart';

/// Diameter of the leading status dot. Small enough to read as punctuation next
/// to an 11 pt label rather than as a second glyph.
const double _kDotSize = 5;

/// Alpha of the tinted fill. The mockup's 14% wash: enough to bound the token,
/// far too little to swamp the row it sits in.
const double _kWashAlpha = 0.14;

/// Renders [label] as a small tinted pill whose long-press bubble and semantics
/// label are both [sentence] — one string, three surfaces.
class PortTokenPill extends StatelessWidget {
  const PortTokenPill({
    super.key,
    required this.label,
    required this.sentence,
    this.tone = PortTone.idle,
    this.showDot = false,
  });

  /// The terse glance text (`200`, `loopback`, …).
  final String label;

  /// The one vocabulary sentence that explains [label]; drives both the
  /// long-press bubble and the semantics label.
  final String sentence;

  /// The severity this token carries, from [portHealthTone] / [portReachTone].
  final PortTone tone;

  /// Whether this token is a live verdict, and so earns a leading status dot.
  /// The health token is; the reach token is not (it is a property of the bind
  /// address, not a state that changes under you).
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = portTonePillForeground(cs, tone);
    // An idle token has no verdict to pulse: "not probed" is the ABSENCE of a
    // reading, and a dot there would claim a live check happened (mockup 115,
    // the one `.health` span with no `__PULSE__`).
    final drawDot = showDot && tone != PortTone.idle;
    return Semantics(
      label: sentence,
      child: Tooltip(
        message: sentence,
        triggerMode: TooltipTriggerMode.longPress,
        // The pill's glance text would otherwise be spoken instead of the
        // sentence; the sentence is the accessible label the spec requires.
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: portTonePillFill(cs, tone),
              borderRadius: BorderRadius.circular(kRadius6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace6,
                vertical: 1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (drawDot) ...[
                    Container(
                      width: _kDotSize,
                      height: _kDotSize,
                      decoration: BoxDecoration(
                        color: fg,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: kSpace4),
                  ],
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The *text* colour for a tone, from the sanctioned palette only (theme.dart →
/// [MakitSemanticText]); those variants already resolve per brightness, so a
/// pill is legible in both themes without a second table.
///
/// Clears WCAG AA against [portTonePillFill] in BOTH themes — which is why
/// `_diffAddTextLight` is darker than the bare surface alone would need. Pinned
/// by the port-pill case in `theme_contrast_test.dart`.
///
/// Public (like `prToneTextColor`) so that test can pin the real ratio against
/// [portTonePillFill] instead of trusting the pairing by eye.
Color portTonePillForeground(ColorScheme cs, PortTone tone) => switch (tone) {
  PortTone.ok => cs.diffAddText,
  PortTone.warn => cs.statusWarningText,
  PortTone.err => cs.error,
  PortTone.idle => cs.onSurfaceVariant,
};

/// The pill fill: a translucent wash of its own foreground for the three verdict
/// tones, and the opaque neutral container step for [PortTone.idle] — which must
/// NOT be a wash of the muted grey, or a list of loopback tokens would tint the
/// whole panel.
///
/// Verdict fills are deliberately translucent so a pill composites over whatever
/// surface its host draws (popover panel, sheet, or screen) instead of assuming
/// one. A contrast check must therefore `Color.alphaBlend` this over the surface
/// under test — which is a no-op for the already-opaque idle fill, so one
/// function serves the widget and the guard.
Color portTonePillFill(ColorScheme cs, PortTone tone) => tone == PortTone.idle
    ? cs.surfaceContainerHigh
    : portTonePillForeground(cs, tone).withValues(alpha: _kWashAlpha);
