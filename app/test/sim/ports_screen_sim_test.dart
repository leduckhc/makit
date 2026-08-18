// Simulation harness for the SPEC-ports-global-view global Ports screen, used to audit the
// built UI against `mockups/open-ports.html` §6 without a simulator, a device
// or a running server. Regenerate the images with:
//
//   flutter test --no-pub --update-goldens test/sim/ports_screen_sim_test.dart
//
// This is an AUDIT harness, not a regression gate: it renders the states the
// mockup pictures (iPhone 393pt and a macOS pane) so the two can be compared
// side by side. Real fonts are loaded in `setUpAll`, because the headless engine
// otherwise falls back to Ahem and every glyph rasterises as a black box —
// which would make the comparison worthless.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/ports_screen.dart';

/// One reference clock for every scene. It is anchored to the REAL wall clock
/// because `PortsScreen` reads `DateTime.now()` internally for the scan age and
/// the uptimes; a fixed epoch constant would render honest code as
/// "scanned 17895697 min ago" and make the audit unreadable. That makes the
/// images non-deterministic, which is why these tests are audit-gated below
/// rather than acting as a regression golden.
final int _nowMs = DateTime.now().millisecondsSinceEpoch;

PortInfo _port({
  required int port,
  required String command,
  String address = '127.0.0.1',
  PortReach reach = PortReach.loopback,
  int pid = 48211,
  String? worktreePath,
  String? sessionId,
  PortHealth? health,
  String? openUrl,
  int? startedAt,
  PortOrphan? orphan,
  PortCollision? collision,
}) => PortInfo(
  key: '$pid:$address:$port',
  port: port,
  address: address,
  reach: reach,
  pid: pid,
  command: command,
  startedAt: startedAt ?? _nowMs - 41 * 60 * 1000,
  worktreePath: worktreePath,
  sessionId: sessionId,
  health: health,
  openUrl: openUrl,
  orphan: orphan,
  collision: collision,
);

final _ok = PortHealth(
  kind: PortHealthKind.ok,
  status: 200,
  probedAt: _nowMs - 4000,
);
final _refused = PortHealth(
  kind: PortHealthKind.refused,
  probedAt: _nowMs - 3000,
);

/// The mockup's §6 population: three makit worktrees, a second repo, and two
/// system listeners.
PortsSnapshot _snapshot({bool scanOk = true}) => PortsSnapshot(
  scannedAt: _nowMs,
  scanOk: scanOk,
  ports: [
    _port(
      port: 5173,
      command: '/opt/homebrew/bin/node vite --port 5173',
      worktreePath: '/wt/makit-open-ports',
      sessionId: 's1',
      health: _ok,
      openUrl: 'http://127.0.0.1:5173',
    ),
    _port(
      port: 9787,
      command: '/opt/homebrew/bin/node dist/serve.js',
      address: '0.0.0.0',
      reach: PortReach.exposed,
      pid: 47120,
      worktreePath: '/wt/makit-open-ports',
      health: _ok,
      openUrl: 'http://127.0.0.1:9787',
    ),
    _port(
      port: 5174,
      command: '/opt/homebrew/bin/node vite --port 5174',
      pid: 49004,
      worktreePath: '/wt/makit-main',
      health: _ok,
      openUrl: 'http://127.0.0.1:5174',
    ),
    _port(
      port: 5175,
      command: '/opt/homebrew/bin/node vite --port 5175',
      pid: 50110,
      worktreePath: '/wt/makit-scroll',
      health: _refused,
    ),
    _port(port: 22, command: '/usr/sbin/sshd', pid: 1201),
    _port(port: 5000, command: '/System/…/ControlCenter', pid: 900),
  ],
);

/// The P2b read: two orphans (one dated, one not) plus a collision.
PortsSnapshot _orphanSnapshot() => PortsSnapshot(
  scannedAt: _nowMs,
  scanOk: true,
  ports: [
    _port(
      port: 5173,
      command: '/opt/homebrew/bin/node vite --port 5173',
      worktreePath: '/wt/makit-open-ports',
      health: _ok,
      openUrl: 'http://127.0.0.1:5173',
      collision: const PortCollision(
        withBranch: 'chore/deps',
        withWorktreePath: '/wt/makit-deps',
      ),
    ),
    _port(
      port: 5180,
      command: '/opt/homebrew/bin/node vite --port 5180',
      pid: 51002,
      health: _ok,
      orphan: PortOrphan(
        formerBranch: 'feat/desktop-tabs',
        formerWorktreePath: '/wt/makit-desktop-tabs',
        removedAt: _nowMs - 2 * 24 * 60 * 60 * 1000,
      ),
    ),
    _port(
      port: 6006,
      command: '/opt/homebrew/bin/node storybook',
      pid: 51003,
      // No `removedAt`: history never recorded when it went. Must render the
      // path with NO date rather than fabricating one (D10).
      orphan: const PortOrphan(formerWorktreePath: '/tmp/scratch'),
    ),
    _port(port: 22, command: '/usr/sbin/sshd', pid: 1201),
  ],
);

ReposState _repos() => ReposState([
  RepoInfo(
    id: 'p1',
    name: 'makit',
    path: '/repo/makit',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [
      _wt('/wt/makit-open-ports', 'feat/open-ports'),
      _wt('/wt/makit-main', 'main'),
      _wt('/wt/makit-scroll', 'fix/scroll-anchor'),
    ],
  ),
]);

Worktree _wt(String path, String branch) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: branch == 'main',
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const [],
);

Widget _scene({
  required PortsSnapshot snapshot,
  required double width,
  required double height,
  String? repoId,
}) => ProviderScope(
  overrides: [
    portsWatchProvider.overrideWithValue(PortsWatch((_) {})),
    portsProvider.overrideWithValue(snapshot),
    reposProvider.overrideWithValue(_repos()),
    sessionsProvider.overrideWithValue(SessionsState(const [])),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: makitDarkTheme,
    home: Center(
      child: SizedBox(
        width: width,
        height: height,
        child: PortsScreen(repoId: repoId),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Without real fonts the headless engine renders Ahem boxes and the audit
    // images are useless. Text font first, then the Phosphor icon weights.
    final sfns = File('/System/Library/Fonts/SFNS.ttf');
    if (sfns.existsSync()) {
      final bytes = sfns.readAsBytesSync().buffer.asByteData();
      for (final family in ['SF Pro Text', 'Roboto', '.SF NS']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
    // `kMonoFontFamily` is the literal 'monospace', which the headless engine
    // does NOT resolve — every port number and command would rasterise as an
    // Ahem box and the audit would be worthless. Bind it to the real system
    // mono face.
    final mono = File('/System/Library/Fonts/SFNSMono.ttf');
    if (mono.existsSync()) {
      final bytes = mono.readAsBytesSync().buffer.asByteData();
      for (final family in ['monospace', 'SF Mono', 'Menlo']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
    for (final weight in ['Light', 'Regular', 'Bold']) {
      final ttf = File(
        '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
        'phosphoricons_flutter-1.0.0/lib/fonts/Phosphor-$weight.ttf',
      );
      if (ttf.existsSync()) {
        await (FontLoader(
              'packages/phosphoricons_flutter/Phosphor$weight',
            )..addFont(Future.value(ttf.readAsBytesSync().buffer.asByteData())))
            .load();
      }
    }
  });

  // Goldens rasterise differently off macOS, same convention as the SPEC-context-usage/40
  // goldens in this repo. These are AUDIT images, not a regression gate: they
  // are anchored to the real clock (so the scan age reads sensibly), which means
  // they would flap if the suite compared them. Run them deliberately:
  //   PORTS_AUDIT=1 flutter test --no-pub --update-goldens test/sim/
  final skipAudit =
      !Platform.isMacOS || Platform.environment['PORTS_AUDIT'] == null;

  for (final (name, width, height, dpr, snapshot)
      in <(String, double, double, double, PortsSnapshot)>[
        // iPhone 15/16/17 logical width; the mockup's §6 phone frame.
        ('iphone_all', 393, 760, 3, _snapshot()),
        // A macOS chat pane's width, where the same screen must not look empty.
        ('macos_pane', 720, 620, 2, _snapshot()),
        // The degraded read: `lsof` denied. Must show the banner, never a fake
        // empty list (SPEC-open-ports D7).
        ('iphone_degraded', 393, 760, 3, _snapshot(scanOk: false)),
        // P2b: the orphans section and the collision banner — the two reads the
        // mockup's §6 says earn the whole feature. Includes an orphan whose
        // history has NO removal date, which must render without one (D10).
        ('iphone_orphans', 393, 820, 3, _orphanSnapshot()),
      ]) {
    testWidgets('ports screen — $name', (tester) async {
      tester.view.physicalSize = Size(width * dpr, height * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _scene(snapshot: snapshot, width: width, height: height),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('images/ports_screen_$name.png'),
      );
    }, skip: skipAudit);
  }

  // The empty state is worth its own image: it is the common case for a machine
  // with nothing running, and the mockup words it specifically.
  testWidgets('ports screen — empty', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 500 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _scene(
        snapshot: PortsSnapshot(
          scannedAt: _nowMs,
          scanOk: true,
          ports: const [],
        ),
        width: 393,
        height: 500,
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/ports_screen_empty.png'),
    );
  }, skip: skipAudit);
}
