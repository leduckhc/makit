// SPEC-ports-global-view P2a T3 — the global Ports screen widget.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';
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
  PortDocker? docker,
  String? command,
  int? startedAt,
}) => PortInfo(
  key: '$port:x:$port',
  port: port,
  address: reach == PortReach.exposed ? '0.0.0.0' : '127.0.0.1',
  reach: reach,
  pid: port,
  command: command ?? 'node vite --port $port',
  startedAt: startedAt,
  worktreePath: worktreePath,
  openUrl: 'http://127.0.0.1:$port',
  orphan: orphan,
  collision: collision,
  docker: docker,
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

/// The kill outcome lands on the Activity record (SPEC-status-and-activity), not in a snackbar, so
/// tests that assert the outcome read it from here.
late StatusCenter statusCenter;

Future<PortsWatch> _pump(
  WidgetTester tester,
  PortsSnapshot? snapshot, {
  String? repoId,
  PortsKiller? killer,
}) async {
  final watch = PortsWatch((_) {});
  statusCenter = StatusCenter();
  addTearDown(statusCenter.dispose);
  final container = ProviderContainer(
    overrides: [
      statusCenterProvider.overrideWithValue(statusCenter),
      portsWatchProvider.overrideWithValue(watch),
      portsKillerProvider.overrideWithValue(
        killer ?? PortsKiller((_) async => {'results': <dynamic>[]}),
      ),
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
      // SPEC-open-ports §3's doctrine is that a cached verdict must publish its age. On
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

  group('orphans (SPEC-ports-global-view D10)', () {
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

    testWidgets('the orphans section offers "Kill all orphans (n)" (P3b)', (
      tester,
    ) async {
      // This is the button that earns the feature: removing a worktree never
      // kills its dev server, so orphans pile up for days (mockup §6).
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            startedAt: 900,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
          _port(
            port: 5181,
            worktreePath: null,
            startedAt: 900,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
        ]),
      );
      expect(find.byKey(kPortsOrphansSection), findsOneWidget);
      expect(find.text('Kill all orphans (2)'), findsOneWidget);
    });

    testWidgets('it confirms once, naming the count and the ports (D5/D8)', (
      tester,
    ) async {
      final sent = <Map<String, dynamic>>[];
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            startedAt: 900,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
        ]),
        killer: PortsKiller((body) async {
          sent.add(body);
          return {
            'results': [
              {'outcome': 'released', 'address': '127.0.0.1', 'port': 5180},
            ],
          };
        }),
      );
      await tester.tap(find.text('Kill all orphans (1)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('5180'), findsWidgets);
      expect(sent, isEmpty, reason: 'nothing before the confirm');

      await tester.tap(find.widgetWithText(FilledButton, 'Kill all'));
      await tester.pumpAndSettle();
      expect(sent, [
        {'kind': 'ports.killOrphans'},
      ]);
      expect(statusCenter.events.single.title, contains('1 port released'));
    });

    testWidgets('dismissing the confirm sends nothing', (tester) async {
      final sent = <Map<String, dynamic>>[];
      await _pump(
        tester,
        _snap([
          _port(
            port: 5180,
            worktreePath: null,
            startedAt: 900,
            orphan: const PortOrphan(formerBranch: 'feat/gone'),
          ),
        ]),
        killer: PortsKiller((body) async {
          sent.add(body);
          return {'results': <dynamic>[]};
        }),
      );
      await tester.tap(find.text('Kill all orphans (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
    });

    testWidgets('no orphans → no bulk kill button at all', (tester) async {
      await _pump(tester, _snap([_port(port: 5173)]));
      expect(find.textContaining('Kill all orphans'), findsNothing);
    });
  });

  group('collision banner (SPEC-ports-global-view D12)', () {
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
      // D12: no suggested free port — PORT=5183 is SPEC-ports-kill's, not ours.
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

  group('docker annotation (P2c, D13)', () {
    // A published container port is held by docker's proxy, so without the
    // annotation the row reads `com.docker.backend` in the collapsed system
    // group — the exact illegibility D13 exists to fix.
    PortsSnapshot dockerSnap() => _snap([
      _port(
        port: 5432,
        worktreePath: null,
        reach: PortReach.exposed,
        command: '/Applications/Docker.app/Contents/MacOS/com.docker.backend',
        docker: const PortDocker(
          container: 'chat-ui-db-1',
          compose: '/repo/chat-ui/compose.yml',
        ),
      ),
    ]);

    Future<void> unfoldSystem(WidgetTester tester) async {
      await tester.tap(find.text('OTHER / SYSTEM'));
      await tester.pumpAndSettle();
    }

    testWidgets('the row names the container instead of docker\'s proxy', (
      tester,
    ) async {
      await _pump(tester, dockerSnap());
      await unfoldSystem(tester);
      expect(find.text('chat-ui-db-1'), findsOneWidget);
      expect(find.text('com.docker.backend'), findsNothing);
    });

    testWidgets('the row carries the docker word, and a plain row does not', (
      tester,
    ) async {
      await _pump(tester, dockerSnap());
      await unfoldSystem(tester);
      expect(find.text(portDockerWord), findsOneWidget);

      await _pump(tester, _snap([_port(port: 5173)]));
      expect(find.text(portDockerWord), findsNothing);
    });

    testWidgets('the docker token speaks its sentence once, not twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, dockerSnap());
      await unfoldSystem(tester);
      final spoken = tester
          .getSemantics(
            find.ancestor(
              of: find.text(portDockerWord),
              matching: find.byType(PortTokenPill),
            ),
          )
          .label;
      const docker = PortDocker(
        container: 'chat-ui-db-1',
        compose: '/repo/chat-ui/compose.yml',
      );
      expect(
        RegExp(
          RegExp.escape(portDockerTooltip(docker)),
        ).allMatches(spoken).length,
        1,
        reason: 'the docker sentence is spoken twice: $spoken',
      );
      handle.dispose();
    });

    testWidgets('the reach pill still reports the real bind (D13)', (
      tester,
    ) async {
      // The mockup draws `docker` as a *reach*; the shipped contract keeps reach
      // for the bind, so a published port on 0.0.0.0 must still read `exposed`.
      await _pump(tester, dockerSnap());
      await unfoldSystem(tester);
      expect(find.text(portReachPill(PortReach.exposed)), findsOneWidget);
    });
  });
}
