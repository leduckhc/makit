import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/pane_zoom.dart';

void main() {
  group('the ladder', () {
    test('starts at 1.0 and steps to the next stop up', () {
      expect(PaneZoom.stepIn(1), 1.1);
      expect(PaneZoom.stepIn(1.1), 1.25);
      expect(PaneZoom.stepIn(2.2), 2.4);
    });

    test('steps to the next stop down', () {
      expect(PaneZoom.stepOut(1), 0.9);
      expect(PaneZoom.stepOut(0.9), 0.8);
      expect(PaneZoom.stepOut(0.67), 0.6);
    });

    test('holds still at each end instead of overshooting', () {
      expect(PaneZoom.stepIn(PaneZoom.max), PaneZoom.max);
      expect(PaneZoom.stepOut(PaneZoom.min), PaneZoom.min);
    });

    test(
      'exposes 1.0 as an exact stop, so a reset is reachable by stepping',
      () {
        expect(PaneZoom.stops, contains(1.0));
        expect(PaneZoom.stepIn(0.9), 1.0);
        expect(PaneZoom.stepOut(1.1), 1.0);
      },
    );

    test('steps from a continuous value left by a pinch', () {
      // 1.03 came from a pinch. Stepping in must not return to 1.1's
      // neighbour-of-1.0; it must pass 1.03 and land on the next real stop.
      expect(PaneZoom.stepIn(1.03), 1.1);
      expect(PaneZoom.stepOut(1.03), 1.0);
    });

    test('clamps a value from outside the ladder before stepping', () {
      expect(PaneZoom.stepIn(9), PaneZoom.max);
      expect(PaneZoom.stepOut(0.01), PaneZoom.min);
    });

    test('walks every adjacent pair of stops, up and back down', () {
      // The spec promises every step, so check every step rather than a sample.
      for (var i = 0; i < PaneZoom.stops.length - 1; i++) {
        final from = PaneZoom.stops[i];
        final to = PaneZoom.stops[i + 1];
        expect(
          PaneZoom.stepIn(from),
          to,
          reason: 'stepIn($from) should reach $to',
        );
        expect(
          PaneZoom.stepOut(to),
          from,
          reason: 'stepOut($to) should reach $from',
        );
      }
    });

    test('reaches both ends by stepping, and no further', () {
      var zoom = PaneZoom.none;
      for (var i = 0; i < PaneZoom.stops.length; i++) {
        zoom = PaneZoom.stepIn(zoom);
      }
      expect(zoom, PaneZoom.max);
      for (var i = 0; i < PaneZoom.stops.length; i++) {
        zoom = PaneZoom.stepOut(zoom);
      }
      expect(zoom, PaneZoom.min);
    });
  });

  group('nudge, for a pinch or a wheel', () {
    test('multiplies the current factor', () {
      expect(PaneZoom.nudge(1, 1.5), 1.5);
      expect(PaneZoom.nudge(2, 0.5), 1);
    });

    test('clamps to the ladder ends and does not snap to a stop', () {
      expect(PaneZoom.nudge(1, 100), PaneZoom.max);
      expect(PaneZoom.nudge(1, 0.001), PaneZoom.min);
      expect(PaneZoom.nudge(1, 1.03), closeTo(1.03, 1e-9));
    });
  });

  group('the effective scale', () {
    test('multiplies the global text scale by the pane zoom', () {
      expect(PaneZoom.effective(globalTextScale: 1, zoom: 1.4), 1.4);
      expect(PaneZoom.effective(globalTextScale: 1.2, zoom: 1), 1.2);
    });

    test('clamps the product, so a high global cannot exceed the maximum', () {
      // 1.3 x 2.4 is 3.12. D3 clamps the product, not just the pane factor.
      expect(PaneZoom.effective(globalTextScale: 1.3, zoom: 2.4), PaneZoom.max);
      expect(PaneZoom.effective(globalTextScale: 0.9, zoom: 0.6), PaneZoom.min);
    });
  });

  group('the percentage label', () {
    test('reads as a whole percent', () {
      expect(PaneZoom.label(1), '100%');
      expect(PaneZoom.label(1.25), '125%');
      expect(PaneZoom.label(0.67), '67%');
    });
  });
}
