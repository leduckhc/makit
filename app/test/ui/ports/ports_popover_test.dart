import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_glyph.dart';
import 'package:makit/ui/ports/ports_popover.dart';
import 'package:makit/ui/ports/ports_vocabulary.dart';

PortInfo _port({
  int port = 5173,
  String? openUrl = 'http://127.0.0.1:5173',
  String? command,
  int? startedAt = 1000,
}) => PortInfo(
  key: '100:127.0.0.1:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: 48211,
  command: command ?? 'node vite --port $port',
  startedAt: startedAt,
  worktreePath: '/wt',
  sessionId: 's1',
  health: const PortHealth(kind: PortHealthKind.ok, status: 200, probedAt: 0),
  openUrl: openUrl,
);

/// Records the `ports.kill` bodies a row sends, so a test can prove the confirm
/// gates them (SPEC-43 D8).
final _killBodies = <Map<String, dynamic>>[];

// The real theme, so the app-wide `tooltipTheme` dwell applies here exactly as
// it does in the product (a bare MaterialApp would silently use Flutter's
// zero-dwell default and the tooltip tests below would prove nothing).
//
// A ProviderScope wraps it because a port row owns the kill (it reads the
// killer), with the socket replaced by a recorder.
Widget _host(Widget child) => ProviderScope(
  overrides: [
    portsKillerProvider.overrideWithValue(
      PortsKiller((body) async {
        _killBodies.add(body);
        return {'outcome': 'released'};
      }),
    ),
  ],
  child: MaterialApp(
    theme: makitDarkTheme,
    home: Scaffold(body: Center(child: child)),
  ),
);

PortsPopover _popover({
  List<PortInfo>? ports,
  ValueChanged<bool>? onOpenChanged,
  int nowMs = 0,
}) => PortsPopover(
  state: PortsGlyphState.serving,
  count: 1,
  branch: 'feat/open-ports',
  ports: ports ?? [_port()],
  nowMs: nowMs,
  onOpenChanged: onOpenChanged,
);

void main() {
  setUp(_killBodies.clear);

  group('tooltip dwell (SPEC-41 §Tooltips: TOOLTIP_DWELL_MS = 500)', () {
    test('the dwell is 500 ms and cannot race the popover open dwell', () {
      expect(kTooltipDwell, const Duration(milliseconds: 500));
      // The load-bearing ordering: a tooltip that fired before the popover
      // opened would cover the glyph the pointer is aiming at.
      expect(
        kTooltipDwell.inMilliseconds,
        greaterThan(kPortsHoverOpenMs),
        reason: 'the tooltip must not appear before the popover',
      );
    });

    test('both themes carry the dwell, not Flutter\'s zero default', () {
      for (final theme in [makitLightTheme, makitDarkTheme]) {
        expect(
          theme.tooltipTheme.waitDuration,
          kTooltipDwell,
          reason: '${theme.brightness.name} tooltips would fire instantly',
        );
      }
    });

    testWidgets('a token tooltip waits out the dwell before appearing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_popover()));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();

      // Hover the reach token inside the open popover.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('loopback')));

      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('reachable only from this machine'),
        findsNothing,
        reason: 'the tooltip fired before the 500 ms dwell',
      );

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('reachable only from this machine'),
        findsOneWidget,
      );
    });
  });

  group('PortsPopover glyph hover feedback (mockup §5)', () {
    Color? circleColor(WidgetTester tester) {
      final box = tester.widget<Container>(find.byKey(kPortsGlyphHoverCircle));
      return (box.decoration as BoxDecoration).color;
    }

    testWidgets('the glyph paints a circle under the pointer, and clears it', (
      tester,
    ) async {
      // Without this the feature's primary control gives no sign it is a
      // target, while the `…` right beside it does (IconButton supplies one).
      await tester.pumpWidget(_host(_popover()));
      expect(circleColor(tester)!.a, 0, reason: 'lit before any hover');

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(PortsGlyph)));
      await tester.pump();
      expect(circleColor(tester)!.a, greaterThan(0));

      await gesture.moveTo(const Offset(600, 600));
      await tester.pump(const Duration(milliseconds: 200));
      expect(circleColor(tester)!.a, 0, reason: 'still lit after leaving');
    });

    testWidgets('stays lit while a pinned popover owns the glyph', (
      tester,
    ) async {
      // A pinned popover with an unlit glyph loses the only clue about which
      // control opened it.
      await tester.pumpWidget(_host(_popover()));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(circleColor(tester)!.a, greaterThan(0));
    });
  });

  group('PortsPopover placement', () {
    // The glyph lives on a sidebar row's sub-row. Opening the panel BELOW it
    // covers the sidebar — including the very row whose ports you are reading
    // — so it opens BESIDE the glyph instead, spilling into the pane on the
    // right where there is nothing to hide.
    Future<void> pumpAt(
      WidgetTester tester, {
      required Offset at,
      required Size window,
      List<PortInfo>? ports,
    }) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Through `_host`, not a bare MaterialApp: opening the popover builds
      // `_PortRow`, which is a ConsumerWidget and therefore needs an ancestor
      // ProviderScope. It happens to survive without one today only because
      // nothing reads a provider during build — one `ref.watch` away from
      // breaking every placement test for an unrelated reason.
      await tester.pumpWidget(
        _host(
          Stack(
            children: [
              Positioned(
                left: at.dx,
                top: at.dy,
                child: _popover(ports: ports),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
    }

    testWidgets('opens beside the glyph, clear of it, never below', (
      tester,
    ) async {
      await pumpAt(
        tester,
        at: const Offset(240, 300),
        window: const Size(1400, 900),
      );
      final glyph = tester.getRect(find.byType(PortsGlyph));
      final panel = tester.getRect(find.byKey(kPortsPopover));
      expect(
        panel.left,
        greaterThanOrEqualTo(glyph.right),
        reason: 'the panel overlaps the glyph and its row',
      );
      // Aligned to the row it belongs to, rather than floating at some
      // unrelated height.
      expect(panel.top, lessThanOrEqualTo(glyph.top));
    });

    testWidgets('falls back to the glyph\'s left when the right is too tight', (
      tester,
    ) async {
      // A sidebar docked on the RIGHT, or a narrow window: there is no room
      // beside the glyph, so the panel goes to the other side rather than
      // being clamped into a position that covers it.
      await pumpAt(
        tester,
        at: const Offset(600, 300),
        window: const Size(700, 900),
      );
      final glyph = tester.getRect(find.byType(PortsGlyph));
      final panel = tester.getRect(find.byKey(kPortsPopover));
      expect(panel.right, lessThanOrEqualTo(glyph.left));
    });

    testWidgets('stays inside the window when neither side fits', (
      tester,
    ) async {
      await pumpAt(
        tester,
        at: const Offset(180, 300),
        window: const Size(400, 900),
      );
      final panel = tester.getRect(find.byKey(kPortsPopover));
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(400));
    });

    testWidgets('flips up when the glyph sits near the bottom', (tester) async {
      // Pinning only the top edge would run a tall panel off the bottom, which
      // is where a sidebar's last worktree row lives.
      await pumpAt(
        tester,
        at: const Offset(240, 560),
        window: const Size(1400, 600),
        ports: [_port(port: 5173), _port(port: 5174), _port(port: 5175)],
      );
      final panel = tester.getRect(find.byKey(kPortsPopover));
      expect(panel.bottom, lessThanOrEqualTo(600));
      expect(panel.top, greaterThanOrEqualTo(0));
    });

    testWidgets('at the height cap, only the rows scroll', (tester) async {
      // The cap exists so a worktree with a dozen listeners scrolls instead of
      // running off the window edge. Scrolling the WHOLE column would take the
      // branch name and the hint with it — and the hint is the only place the
      // pin and Esc are documented, so losing it strands a hover-opened panel.
      await pumpAt(
        tester,
        at: const Offset(240, 20),
        window: const Size(1400, 360),
        ports: [for (var i = 0; i < 24; i++) _port(port: 5173 + i)],
      );

      final scroller = find.descendant(
        of: find.byKey(kPortsPopover),
        matching: find.byType(Scrollable),
      );
      final header = find.text('feat/open-ports');
      final hint = find.byKey(kPortsPopoverHint);

      final headerBefore = tester.getRect(header);
      final hintBefore = tester.getRect(hint);
      final offsetBefore = tester
          .state<ScrollableState>(scroller)
          .position
          .pixels;

      await tester.drag(scroller, const Offset(0, -140));
      await tester.pumpAndSettle();

      // The rows really did move, so the assertions below are not vacuous.
      expect(
        tester.state<ScrollableState>(scroller).position.pixels,
        greaterThan(offsetBefore),
        reason: 'the row list did not scroll, so this proves nothing',
      );
      expect(tester.getRect(header), headerBefore);
      expect(tester.getRect(hint), hintBefore);
    });
  });

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
    // Both lines ellipse for any real absolute-path argv[0], so neither may
    // spend its width on directories: line 1 shows argv[0]'s BASENAME and line
    // 2 shows `pid · age · args`. The untruncated argv lives in the tooltip
    // both of them share — otherwise the row is unreadable with no way to read
    // it (spec §3).
    const long =
        '/opt/homebrew/Cellar/node/26.5.1/bin/node dist/serve.js --port 5173';

    testWidgets('line 1 shows the command basename, not the whole path', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_popover(ports: [_port(command: long)])));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(find.text('node'), findsOneWidget);
    });

    testWidgets('no visible line spends its width on argv[0] directories', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_popover(ports: [_port(command: long)])));
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      // The regression this replaces: line 2 rendered the full argv, so its
      // ellipsis fell inside the path and the process age — the fact the line
      // exists for — was pushed off the end and never rendered at all.
      expect(find.textContaining('/opt/homebrew/Cellar'), findsNothing);
    });

    testWidgets('line 2 shows the process age ahead of the args', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _popover(
            ports: [_port(command: long, startedAt: 0)],
            nowMs: 41 * 60 * 1000,
          ),
        ),
      );
      await tester.tap(find.byType(PortsPopover));
      await tester.pump();
      expect(
        find.text('pid 48211 · up 41m · node dist/serve.js --port 5173'),
        findsOneWidget,
      );
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

  // ── SPEC-43 P3a: the desktop Kill button (D8, mockup §2a) ────────────────
  group('Kill action', () {
    Future<void> pin(WidgetTester tester, {List<PortInfo>? ports}) async {
      await tester.pumpWidget(_host(_popover(ports: ports)));
      await tester.tap(find.byType(PortsPopover));
      await tester.pumpAndSettle();
    }

    testWidgets('Kill is the LAST action, after Open and Copy URL', (
      tester,
    ) async {
      await pin(tester);
      // Tree order, not x-position: the action group wraps at 360 pt, so "last"
      // means last in reading order — never before a non-destructive button.
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(
        labels.indexOf(portKillLabel),
        greaterThan(labels.indexOf('Open')),
      );
      expect(
        labels.indexOf(portKillLabel),
        greaterThan(labels.indexOf('Copy URL')),
      );
      // And it is never ABOVE them either.
      final kill = tester.getTopLeft(find.text(portKillLabel));
      expect(
        kill.dy,
        greaterThanOrEqualTo(tester.getTopLeft(find.text('Open')).dy),
      );
    });

    testWidgets('it is offered even when nothing answered HTTP', (
      tester,
    ) async {
      // `:5175 vite · refused, up 6h` has no openUrl — and is precisely the
      // wedged server the feature exists to reclaim.
      await pin(tester, ports: [_port(openUrl: null)]);
      expect(find.text('Open'), findsNothing);
      expect(find.text(portKillLabel), findsOneWidget);
    });

    testWidgets('a pinned popover still confirms — the pin is not consent', (
      tester,
    ) async {
      await pin(tester);
      await tester.tap(find.text(portKillLabel));
      await tester.pumpAndSettle();
      // A dialog naming the victim, and NOTHING sent yet.
      expect(find.text('Kill :5173?'), findsOneWidget);
      // The row behind the dialog also prints the pid, so `findsWidgets`: what
      // matters is that the DIALOG names it.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('pid 48211'),
        ),
        findsOneWidget,
      );
      expect(_killBodies, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_killBodies, isEmpty, reason: 'dismissing sends nothing');
    });

    testWidgets('confirming sends the displayed tuple', (tester) async {
      await pin(tester);
      await tester.tap(find.text(portKillLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Kill'));
      await tester.pumpAndSettle();
      expect(_killBodies, [
        {
          'kind': 'ports.kill',
          'address': '127.0.0.1',
          'port': 5173,
          'pid': 48211,
          'startedAt': 1000,
        },
      ]);
    });

    testWidgets('a port with no startedAt offers no Kill (D1)', (tester) async {
      await pin(tester, ports: [_port(startedAt: null)]);
      expect(find.text(portKillLabel), findsNothing);
    });
  });
}
