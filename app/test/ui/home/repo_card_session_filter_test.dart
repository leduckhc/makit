// Mobile home parity with the desktop sidebar (SPEC-session-lifecycle-resume-list-delete): dead sessions are
// hidden from a repo card, but a cold *resumable* one stays discoverable.
// Mirrors the desktop rule in desktop/chat/desktop_sidebar.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/ui/home/repo_card.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Session _session(
  String id, {
  required SessionStatus status,
  bool resumable = false,
  bool pending = false,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: 'sess-$id',
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  branch: 'feature',
  worktreePath: '/tmp/demo',
  resumable: resumable,
  pending: pending,
);

RepoInfo _repo(List<String> sessionIds) => RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: '/tmp/demo',
      path: '/tmp/demo',
      branch: 'main',
      isPrimary: true,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: sessionIds,
    ),
  ],
);

Future<void> _pump(WidgetTester tester, List<Session> sessions) async {
  final repo = _repo([for (final s in sessions) s.id]);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: ListView(
            children: [RepoCard(repo: repo, sessions: sessions)],
          ),
        ),
      ),
      GoRoute(
        path: '/session/:id',
        builder: (context, state) => const Scaffold(body: Text('session')),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  // Not pumpAndSettle: a running session's SessionStatusDot pulses forever,
  // so settling would never complete.
  await tester.pump();
}

void main() {
  testWidgets('hides an exited, non-resumable session', (tester) async {
    await _pump(tester, [
      _session('live', status: SessionStatus.running),
      _session('dead', status: SessionStatus.exited),
    ]);

    expect(find.text('sess-live'), findsOneWidget);
    expect(find.text('sess-dead'), findsNothing);
  });

  testWidgets('keeps a cold but resumable session visible', (tester) async {
    await _pump(tester, [
      _session('cold', status: SessionStatus.exited, resumable: true),
    ]);

    expect(find.text('sess-cold'), findsOneWidget);
  });

  testWidgets('hides a dead session from the drafts section too', (
    tester,
  ) async {
    await _pump(tester, [
      _session('deadDraft', status: SessionStatus.exited, pending: true),
    ]);

    expect(find.text('sess-deadDraft'), findsNothing);
    expect(find.text('DRAFTS'), findsNothing);
  });
}
