import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'pulse.dart';

/// One revolution of the spinner.
const Duration kSpinnerPeriod = Duration(milliseconds: 1000);

/// How much of the ring the arc covers, in turns.
const double _kArcTurns = 0.75;

/// Revolutions completed at [elapsed], wrapping at 1.
double spinnerTurns(Duration elapsed) =>
    pulseValue(elapsed, kSpinnerPeriod, reverse: false);

/// An indeterminate spinner driven by the shared [PulseClock] instead of a
/// per-widget vsync ticker.
///
/// Material's [CircularProgressIndicator] runs its own repeating
/// `AnimationController`, so one of them on screen keeps the app producing
/// frames at the display refresh rate — measured at ~120 fps on ProMotion, which
/// cancels out the PulseClock saving for as long as the spinner is visible. That
/// is fine for a spinner in a modal you are waiting on, and expensive for one
/// that sits in the transcript for the length of a turn.
///
/// Use this where a spinner coexists with ongoing work; leave Material's where
/// it appears briefly and smoothness is the only thing that matters.
class PulseSpinner extends StatelessWidget {
  /// Creates a spinner of [size] logical pixels.
  const PulseSpinner({
    super.key,
    this.size = 14,
    this.strokeWidth = 2,
    this.color,
    this.semanticsLabel,
  });

  /// Width and height of the ring.
  final double size;

  /// Stroke width of the arc.
  final double strokeWidth;

  /// Arc colour; defaults to the progress-indicator colour of the theme.
  final Color? color;

  /// Names what is in flight, for assistive tech. Mirrors
  /// [CircularProgressIndicator.semanticsLabel]: optional, because a caller that
  /// already renders the state as text (the connection chip) would otherwise say
  /// it twice. Pass one wherever the spinner is the only signal.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arcColor =
        color ??
        theme.progressIndicatorTheme.color ??
        theme.colorScheme.primary;
    // Material's progress indicators always emit a Semantics node carrying
    // SemanticsRole.loadingSpinner; a bare CustomPaint would silently drop that.
    return Semantics(
      role: SemanticsRole.loadingSpinner,
      label: semanticsLabel,
      child: SizedBox(
        width: size,
        height: size,
        child: PulseBuilder(
          period: kSpinnerPeriod,
          reverse: false,
          builder: (context, t) => CustomPaint(
            painter: SpinnerPainter(
              turns: t,
              color: arcColor,
              strokeWidth: strokeWidth,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the spinner's arc, rotated to [turns] of a full revolution.
class SpinnerPainter extends CustomPainter {
  /// Creates a painter for an arc rotated by [turns].
  const SpinnerPainter({
    required this.turns,
    required this.color,
    required this.strokeWidth,
  });

  /// Rotation of the arc, in revolutions.
  final double turns;

  /// Arc colour.
  final Color color;

  /// Stroke width of the arc.
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawArc(
      rect.deflate(strokeWidth / 2),
      turns * 2 * math.pi,
      _kArcTurns * 2 * math.pi,
      false,
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(SpinnerPainter old) =>
      old.turns != turns ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
