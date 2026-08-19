// SPEC-pane-zoom D5: the trackpad and wheel paths.
//
// The wheel half needs a gate. `Scrollable._receivedPointerSignal` registers
// with the `PointerSignalResolver`, the resolver keeps the FIRST registrant, and
// `GestureBinding` dispatches a signal deepest-first — so the transcript's
// `Scrollable` always beats the pane's outer `Listener`. Refusing the offset
// makes `Scrollable` return *before* it registers, which hands the event to the
// pane. These tests pin that mechanism, because a regression here is silent:
// the pane would zoom AND scroll at the same time.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/zoom_gestures.dart';

/// Metrics for a list that is scrolled halfway, so the physics' own rules would
/// accept an offset and only the zoom modifier can refuse it.
final _scrollable = FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: 1000,
  pixels: 500,
  viewportDimension: 400,
  axisDirection: AxisDirection.down,
  devicePixelRatio: 2,
);

Future<void> _hold(LogicalKeyboardKey key, Future<void> Function() body) async {
  await simulateKeyDownEvent(key);
  try {
    await body();
  } finally {
    await simulateKeyUpEvent(key);
  }
}

void main() {
  group('zoomModifierHeld', () {
    testWidgets('is false with no modifier down', (tester) async {
      expect(zoomModifierHeld, isFalse);
    });

    testWidgets('is true while the meta key is held (macOS ⌘+wheel)', (
      tester,
    ) async {
      await _hold(LogicalKeyboardKey.metaLeft, () async {
        expect(zoomModifierHeld, isTrue);
      });
      expect(zoomModifierHeld, isFalse);
    });

    testWidgets('is true while control is held (⌃+wheel elsewhere)', (
      tester,
    ) async {
      await _hold(LogicalKeyboardKey.controlLeft, () async {
        expect(zoomModifierHeld, isTrue);
      });
    });

    testWidgets('ignores shift and alt, which carry other meanings', (
      tester,
    ) async {
      await _hold(LogicalKeyboardKey.shiftLeft, () async {
        expect(zoomModifierHeld, isFalse);
      });
      await _hold(LogicalKeyboardKey.altLeft, () async {
        expect(zoomModifierHeld, isFalse);
      });
    });
  });

  group('ZoomAwareScrollPhysics', () {
    testWidgets('accepts a user offset normally', (tester) async {
      const physics = ZoomAwareScrollPhysics();
      expect(physics.shouldAcceptUserOffset(_scrollable), isTrue);
    });

    testWidgets('refuses the offset while a zoom modifier is held', (
      tester,
    ) async {
      const physics = ZoomAwareScrollPhysics();
      await _hold(LogicalKeyboardKey.metaLeft, () async {
        expect(
          physics.shouldAcceptUserOffset(_scrollable),
          isFalse,
          reason: 'Scrollable must bail before it registers with the resolver',
        );
      });
      expect(physics.shouldAcceptUserOffset(_scrollable), isTrue);
    });

    testWidgets('keeps its parent physics through applyTo', (tester) async {
      final composed = const ZoomAwareScrollPhysics().applyTo(
        const ClampingScrollPhysics(),
      );
      expect(composed, isA<ZoomAwareScrollPhysics>());
      // The parent still decides everything else; only the zoom gate is ours.
      expect(composed.parent, isA<ClampingScrollPhysics>());
      await _hold(LogicalKeyboardKey.metaLeft, () async {
        expect(composed.shouldAcceptUserOffset(_scrollable), isFalse);
      });
    });
  });
}
