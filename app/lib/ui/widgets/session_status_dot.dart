import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/models.dart';

/// A tiny session-status indicator dot. Active states (running / awaiting)
/// pulse; the rest render as a solid dot. Shared by the sidebar session tiles
/// and the pane header so a session reads the same everywhere.
///
/// Palette-tuned hues (theme roles where they exist, softened ambers for the
/// awaiting states) so it sits with the neutral M3 surfaces. Carries a tooltip
/// + semantics label so the dot is never a colour-only signal.
class SessionStatusDot extends StatefulWidget {
  /// Creates a status dot reflecting [status].
  const SessionStatusDot({super.key, required this.status});

  /// The session status the dot reflects.
  final SessionStatus status;

  @override
  State<SessionStatusDot> createState() => _SessionStatusDotState();
}

class _SessionStatusDotState extends State<SessionStatusDot>
    with TickerProviderStateMixin {
  AnimationController? _controller;

  bool get _pulses =>
      widget.status == SessionStatus.running ||
      widget.status == SessionStatus.awaitingInput ||
      widget.status == SessionStatus.awaitingApproval;

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(SessionStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sessions transition status in place (running → exited, idle → running…)
    // and this State object is reused, so the controller must track the
    // current status — not the one we mounted with.
    if (oldWidget.status != widget.status) _syncController();
  }

  /// Only active states animate — solid states must not leave a repeating
  /// controller running (it would also make pumpAndSettle hang in tests).
  void _syncController() {
    if (_pulses && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat(reverse: true);
    } else if (!_pulses && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Human-readable status, used for the tooltip + screen-reader semantics so
  /// the dot is not a color-only signal.
  String get _label => switch (widget.status) {
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
    final color = switch (widget.status) {
      SessionStatus.running => cs.primary,
      SessionStatus.awaitingInput => kStatusWarning,
      SessionStatus.awaitingApproval => kStatusCaution,
      SessionStatus.error => cs.error,
      SessionStatus.exited => cs.outline,
      SessionStatus.idle => cs.outline,
    };
    Widget dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final controller = _controller;
    if (controller != null) {
      dot = FadeTransition(
        opacity: Tween<double>(begin: 0.3, end: 1).animate(controller),
        child: dot,
      );
    }
    return Tooltip(
      message: _label,
      child: Semantics(label: 'status: $_label', child: dot),
    );
  }
}
