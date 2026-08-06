import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/port_detail_sheet.dart';
import 'package:makit/ui/ports/port_token_pill.dart';
import 'package:makit/ui/ports/ports_vocabulary.dart';
import 'package:makit/ui/ports/worktree_ports_sheet.dart';

PortInfo _port({
  int port = 5173,
  String? openUrl = 'http://127.0.0.1:5173',
  String? sessionId = 's1',
  PortHealth? health,
}) => PortInfo(
  key: '100:127.0.0.1:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: 48211,
  command: 'node vite --port $port',
  startedAt: 1000,
  worktreePath: '/wt',
  sessionId: sessionId,
  health:
      health ??
      const PortHealth(kind: PortHealthKind.ok, status: 200, probedAt: 2000),
  openUrl: openUrl,
);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('sheet 1 — the list', () {
    testWidgets('has no action buttons (nothing reachable from a flick)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          WorktreePortsSheetBody(
            branch: 'feat/open-ports',
            ports: [_port(port: 5173), _port(port: 9787)],
            onOpenPort: (_) {},
          ),
        ),
      );
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy URL'), findsNothing);
      expect(find.text('Kill'), findsNothing);
      // Two tappable port rows, each with a chevron.
      expect(find.byIcon(Icons.chevron_right), findsNothing); // uses phosphor
      expect(find.byKey(const ValueKey('ports-list-row-5173')), findsOneWidget);
      expect(find.byKey(const ValueKey('ports-list-row-9787')), findsOneWidget);
    });

    testWidgets('tapping a row invokes onOpenPort with that port', (
      tester,
    ) async {
      PortInfo? opened;
      await tester.pumpWidget(
        _host(
          WorktreePortsSheetBody(
            branch: 'feat/open-ports',
            ports: [_port(port: 5173)],
            onOpenPort: (p) => opened = p,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('ports-list-row-5173')));
      expect(opened?.port, 5173);
    });
  });

  group('sheet 2 — the detail', () {
    testWidgets('lists every fact', (tester) async {
      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(),
            branchLabel: 'feat/open-ports',
            sessionLabel: 'wire the ports snapshot',
            nowMs: 100000 + 41 * 60 * 1000 + 1000,
          ),
        ),
      );
      expect(find.text('worktree'), findsOneWidget);
      expect(find.text('session'), findsOneWidget);
      expect(find.text('command'), findsOneWidget);
      expect(find.text('pid'), findsOneWidget);
      expect(find.text('uptime'), findsOneWidget);
      expect(find.text('bound'), findsOneWidget);
      expect(find.text('probe'), findsOneWidget);
      // The two P1 actions, present when openUrl is set.
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Copy URL'), findsOneWidget);
      // No destructive control in P1.
      expect(find.text('Kill'), findsNothing);
      expect(find.textContaining('Kill'), findsNothing);
    });

    testWidgets('hides Open and Copy URL when openUrl is absent', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(openUrl: null),
            branchLabel: 'feat/open-ports',
            sessionLabel: null,
            nowMs: 100000,
          ),
        ),
      );
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy URL'), findsNothing);
    });

    testWidgets(
      'Open shows a SnackBar when the launcher cannot open the port',
      (tester) async {
        // A valid URI with no handler makes `launchUrl` return false WITHOUT
        // throwing (url_launcher's documented contract); only the thrown path
        // used to surface the failure, so the false result must be handled too.
        // (Un-mocked, this platform channel HANGS rather than fails, so the
        // handler is mandatory.)
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async => call.method == 'launch' ? false : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null,
          ),
        );

        await tester.pumpWidget(
          _host(
            PortDetailSheetBody(
              port: _port(),
              branchLabel: 'feat/open-ports',
              sessionLabel: null,
              nowMs: 100000,
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pump(); // flush the async launch
        await tester.pump(
          const Duration(milliseconds: 400),
        ); // animate SnackBar
        expect(find.text('Could not open the port'), findsOneWidget);
      },
    );

    testWidgets('Copy URL writes the url to the clipboard', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(),
            branchLabel: 'feat/open-ports',
            sessionLabel: null,
            nowMs: 100000,
          ),
        ),
      );
      await tester.tap(find.text('Copy URL'));
      await tester.pump();
      expect(calls, hasLength(1));
      expect((calls.single.arguments as Map)['text'], 'http://127.0.0.1:5173');
    });
  });

  // SPEC-41 §"Tooltips: every terse token owns a sentence": one string per
  // token, proven CONSUMED by the mobile surfaces — a long-press bubble and a
  // `Semantics.label` — not merely that the vocabulary function returns a
  // string.
  group('the vocabulary is consumed by the mobile tokens', () {
    const nowMs = 100000;
    final reachSentence = portReachTooltip(PortReach.loopback);
    final healthSentence = portHealthTooltip(
      const PortHealth(kind: PortHealthKind.ok, status: 200, probedAt: 2000),
      nowMs: nowMs,
    );

    testWidgets('sheet 1 rows speak the sentence as their semantics label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          WorktreePortsSheetBody(
            branch: 'feat/open-ports',
            ports: [_port(port: 5173)],
            nowMs: nowMs,
            onOpenPort: (_) {},
          ),
        ),
      );
      // The reach + health tokens carry their vocabulary sentence, not the
      // terse pill text, to a screen reader. (Sheet-1 rows are InkWells, which
      // merge descendant semantics into the row node, so match a containing
      // label rather than a standalone node.)
      expect(
        find.bySemanticsLabel(RegExp(RegExp.escape(reachSentence))),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp(RegExp.escape(healthSentence))),
        findsWidgets,
      );
      handle.dispose();
    });

    testWidgets('long-pressing a sheet-1 token shows its vocabulary bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          WorktreePortsSheetBody(
            branch: 'feat/open-ports',
            ports: [_port(port: 5173)],
            nowMs: nowMs,
            onOpenPort: (_) {},
          ),
        ),
      );
      // No bubble before the gesture.
      expect(find.text(reachSentence), findsNothing);
      await tester.longPress(find.text('loopback'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(reachSentence), findsOneWidget);
    });

    testWidgets('sheet 2 tokens speak the sentence as their semantics label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(),
            branchLabel: 'feat/open-ports',
            sessionLabel: null,
            nowMs: nowMs,
          ),
        ),
      );
      expect(
        find.bySemanticsLabel(RegExp(RegExp.escape(reachSentence))),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp(RegExp.escape(healthSentence))),
        findsWidgets,
      );
      handle.dispose();
    });

    testWidgets('long-pressing a sheet-2 token shows its vocabulary bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(),
            branchLabel: 'feat/open-ports',
            sessionLabel: null,
            nowMs: nowMs,
          ),
        ),
      );
      await tester.longPress(find.text('loopback'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(reachSentence), findsOneWidget);
    });
  });

  // Review round 2 claimed the `Tooltip`'s own semantics node duplicates the
  // explicit `Semantics(label: sentence)`, making a screen reader read the whole
  // sentence twice. Measured: it does NOT on this Flutter version — the nodes
  // merge to a single utterance — so no `excludeFromSemantics` was added. This
  // test stays as the guard that keeps it that way, because the failure mode is
  // invisible without a screen reader and a future Tooltip change could bring
  // it back. One token = one utterance.
  testWidgets('a token speaks its sentence exactly once, not twice', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    const sentence = 'Bound to 127.0.0.1 — reachable only from this Mac';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PortTokenPill(label: 'loopback', sentence: sentence),
        ),
      ),
    );

    // Counting widgets cannot see this: the nodes merge, so a duplicate would
    // read "<sentence>\n<sentence>" in ONE node. Count occurrences instead.
    final label = tester.getSemantics(find.byType(PortTokenPill)).label;
    expect(
      RegExp(RegExp.escape(sentence)).allMatches(label).length,
      1,
      reason: 'the sentence is spoken twice: $label',
    );
    handle.dispose();
  });

  // Finding 5: the sheet must reflect a LATER `ports.snapshot` (a port removed,
  // ownership changed, a dead server dropping to a refusal), not the one-shot
  // `ref.read` captured when it opened.
  //
  // Mutation that proves it bites: revert `showWorktreePortsSheet` to read the
  // ports with `ref.read(...)` outside the builder — the open sheet keeps the
  // stale row and the `findsNothing` below fails.
  testWidgets('an open sheet drops a port removed by a later snapshot', (
    tester,
  ) async {
    final live = StateProvider<PortsSnapshot?>(
      (ref) =>
          PortsSnapshot(ports: [_port(port: 5173)], scannedAt: 0, scanOk: true),
    );
    final container = ProviderContainer(
      overrides: [
        portsProvider.overrideWith((ref) => ref.watch(live)),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showWorktreePortsSheet(
                  ctx,
                  worktreePath: '/wt',
                  branch: 'feat/open-ports',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ports-list-row-5173')), findsOneWidget);

    // A later snapshot no longer owns the port.
    container.read(live.notifier).state = const PortsSnapshot(
      ports: [],
      scannedAt: 1,
      scanOk: true,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('ports-list-row-5173')), findsNothing);
  });
}
