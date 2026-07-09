import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Brand colors for the makit mark. Kept local so the mark renders the same
/// regardless of the app theme (which is still seeded blue pending a design
/// pass — see app/theme.dart).
const Color makitAccent = Color(0xFF4ADE80);
const Color makitFrame = Color(0xFF171717); // design-system dark bg

/// Static makit mark — the `o//` winner (B4: medium head + two thick forward
/// slashes, arms far apart, round caps).
///
/// Renders in a 160x100 logical space, fit (contain) into the given size.
class MakitMark extends StatelessWidget {
  const MakitMark({super.key, this.size = 80, this.color = makitAccent});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * (100 / 160),
      child: CustomPaint(painter: _MakitMarkPainter(color: color)),
    );
  }
}

/// Animated makit mark that plays the Clap loop: arms pivot from the shoulder
/// (the end nearest the head), swinging inward while the shoulder slides
/// right (away from the head), then back. Matches CSS `A · Clap`:
///   0–35%  swing in  (rotate -32°, translateX +12)
///   35–50% hold
///   50–65% swing out
///   65–100% rest
/// Duration 1.6s, ease-in-out per segment.
class MakitClapMark extends StatefulWidget {
  const MakitClapMark({
    super.key,
    this.size = 160,
    this.color = makitAccent,
    this.running = true,
  });

  final double size;
  final Color color;
  final bool running;

  @override
  State<MakitClapMark> createState() => _MakitClapMarkState();
}

class _MakitClapMarkState extends State<MakitClapMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.running) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant MakitClapMark old) {
    super.didUpdateWidget(old);
    if (widget.running && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.running && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size * (100 / 160),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) => CustomPaint(
          painter: _MakitMarkPainter(
            clapProgress: widget.running ? _ctrl.value : -1,
            color: widget.color,
          ),
        ),
      ),
    );
  }
}

/// Paints the mark in a 160x100 logical space. When [clapProgress] is in
/// 0..1, the arms are transformed by the clap cycle; -1 = static.
class _MakitMarkPainter extends CustomPainter {
  final double clapProgress;
  final Color color;

  _MakitMarkPainter({this.clapProgress = -1, required this.color});

  // Clap peaks (match the CSS keyframe).
  static const double _maxRotDeg = -32.0;
  static const double _maxTx = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    const logicalW = 160.0, logicalH = 100.0;
    final s = math.min(size.width / logicalW, size.height / logicalH);
    final dx = (size.width - logicalW * s) / 2;
    final dy = (size.height - logicalH * s) / 2;
    canvas.translate(dx, dy);
    canvas.scale(s);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Head.
    canvas.drawCircle(const Offset(38, 50), 26, paint);

    // Arms.
    paint
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 14;

    final (rot, tx) = _clapTransform(clapProgress);

    // Arm L: line (72,82)→(106,18), pivot at shoulder (72,82).
    canvas.save();
    canvas.translate(72 + tx, 82);
    canvas.rotate(rot);
    canvas.translate(-72, -82);
    canvas.drawLine(const Offset(72, 82), const Offset(106, 18), paint);
    canvas.restore();

    // Arm R: line (100,82)→(134,18), pivot at shoulder (100,82).
    canvas.save();
    canvas.translate(100 + tx, 82);
    canvas.rotate(rot);
    canvas.translate(-100, -82);
    canvas.drawLine(const Offset(100, 82), const Offset(134, 18), paint);
    canvas.restore();
  }

  /// Maps cycle t (0..1) → (rotation radians, shoulder translateX in logical
  /// units). Segments match the CSS keyframe; ease-in-out per segment.
  static (double, double) _clapTransform(double t) {
    if (t < 0) return (0.0, 0.0);
    const maxRot = _maxRotDeg * math.pi / 180.0; // ~-0.5585 rad
    const maxTx = _maxTx;
    if (t < 0.35) {
      final u = Curves.easeInOut.transform(t / 0.35);
      return (maxRot * u, maxTx * u);
    } else if (t < 0.5) {
      return (maxRot, maxTx);
    } else if (t < 0.65) {
      final u = Curves.easeInOut.transform((t - 0.5) / 0.15);
      return (maxRot * (1 - u), maxTx * (1 - u));
    }
    return (0.0, 0.0);
  }

  @override
  bool shouldRepaint(covariant _MakitMarkPainter old) =>
      old.clapProgress != clapProgress || old.color != color;
}

/// Full-screen splash that plays the Clap animation on the dark brand frame,
/// holds for [duration], fades out, then calls [onCompleted] exactly once.
///
/// The OS-level native splash (see flutter_native_splash.yaml) shows the same
/// dark frame + mark while the engine boots, so the hand-off is seamless.
class MakitSplash extends StatefulWidget {
  const MakitSplash({
    super.key,
    this.duration = const Duration(milliseconds: 2400),
    this.fadeDuration = const Duration(milliseconds: 300),
    this.onCompleted,
  });

  /// How long the animation holds before it starts fading out.
  final Duration duration;

  /// Fade-out length once [duration] elapses.
  final Duration fadeDuration;

  /// Called once, after the fade-out completes.
  final VoidCallback? onCompleted;

  @override
  State<MakitSplash> createState() => _MakitSplashState();
}

class _MakitSplashState extends State<MakitSplash> {
  Timer? _holdTimer;
  bool _fadingOut = false;

  @override
  void initState() {
    super.initState();
    _holdTimer = Timer(widget.duration, () {
      if (mounted) setState(() => _fadingOut = true);
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: makitFrame,
      body: Center(
        child: AnimatedOpacity(
          opacity: _fadingOut ? 0 : 1,
          duration: widget.fadeDuration,
          curve: Curves.easeOut,
          onEnd: () {
            if (_fadingOut) widget.onCompleted?.call();
          },
          child: MakitClapMark(size: 160, running: !_fadingOut),
        ),
      ),
    );
  }
}
