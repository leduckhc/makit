import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_popover.dart';

PortInfo _port({
  int port = 5173,
  String? openUrl = 'http://127.0.0.1:5173',
  String? command,
}) => PortInfo(
  key: '100:127.0.0.1:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: 48211,
  command: command ?? 'node vite --port $port',
  startedAt: 1000,
  worktreePath: '/wt',
  sessionId: 's1',
  health: const PortHealth(kind: PortHealthKind.ok, status: 200, probedAt: 0),
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

    testWidgets(
      'clicking to pin an ALREADY-OPEN popover installs the outside-tap barrier',
      (tester) async {
        // Comment 3 / finding 7. In the sidebar this cannot be pinned down: any
        // ancestor rebuild re-runs `overlayChildBuilder`, so the barrier appears
        // whether or not `_onTap` asked for a rebuild. In ISOLATION nothing else
        // rebuilds this widget, so the barrier can only exist if flipping
        // `_pinned` was done under `setState`.
        //
        // Mutation that proves it bites: `_pinned = true;` without `setState` in
        // `_onTap` — hover-open leaves the overlay built while `_pinned` was
        // false, `_show()` early-returns, and this expect finds no barrier.
        await tester.pumpWidget(_host(_popover()));
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);

        // Hover-open first: this is the path where `_show()` early-returns.
        await gesture.moveTo(tester.getCenter(find.byType(PortsPopover)));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(kPortsPopover), findsOneWidget);
        expect(find.byKey(kPortsPopoverBarrier), findsNothing);

        await tester.tap(find.byType(PortsPopover));
        await tester.pump();
        expect(find.byKey(kPortsPopoverBarrier), findsOneWidget);
      },
    );

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

  group('PortsPopover truncated text', () {
    // The panel is a fixed 320 pt, so both the command token and the
    // pid · command line ellipse for any real absolute-path argv[0]. Line 1
    // therefore shows argv[0]'s BASENAME, and both carry the full command as a
    // tooltip — otherwise the row is unreadable with no way to read it.
    const long =
        '/opt/homebrew/Cellar/node/26.5.1/bin/node dist/serve.js --port 5173';

    testWidgets('line 1 shows the command basename, not the whole path', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_popover(ports: [_port(command: long)])));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.text('node'), findsOneWidget);
      expect(find.textContaining('/opt/homebrew/Cellar'), findsOneWidget);
    });

    testWidgets('the command token and the pid line both carry the full '
        'command as a tooltip', (tester) async {
      await tester.pumpWidget(_host(_popover(ports: [_port(command: long)])));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.byTooltip('pid 48211 · $long'), findsNWidgets(2));
    });
  });

  group('PortsPopover actions', () {
    testWidgets('a pinned popover states how to reach and dismiss it', (
      tester,
    ) async {
      // Mockup §2a's footer: the pin and the Esc/Tab paths are otherwise
      // undiscoverable — a hover popover holding buttons has to say so.
      await tester.pumpWidget(_host(_popover()));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.byKey(kPortsPopoverHint), findsOneWidget);
    });

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
