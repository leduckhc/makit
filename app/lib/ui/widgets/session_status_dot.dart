import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'pulse.dart';

/// A tiny session-status indicator dot. Only the `running` state pulses; every
/// other state renders as a solid dot. Shared by the sidebar session tiles and
/// the pane header so a session reads the same everywhere.
///
/// Motion means work. A parked session (awaiting input or approval) waits on the
/// human and does no work, so its dot stays solid. Its colour still names the
/// state, and the tooltip plus semantics label keep the dot from being a
/// colour-only signal.
///
/// Palette-tuned hues (theme roles where they exist, softened ambers for the
/// awaiting states) so it sits with the neutral M3 surfaces.
class SessionStatusDot extends StatelessWidget {
  /// Creates a status dot reflecting [status].
  const SessionStatusDot({super.key, required this.status, this.clock});

  /// The session status the dot reflects.
  final SessionStatus status;

  /// The clock the pulse listens to. Tests inject their own; production reads
  /// the shared [PulseClock.instance].
  final PulseClock? clock;

  bool get _pulses => status == SessionStatus.running;

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
        ? PulseBuilder(
            clock: clock,
            builder: (context, t) => dotAt(0.3 + 0.7 * t),
          )
        : dotAt(1);
    return Tooltip(
      message: _label,
      child: Semantics(label: 'status: $_label', child: dot),
    );
  }
}
