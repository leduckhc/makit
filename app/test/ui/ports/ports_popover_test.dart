import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_popover.dart';

PortInfo _port({int port = 5173, String? openUrl = 'http://127.0.0.1:5173'}) =>
    PortInfo(
      key: '100:127.0.0.1:$port',
      port: port,
      address: '127.0.0.1',
      reach: PortReach.loopback,
      pid: 48211,
      command: 'node vite --port $port',
      startedAt: 1000,
      worktreePath: '/wt',
      sessionId: 's1',
      health: const PortHealth(
        kind: PortHealthKind.ok,
        status: 200,
        probedAt: 0,
      ),
      openUrl: openUrl,
    );

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

PortsPopover _popover({
  List<PortInfo>? ports,
  ValueChanged<bool>? onOpenChanged,
}) => PortsPopover(
  state: PortsGlyphState.serving,
  count: 1,
  branch: 'feat/open-ports',
  ports: ports ?? [_port()],
  nowMs: 0,
  onOpenChanged: onOpenChanged,
);

void main() {
  group('PortsPopover hover mechanics', () {
    testWidgets('opens only after the 350 ms dwell', (tester) async {
      await tester.pumpWidget(_host(_popover()));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.byType(PortsPopover)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(kPortsPopover), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(kPortsPopover), findsOneWidget);
    });

    testWidgets('travelling into the popover keeps it open', (tester) async {
      await tester.pumpWidget(_host(_popover()));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.byType(PortsPopover)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(kPortsPopover), findsOneWidget);

      // Move into the popover panel; the grace timer must be cancelled.
      await gesture.moveTo(tester.getCenter(find.byKey(kPortsPopover)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(kPortsPopover), findsOneWidget);
    });

    testWidgets('a click pins it open past a pointer exit', (tester) async {
      await tester.pumpWidget(_host(_popover()));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.byKey(kPortsPopover), findsOneWidget);

      // Move the pointer far away and let the grace window elapse.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(5, 5));
      addTearDown(gesture.removePointer);
      await gesture.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(kPortsPopover), findsOneWidget);
    });

    testWidgets('esc closes a pinned popover', (tester) async {
      await tester.pumpWidget(_host(_popover()));
      await tester.tap(find.byType(PortsPopover));
      await tester.pumpAndSettle();
      expect(find.byKey(kPortsPopover), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(kPortsPopover), findsNothing);
    });

    testWidgets('reports open-state changes for the row hover latch', (
      tester,
    ) async {
      final changes = <bool>[];
      await tester.pumpWidget(_host(_popover(onOpenChanged: changes.add)));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(changes.last, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(changes.last, false);
    });

    testWidgets('a pending open timer does not survive dispose', (
      tester,
    ) async {
      // Finding 5: the 350 ms open timer is armed on hover-enter; if dispose
      // did not cancel it, flutter_test's end-of-test pending-timer assertion
      // would fail here (and a fired callback could touch an unmounted state).
      await tester.pumpWidget(_host(_popover()));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(PortsPopover)));
      // Arm but do not fire the 350 ms open timer.
      await tester.pump(const Duration(milliseconds: 100));
      // Tear the widget down while the timer is still pending.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a pending close (grace) timer does not survive dispose', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_popover()));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      // Open on hover, then leave to arm the 150 ms grace close timer.
      await gesture.moveTo(tester.getCenter(find.byType(PortsPopover)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(kPortsPopover), findsOneWidget);
      await gesture.moveTo(const Offset(500, 500));
      await tester.pump(const Duration(milliseconds: 50));
      // Dispose while the close timer is still pending.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('PortsPopover actions', () {
    testWidgets('shows Open + Copy URL when openUrl is present', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_popover()));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Copy URL'), findsOneWidget);
    });

    testWidgets('hides both when openUrl is absent', (tester) async {
      await tester.pumpWidget(_host(_popover(ports: [_port(openUrl: null)])));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy URL'), findsNothing);
    });
  });
}
