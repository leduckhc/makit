// Screenshot generator (not a regression guard). Renders the restyled desktop
// shell headlessly and writes PNGs via `--update-goldens` for the PR. Run:
//   flutter test --no-pub --update-goldens test/desktop/chat/restyle_screenshots_test.dart
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/desktop_chat_shell.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

Session _session(String id, String title, String worktree, SessionStatus st) =>
    Session(
      id: id,
      projectId: 'p1',
      agent: 'pi',
      title: title,
      status: st,
      policy: ApprovalPolicy.askOnRisky,
      lastPreview: 'last activity preview…',
      lastActivityAt: 0,
      worktreePath: worktree,
      branch: worktree.split('/').last,
    );

Worktree _wt(String path, String branch, List<String> sessionIds) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: branch == 'main',
  insertions: 12,
  deletions: 3,
  filesChanged: 2,
  sessionIds: sessionIds,
);

void main() {
  const outDir = '/private/tmp/vB/docs/screenshots/restyle';

  setUpAll(() async {
    // Render real text (not tofu boxes): load the system San Francisco face as
    // the theme's 'SF Pro Text' family. macOS-only; harmless if absent.
    for (final path in const ['/System/Library/Fonts/SFNS.ttf']) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final bytes = await f.readAsBytes();
      final loader = FontLoader('SF Pro Text')
        ..addFont(Future.value(bytes.buffer.asByteData()));
      await loader.load();
    }
    // Load Phosphor icon weights + codicon so glyphs render instead of boxes.
    Future<void> loadFont(String family, String path) async {
      final f = File(path);
      if (!f.existsSync()) return;
      await (FontLoader(
        family,
      )..addFont(Future.value(f.readAsBytesSync().buffer.asByteData()))).load();
    }

    final phDir =
        '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
        'phosphoricons_flutter-1.0.0/lib/fonts';
    for (final (family, file) in const [
      ('PhosphorLight', 'Phosphor-Light.ttf'),
      ('PhosphorRegular', 'Phosphor.ttf'),
      ('PhosphorFill', 'Phosphor-Fill.ttf'),
      ('PhosphorBold', 'Phosphor-Bold.ttf'),
      ('PhosphorThin', 'Phosphor-Thin.ttf'),
      ('PhosphorDuotone', 'Phosphor-Duotone.ttf'),
    ]) {
      await loadFont('packages/phosphoricons_flutter/$family', '$phDir/$file');
    }
    await loadFont('codicon', 'assets/fonts/codicon.ttf');
  });

  // Golden tests are platform-dependent. Regenerate on macOS:
  //   flutter test --update-goldens test/desktop/chat/restyle_screenshots_test.dart
  final skipOffMac = !Platform.isMacOS;

  setUp(() {
    resetNodeIds();
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => null,
        );
  });

  final sessions = <Session>[
    _session('s1', 'refactor auth guard', '/tmp/wt-a', SessionStatus.idle),
    _session('s2', 'fix stream flush', '/tmp/wt-a', SessionStatus.running),
    _session(
      's3',
      'add pricing gate',
      '/tmp/wt-b',
      SessionStatus.awaitingInput,
    ),
    _session('s4', 'migrate sqlite store', '/tmp/wt-b', SessionStatus.exited),
  ];

  ProviderContainer seed() {
    final c = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(
          ReposState([
            RepoInfo(
              id: 'p1',
              name: 'makit',
              path: '/Users/dev/makit',
              pinned: true,
              lastActivityAt: 0,
              isGitRepo: true,
              defaultBranch: 'main',
              currentBranch: 'main',
              worktrees: [
                _wt('/tmp/wt-a', 'wt-a', ['s1', 's2']),
                _wt('/tmp/wt-b', 'wt-b', ['s3', 's4']),
              ],
            ),
          ]),
        ),
        sessionsProvider.overrideWithValue(SessionsState(sessions)),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        for (final s in sessions)
          sessionMetaProvider(s.id).overrideWithValue(
            const SessionMeta(
              model: _model,
              thinking: 'medium',
              models: [_model],
            ),
          ),
      ],
    );
    // A focused split (wt-b: s3,s4 → s4 active + green) beside an unfocused
    // split (wt-a: s1,s2 → dimmed, no green cap): proves the two tab fixes.
    final ws = c.read(workspaceControllerProvider.notifier);
    ws.revealSession('s1');
    ws.revealSession('s2');
    ws.divideActive(Axis.horizontal);
    ws.revealSession('s3');
    ws.revealSession('s4');
    return c;
  }

  Future<void> shot(WidgetTester tester, ThemeData theme, String name) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = seed();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: const DesktopChatShell(),
        ),
      ),
    );
    // Fixed pumps (not pumpAndSettle): running/awaiting sessions animate a
    // shimmer that never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(Uri.file('$outDir/$name.png')),
    );
  }

  testWidgets('desktop shell — dark', (tester) async {
    if (skipOffMac) return;
    await shot(tester, makitDarkTheme, 'desktop-dark');
  });

  testWidgets('desktop shell — light', (tester) async {
    if (skipOffMac) return;
    await shot(tester, makitLightTheme, 'desktop-light');
  });
}
