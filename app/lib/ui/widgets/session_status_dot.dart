import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'pulse.dart';

/// A tiny session-status indicator dot. Active states (running / awaiting)
/// pulse; the rest render as a solid dot. Shared by the sidebar session tiles
/// and the pane header so a session reads the same everywhere.
///
/// Palette-tuned hues (theme roles where they exist, softened ambers for the
/// awaiting states) so it sits with the neutral M3 surfaces. Carries a tooltip
/// + semantics label so the dot is never a colour-only signal.
class SessionStatusDot extends StatelessWidget {
  /// Creates a status dot reflecting [status].
  const SessionStatusDot({super.key, required this.status});

  /// The session status the dot reflects.
  final SessionStatus status;

  bool get _pulses =>
      status == SessionStatus.running ||
      status == SessionStatus.awaitingInput ||
      status == SessionStatus.awaitingApproval;

  /// Human-readable status, used for the tooltip + screen-reader semantics so
  /// the dot is not a color-only signal.
  String get _label => switch (status) {
    SessionStatus.running => 'running',
    SessionStatus.awaitingInput => 'awaiting input',
    SessionStatus.awaitingApproval => 'awaiting approval',
    SessionStatus.error => 'error',
    SessionStatus.exited => 'exited',
    SessionStatus.idle => 'idle',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Palette-tuned status hues: theme roles where they exist (green primary,
    // M3 error red, neutral outline), and softened ambers for the awaiting
    // states so they sit with the neutral panel instead of shouting.
    final color = switch (status) {
      SessionStatus.running => cs.primary,
      SessionStatus.awaitingInput => kStatusWarning,
      SessionStatus.awaitingApproval => kStatusCaution,
      SessionStatus.error => cs.error,
      SessionStatus.exited => cs.outline,
      SessionStatus.idle => cs.outline,
    };
    // Fade the dot's own colour rather than wrapping it in an Opacity/
    // FadeTransition: those allocate an offscreen layer on every pulse frame,
    // and this dot is drawn once per session tile.
    Widget dotAt(double alpha) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color.withValues(alpha: alpha),
        shape: BoxShape.circle,
      ),
    );
    // Active states pulse on the shared low-rate clock (see [PulseBuilder]);
    // solid states render flat, leaving nothing ticking.
    final Widget dot = _pulses
        ? PulseBuilder(builder: (context, t) => dotAt(0.3 + 0.7 * t))
        : dotAt(1);
    return Tooltip(
      message: _label,
      child: Semantics(label: 'status: $_label', child: dot),
    );
  }
}
