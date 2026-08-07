// SPEC-42 P2a T3 — the global Ports screen widget.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/port_detail_sheet.dart';
import 'package:makit/ui/ports/port_token_pill.dart';
import 'package:makit/ui/ports/ports_screen.dart';
import 'package:makit/ui/ports/ports_vocabulary.dart';

PortInfo _port({
  required int port,
  String? worktreePath = '/A/feat',
  PortReach reach = PortReach.loopback,
  PortOrphan? orphan,
  PortCollision? collision,
}) => PortInfo(
  key: '$port:x:$port',
  port: port,
  address: reach == PortReach.exposed ? '0.0.0.0' : '127.0.0.1',
  reach: reach,
  pid: port,
  command: 'node vite --port $port',
  worktreePath: worktreePath,
  openUrl: 'http://127.0.0.1:$port',
  orphan: orphan,
  collision: collision,
);

Worktree _wt(String path, String branch) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const [],
);

final _repos = ReposState([
  RepoInfo(
    id: 'A',
    name: 'makit',
    path: '/A',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [_wt('/A/feat', 'feat/open-ports')],
  ),
]);

Future<PortsWatch> _pump(
  WidgetTester tester,
  PortsSnapshot? snapshot, {
  String? repoId,
}) async {
  final watch = PortsWatch((_) {});
  final container = ProviderContainer(
    overrides: [
      portsWatchProvider.overrideWithValue(watch),
      portsProvider.overrideWithValue(snapshot),
      reposProvider.overrideWithValue(_repos),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: PortsScreen(repoId: repoId)),
    ),
  );
  await tester.pumpAndSettle();
  return watch;
}

PortsSnapshot _snap(List<PortInfo> ports, {bool scanOk = true}) =>
    PortsSnapshot(ports: ports, scannedAt: 0, scanOk: scanOk);

void main() {
  testWidgets('empty state when the scan succeeded with zero ports', (
    tester,
  ) async {
    await _pump(tester, _snap(const []));
    expect(find.byKey(kPortsEmptyState), findsOneWidget);
    expect(find.textContaining('No dev servers running'), findsOneWidget);
    expect(find.byKey(kPortsDegradedBanner), findsNothing);
  });

  testWidgets('degraded banner when scanOk is false (not a fake empty list)', (
    tester,
  ) async {
    await _pump(tester, _snap(const [], scanOk: false));
    expect(find.byKey(kPortsDegradedBanner), findsOneWidget);
    expect(find.byKey(kPortsEmptyState), findsNothing);
  });

  testWidgets('filter chips switch the visible set', (tester) async {
    await _pump(
      tester,
      _snap([_port(port: 5173), _port(port: 9787, reach: PortReach.exposed)]),
    );
    // All: both ports render.
    expect(find.text('5173'), findsOneWidget);
    expect(find.text('9787'), findsOneWidget);

    // Switch to Exposed: only the wildcard-bound port survives.
    // The chip now carries its count (mockup §6), so match the whole label.
    await tester.tap(find.text('Exposed 1'));
    await tester.pumpAndSettle();
    expect(find.text('5173'), findsNothing);
    expect(find.text('9787'), findsOneWidget);
  });

  testWidgets('unowned-only renders the system group', (tester) async {
    await _pump(tester, _snap([_port(port: 22, worktreePath: null)]));
    expect(find.text('OTHER / SYSTEM'), findsOneWidget);
  });

  testWidgets('the system group is folded by default and unfolds on tap', (
    tester,
  ) async {
    // Mockup §6: "System listeners are collapsed by default — they're noise, not
    // work." The header is still shown (so the ports are discoverable), but its
    // rows must not push a real worktree's ports off the first screen.
    await _pump(tester, _snap([_port(port: 22, worktreePath: null)]));
    expect(find.text('OTHER / SYSTEM'), findsOneWidget);
    expect(find.text('22'), findsNothing);

    await tester.tap(find.text('OTHER / SYSTEM'));
    await tester.pumpAndSettle();
    expect(find.text('22'), findsOneWidget);
  });

  testWidgets('tapping a port opens the P1 detail sheet', (tester) async {
    await _pump(tester, _snap([_port(port: 5173)]));
    await tester.tap(find.text('5173'));
    await tester.pumpAndSettle();
    expect(find.byType(PortDetailSheetBody), findsOneWidget);
  });

  testWidgets('holds the ports watch while mounted, releases to 0 on dispose', (
    tester,
  ) async {
    final watch = await _pump(tester, _snap([_port(port: 5173)]));
    expect(watch.watcherCount, 1);
    await tester.pumpWidget(const SizedBox());
    expect(watch.watcherCount, 0);
  });

  group('mockup §6 affordances', () {
    testWidgets('Exposed and Orphans chips carry their counts', (tester) async {
      // The mockup badges these two because they are the filters you only tap
      // when they are non-zero; without the count you must tap to find out.
      await _pump(
        tester,
        _snap([
          _port(port: 5173),
          _port(port: 9787, reach: PortReach.exposed),
          _port(
            port: 5180,
            worktreePath: null,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
        ]),
      );
      expect(find.text('Exposed 1'), findsOneWidget);
      expect(find.text('Orphans 1'), findsOneWidget);
      // A zero count is not drawn — a badge reading 0 is noise.
      expect(find.text('Mine 2'), findsNothing);
    });

    testWidgets('the app bar states how many are listening and how stale', (
      tester,
    ) async {
      // SPEC-41 §3's doctrine is that a cached verdict must publish its age. On
      // this screen there is no tooltip to carry it, so the app bar does.
      final now = DateTime.now().millisecondsSinceEpoch;
      await _pump(
        tester,
        PortsSnapshot(
          scannedAt: now - 6000,
          scanOk: true,
          ports: [_port(port: 5173), _port(port: 9787)],
        ),
      );
      expect(find.textContaining('2 listening'), findsOneWidget);
      expect(find.textContaining('6 s ago'), findsOneWidget);
    });
  });

  group('orphans (SPEC-42 D10)', () {
    testWidgets('orphan renders its own group with "was <branch>, removed"', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            orphan: PortOrphan(
              formerBranch: 'feat/desktop-tabs',
              formerWorktreePath: '/repo/gone',
              removedAt: now - const Duration(days: 2).inMilliseconds,
            ),
          ),
        ]),
      );
      expect(find.byKey(kPortsOrphansSection), findsOneWidget);
      expect(find.textContaining('was feat/desktop-tabs'), findsOneWidget);
      expect(find.textContaining('removed 2d ago'), findsOneWidget);
      // The orphan does NOT leak into the system group.
      expect(find.text('OTHER / SYSTEM'), findsNothing);
    });

    testWidgets('the removal date survives a 393pt phone width', (
      tester,
    ) async {
      // Regression: the row concatenated `command · was <branch>, removed Nd ago`
      // into ONE ellipsised line, so on a real phone the date — the entire point
      // of D10 — was the part that got cut. `find.text` cannot catch this:
      // ellipsis is a paint concern and `Text.data` still holds the whole
      // string, so this asserts the render object did not exceed its lines.
      tester.view.physicalSize = const Size(393 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final now = DateTime.now().millisecondsSinceEpoch;
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            orphan: PortOrphan(
              formerBranch: 'feat/desktop-tabs',
              formerWorktreePath: '/repo/gone',
              removedAt: now - const Duration(days: 2).inMilliseconds,
            ),
          ),
        ]),
      );

      final detail = find.text('was feat/desktop-tabs, removed 2d ago');
      expect(detail, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(detail).didExceedMaxLines,
        isFalse,
        reason: 'the removal date must not be ellipsised away on a phone',
      );
    });

    testWidgets('the Orphans filter shows only the orphans section', (
      tester,
    ) async {
      await _pump(
        tester,
        _snap([
          _port(port: 5173),
          _port(
            port: 5180,
            worktreePath: null,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
        ]),
      );
      await tester.tap(find.text('Orphans 1'));
      await tester.pumpAndSettle();
      expect(find.byKey(kPortsOrphansSection), findsOneWidget);
      expect(find.text('5180'), findsOneWidget);
      expect(find.text('5173'), findsNothing);
    });

    testWidgets('D10: an orphan with no removedAt renders NO date', (
      tester,
    ) async {
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            orphan: const PortOrphan(
              formerBranch: 'feat/gone',
              formerWorktreePath: '/repo/gone',
              // removedAt deliberately absent — history never recorded it.
            ),
          ),
        ]),
      );
      expect(find.byKey(kPortsOrphansSection), findsOneWidget);
      expect(find.textContaining('was feat/gone'), findsOneWidget);
      // No fabricated date: no "removed", no "ago", no epoch string — asserted
      // WITHIN the orphans section, because the app bar legitimately carries a
      // scan age ("scanned 4 s ago") that is not a claim about this orphan.
      final inSection = find.descendant(
        of: find.byKey(kPortsOrphansSection),
        matching: find.byType(Text),
      );
      final texts = tester
          .widgetList<Text>(inSection)
          .map((t) => t.data ?? '')
          .join(' | ');
      expect(texts, contains('was feat/gone'));
      expect(texts, isNot(contains('removed')));
      expect(texts, isNot(contains('ago')));
      expect(texts, isNot(contains('1970')));
    });

    testWidgets('no "Kill all orphans" control exists (P3, not P2)', (
      tester,
    ) async {
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
        ]),
      );
      expect(find.byKey(kPortsOrphansSection), findsOneWidget);
      expect(find.textContaining('Kill'), findsNothing);
      expect(
        find.widgetWithText(ElevatedButton, 'Kill all orphans'),
        findsNothing,
      );
    });
  });

  group('collision banner (SPEC-42 D12)', () {
    testWidgets('names the other branch and offers NO suggested port', (
      tester,
    ) async {
      await _pump(
        tester,
        _snap([
          _port(
            port: 5173,
            collision: const PortCollision(
              withBranch: 'chore/deps',
              withWorktreePath: '/A/deps',
            ),
          ),
        ]),
      );
      expect(find.byKey(kPortsCollisionBanner), findsOneWidget);
      expect(find.textContaining('chore/deps'), findsWidgets);
      // D12: no suggested free port — PORT=5183 is SPEC-43's, not ours.
      expect(find.textContaining('PORT='), findsNothing);
      expect(find.textContaining('5183'), findsNothing);
      expect(find.textContaining('free'), findsNothing);
    });

    testWidgets('no banner when no port collides', (tester) async {
      await _pump(tester, _snap([_port(port: 5173)]));
      expect(find.byKey(kPortsCollisionBanner), findsNothing);
    });

    // Mockup §9's legend renders a collision as `5173 clash`, and its
    // accessibility rule is explicit: "every tint ships with a word (refused,
    // exposed, clash, orphan)". Without a marker ON the row, the banner names a
    // branch but nothing says WHICH of the listed ports it means — and
    // `portClashWord` sat in the vocabulary unused, which is how we found this.
    testWidgets('the colliding row itself carries the clash word', (
      tester,
    ) async {
      await _pump(
        tester,
        _snap([
          _port(port: 5173, collision: const PortCollision(withBranch: 'x/y')),
          _port(port: 5174),
        ]),
      );
      expect(find.text(portClashWord), findsOneWidget);
    });

    testWidgets('a non-colliding row carries no clash word', (tester) async {
      await _pump(tester, _snap([_port(port: 5173)]));
      expect(find.text(portClashWord), findsNothing);
    });

    testWidgets('the clash token speaks its sentence once, not twice', (
      tester,
    ) async {
      // The pill carries Semantics(label:) itself, so a second wrapper would
      // read the sentence twice — the trap ports_sheets_test.dart already pins.
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        _snap([
          _port(port: 5173, collision: const PortCollision(withBranch: 'x/y')),
        ]),
      );
      final spoken = tester
          .getSemantics(
            find.ancestor(
              of: find.text(portClashWord),
              matching: find.byType(PortTokenPill),
            ),
          )
          .label;
      final sentence = portCollisionTooltip(
        const PortCollision(withBranch: 'x/y'),
        port: 5173,
      );
      expect(
        RegExp(RegExp.escape(sentence)).allMatches(spoken).length,
        1,
        reason: 'the clash sentence is spoken twice: $spoken',
      );
      handle.dispose();
    });
  });

  group('orphan word (mockup §9 — same rule as clash)', () {
    testWidgets('the orphan token speaks its sentence once, not twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      const orphan = PortOrphan(formerBranch: 'gone/branch');
      await _pump(tester, _snap([_port(port: 5180, orphan: orphan)]));
      final spoken = tester
          .getSemantics(
            find.ancestor(
              of: find.text(portOrphanWord),
              matching: find.byType(PortTokenPill),
            ),
          )
          .label;
      expect(
        RegExp(
          RegExp.escape(portOrphanTooltip(orphan, nowMs: 0)),
        ).allMatches(spoken).length,
        1,
        reason: 'the orphan sentence is spoken twice: $spoken',
      );
      handle.dispose();
    });
  });
}
