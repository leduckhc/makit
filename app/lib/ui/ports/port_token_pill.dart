/// A terse port token (a health verdict or a reach) that carries its full
/// sentence to all three consumers the vocabulary promises can never drift
/// (SPEC-41 §"Tooltips"): the visible pill, a **long-press bubble** on touch,
/// and the **`Semantics.label`** a screen reader speaks.
///
/// The desktop popover uses [Tooltip] on hover directly; this is the touch /
/// detail form, where hover does not exist. The pill's own glance text is
/// excluded from semantics so the spoken label is the sentence, not the token.
library;

import 'package:flutter/material.dart';

/// Renders [label] as a small pill whose long-press bubble and semantics label
/// are both [sentence] — one string, three surfaces.
class PortTokenPill extends StatelessWidget {
  const PortTokenPill({
    super.key,
    required this.label,
    required this.sentence,
    this.color,
  });

  /// The terse glance text (`200`, `loopback`, …).
  final String label;

  /// The one vocabulary sentence that explains [label]; drives both the
  /// long-press bubble and the semantics label.
  final String sentence;

  /// Optional tint for the pill text (reach tokens are muted).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.labelSmall;
    final style = color == null ? base : base?.copyWith(color: color);
    return Semantics(
      label: sentence,
      child: Tooltip(
        message: sentence,
        triggerMode: TooltipTriggerMode.longPress,
        // The pill's glance text would otherwise be spoken instead of the
        // sentence; the sentence is the accessible label the spec requires.
        child: ExcludeSemantics(child: Text(label, style: style)),
      ),
    );
  }
}
