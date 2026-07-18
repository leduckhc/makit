import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_draft_reconcile.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(
  String id, {
  String? worktreePath,
  String? branch,
  bool pending = true,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'codex',
  title: '',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  pending: pending,
  branch: branch,
  worktreePath: worktreePath,
);

/// A mutable session source so tests can simulate the server broadcasting a new
/// sessions snapshot (materialized worktree, removed session, …).
final _sessionsSource = StateProvider<SessionsState>(
  (ref) => SessionsState(const []),
);

/// Container whose pane controller starts with a virtual draft tree for
/// [draftSessionId]; [sessionsProvider] mirrors [_sessionsSource].
({ProviderContainer container, PaneTreeController panes}) _harness(
  String draftSessionId,
  List<Session> sessions,
) {
  final panes = PaneTreeController.ephemeral()
    ..bindActiveSession(draftSessionId, draftWorktreeFor('p1', draftSessionId));
  final container = ProviderContainer(
    overrides: [
      paneTreeControllerProvider.overrideWith((ref) => panes),
      sessionsProvider.overrideWith((ref) => ref.watch(_sessionsSource)),
      _sessionsSource.overrideWith((ref) => SessionsState(sessions)),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, panes: panes);
}

void main() {
  test(
    'migrates the draft tree once its session has a worktree path',
    () async {
      final h = _harness('s1', [
        _session('s1', worktreePath: '/wt/feat', branch: 'feat/x'),
      ]);
      h.container.read(desktopDraftReconcileProvider);
      await Future<void>.microtask(() {});

      expect(h.panes.state.trees.containsKey('draft:s1'), isFalse);
      expect(h.panes.state.trees.containsKey('/wt/feat'), isTrue);
      expect(h.panes.current!.worktree.branch, 'feat/x');
    },
  );

  test('prunes a draft tree whose session no longer exists', () async {
    final h = _harness('s1', const []);
    h.container.read(desktopDraftReconcileProvider);
    await Future<void>.microtask(() {});

    expect(h.panes.state.trees, isEmpty);
    expect(h.panes.state.currentKey, isNull);
  });

  test('leaves an un-materialized pending draft untouched', () async {
    final h = _harness('s1', [_session('s1')]); // no worktreePath yet
    h.container.read(desktopDraftReconcileProvider);
    await Future<void>.microtask(() {});

    expect(h.panes.state.trees.containsKey('draft:s1'), isTrue);
  });

  test('reconciles on a later snapshot, not just the initial one', () async {
    final h = _harness('s1', [_session('s1')]); // pending, no worktree
    h.container.read(desktopDraftReconcileProvider);
    await Future<void>.microtask(() {});
    expect(h.panes.state.trees.containsKey('draft:s1'), isTrue);

    // Simulate the server broadcasting the materialized session.
    h.container.read(_sessionsSource.notifier).state = SessionsState([
      _session('s1', worktreePath: '/wt/feat', branch: 'feat/x'),
    ]);
    // Force the dependent provider to recompute + deliver the listen callback.
    h.container.read(sessionsProvider);
    await Future<void>.delayed(Duration.zero);

    expect(h.panes.state.trees.containsKey('draft:s1'), isFalse);
    expect(h.panes.state.trees.containsKey('/wt/feat'), isTrue);
  });
}
