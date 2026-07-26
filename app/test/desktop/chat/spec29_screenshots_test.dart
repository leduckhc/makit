// Golden "screenshots" of the SPEC-29 archive UI, rendered with fake data on
// the app's real dark theme. Regenerate with:
//   flutter test --update-goldens test/desktop/chat/spec29_screenshots_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/archived_sidebar_view.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';

// ---- fake data (mirrors the app's "Open with fake data" demo) --------------

Session _s(
  String id,
  String project,
  String title,
  String agent, {
  SessionStatus status = SessionStatus.idle,
  String branch = 'main',
  String preview = '',
}) => Session(
  id: id,
  projectId: project,
  agent: agent,
  title: title,
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  lastActivityAt: DateTime.now().millisecondsSinceEpoch,
  lastPreview: preview,
  branch: branch,
);

Worktree _wt(
  String id,
  String branch,
  List<String> sessionIds, {
  bool primary = false,
  int ins = 0,
  int del = 0,
  int files = 0,
}) => Worktree(
  id: id,
  path: '/repo/$id',
  branch: branch,
  isPrimary: primary,
  insertions: ins,
  deletions: del,
  filesChanged: files,
  sessionIds: sessionIds,
);

RepoInfo _repo(String id, String name, List<Worktree> wts) => RepoInfo(
  id: id,
  name: name,
  path: '/repo/$id',
  pinned: true,
  lastActivityAt: DateTime.now().millisecondsSinceEpoch,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: wts,
);

final _repos = ReposState([
  _repo('makit', 'makit', [
    _wt(
      'wt-resume',
      'feat/resume-sessions',
      ['a1', 'a2'],
      ins: 812,
      del: 96,
      files: 34,
    ),
    _wt('wt-main', 'main', ['a3'], primary: true),
  ]),
  _repo('cmux', 'cmux', [
    _wt('wt-gh', 'feat/ghostty', ['a4'], ins: 40, del: 12, files: 3),
  ]),
]);

final _sessions = SessionsState([
  _s(
    'a1',
    'makit',
    'Adapter-native resume',
    'pi',
    status: SessionStatus.running,
    branch: 'feat/resume-sessions',
    preview: 'Wired session/load in silent mode; reattach continues seq.',
  ),
  _s(
    'a2',
    'makit',
    'Archive UX + grouping',
    'pi',
    branch: 'feat/resume-sessions',
    preview: 'Sidebar toggle + group-by.',
  ),
  _s('a3', 'makit', 'PR status pill', 'codex', branch: 'main'),
  _s('a4', 'cmux', 'Ghostty rebuild', 'codex', branch: 'feat/ghostty'),
]);

Map<String, dynamic> _arch(
  String id,
  String title,
  String agent,
  String branch, {
  bool orphaned = false,
  String preview = '',
}) => {
  'id': id,
  'projectId': 'makit',
  'agent': agent,
  'title': title,
  'status': 'exited',
  'policy': 'ask-on-risky',
  'archived': true,
  'orphaned': orphaned,
  'branch': branch,
  'lastPreview': preview,
  'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
};

/// Connection that serves a fake archived list (fake server stand-in).
class _FakeConn extends ConnectionController {
  _FakeConn() : super(const _NoStore());
  @override
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) {
    if (body['kind'] == 'session.listArchived') {
      return Future.value({
        'sessions': [
          _arch('x1', 'Silent-load replay dedup', 'pi', 'feat/resume-sessions'),
          _arch('x2', 'Capability negotiation', 'pi', 'feat/resume-sessions'),
          _arch('x3', 'Push wake coordinator', 'pi', 'main'),
          _arch(
            'x4',
            'Ghostty submodule bump',
            'codex',
            'feat/ghostty',
            orphaned: true,
          ),
          _arch('x5', 'Sidebar ExtensionKit', 'codex', 'feat/sidebar-ext'),
        ],
      });
    }
    return Future.value(const {});
  }
}

class _NoStore implements SecureStore {
  const _NoStore();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Widget _scene({required bool archived}) => ProviderScope(
  overrides: [
    reposProvider.overrideWithValue(_repos),
    sessionsProvider.overrideWithValue(_sessions),
    connectionControllerProvider.overrideWith((_) => _FakeConn()),
    sidebarArchivedProvider.overrideWith((_) => archived),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: makitDarkTheme,
    home: const Scaffold(
      body: SizedBox(width: 300, height: 640, child: DesktopSidebar()),
    ),
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Future<void> load(String family, String path) async {
      final f = File(path);
      if (!f.existsSync()) return;
      final loader = FontLoader(family)
        ..addFont(Future.value(f.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }

    // Register real glyphs under every family the text might resolve to — the
    // theme asks for 'SF Pro Text' but Material's default typography falls back
    // to 'Roboto' — so golden text renders as letters, not Ahem boxes.
    for (final family in const [
      'Roboto',
      'SF Pro Text',
      '.SF Pro Text',
      'CupertinoSystemText',
    ]) {
      await load(family, '/System/Library/Fonts/Geneva.ttf');
    }
    await load('SF Mono', '/System/Library/Fonts/Monaco.ttf');
    final ttf = File(
      '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
      'phosphoricons_flutter-1.0.0/lib/fonts/Phosphor-Light.ttf',
    );
    if (ttf.existsSync()) {
      final loader = FontLoader('packages/phosphoricons_flutter/PhosphorLight')
        ..addFont(Future.value(ttf.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  });

  final skipOffMac = !Platform.isMacOS;

  testWidgets('sidebar — active (fake data)', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(300 * 2, 660 * 2);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_scene(archived: false));
    // A running session pulses forever, so render a single settled-ish frame
    // instead of pumpAndSettle (which would time out on the animation).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await expectLater(
      find.byType(DesktopSidebar),
      matchesGoldenFile('goldens/spec29_sidebar_active.png'),
    );
  }, skip: skipOffMac);

  testWidgets('sidebar — archived, grouped by repo (fake data)', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(300 * 2, 660 * 2);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_scene(archived: true));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(DesktopSidebar),
      matchesGoldenFile('goldens/spec29_sidebar_archived.png'),
    );
  }, skip: skipOffMac);
}
