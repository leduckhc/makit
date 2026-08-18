/// The ports row glyph (SPEC-open-ports §1): Phosphor `Plug`, tinted by state, with an
/// attention dot and a semantics label that names the state in words — colour
/// is never the only signal (worktree_row.dart's rule). Renders nothing when
/// the state is [PortsGlyphState.none].
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import 'ports_vocabulary.dart';

/// Stable key for the attention/exposed dot badge, so a test can assert it
/// without depending on colour.
const Key kPortsAttentionDot = ValueKey('ports-attention-dot');

/// Diameter of the badge dot that rides the glyph's top-right (spec §5 table).
const double _kBadgeSize = 6;

/// The presentational glyph. Pure: state in, pixels out. Interaction (hover
/// popover / tap sheet) is wired by the mounts, so this widget stays testable
/// on its own and shared byte-for-byte between phone and desktop.
class PortsGlyph extends StatelessWidget {
  const PortsGlyph({
    super.key,
    required this.state,
    required this.count,
    this.size = 16,
    this.showBadge = true,
  });

  final PortsGlyphState state;

  /// Ports owned by this worktree — the number the semantics label speaks.
  final int count;

  /// Painted glyph size. 14 on the desktop sub-row (fits the 16 pt line), 16
  /// on the phone's trailing control column.
  final double size;

  /// Whether the attention/exposed dot (and the unknown `?`) ride the glyph.
  /// The session-tile glyph sets this false so it stays quieter than the row
  /// glyph, which already carries attention (SPEC-ports-global-view D14).
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    if (state == PortsGlyphState.none) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final color = _tint(cs, state);
    final label = portsGlyphSemanticLabel(state, count: count);

    // The plug, plus a badge for the states that carry one and a "?" for the
    // honest-unknown state. The box is exactly [size]; the badge overflows with
    // Clip.none so it rides up into surrounding padding rather than growing the
    // glyph — which is what lets the desktop sub-row keep its fixed 16 pt.
    return Semantics(
      label: label,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(PhosphorIconsLight.plug, size: size, color: color),
            if (showBadge &&
                (state == PortsGlyphState.attention ||
                    state == PortsGlyphState.exposed))
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  key: kPortsAttentionDot,
                  width: _kBadgeSize,
                  height: _kBadgeSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: state == PortsGlyphState.attention
                        ? kDiffDel
                        : kStatusWarning,
                  ),
                ),
              ),
            if (showBadge && state == PortsGlyphState.unknown)
              Positioned(
                top: -2,
                right: -2,
                child: Text(
                  '?',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: cs.outline,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// State tint, from theme tokens only. `serving` is the app's primary accent;
  /// `exposed` warns amber; `attention` uses the error hue; `unknown` is a
  /// muted outline (an honest "we could not read").
  static Color _tint(ColorScheme cs, PortsGlyphState state) => switch (state) {
    PortsGlyphState.serving => cs.primary,
    PortsGlyphState.exposed => kStatusWarning,
    PortsGlyphState.attention => kDiffDel,
    PortsGlyphState.unknown => cs.outline,
    PortsGlyphState.none => cs.outline,
  };
}
