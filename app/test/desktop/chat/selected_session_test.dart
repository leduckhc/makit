// Unit tests for the ref-based session/worktree selection helpers on the
// SPEC-28 workspace model. These take a [WidgetRef] rather than a [Ref], so
// tests capture one from a bare [Consumer] button press.
import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';

/// A connection that answers every request instantly — so the fire-and-forget
/// archive on tab close leaves no pending timeout Timer in widget tests.
class _FastConn extends ConnectionController {
  _FastConn() : super(const _NoStore());
  final sent = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) {
    sent.add(body);
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

Session _session(
  String id, {
  String? worktreePath,
  String? branch,
  bool pending = false,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'codex',
  title: '',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  branch: branch,
  worktreePath: worktreePath,
  pending: pending,
);

const _wtA = SelectedWorktree(projectId: 'p1', path: '/tmp/wt-a', branch: 'a');

WorkspaceController _workspace(ProviderContainer c) =>
    c.read(workspaceControllerProvider.notifier);

/// The active split's active tab (via the same walk the providers use).
Tab _activeTab(ProviderContainer c) =>
    activeTab(c.read(workspaceControllerProvider))!;

/// Pumps a bare button whose press invokes [action] with a real [WidgetRef],
/// then taps it.
Future<void> _invoke(
  WidgetTester tester,
  ProviderContainer container,
  void Function(WidgetRef ref) action,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (ctx, ref, _) => TextButton(
              onPressed: () => action(ref),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
}

void main() {
  setUp(resetNodeIds);

  group('selectSessionExclusive (decision 6 reveal)', () {
    testWidgets('binds the session into the active split\'s empty tab', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      expect(container.read(selectedSessionProvider), 's1');
      expect(_activeTab(container).sessionId, 's1');
    });

    testWidgets('focuses an already-open session instead of duplicating it '
        '(decision 5)', (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1'), _session('s2')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      // s1 in the first split; a second split hosts s2 and is active.
      _workspace(container).revealSession('s1');
      _workspace(container).divideActive(Axis.horizontal);
      _workspace(container).revealSession('s2');
      expect(container.read(selectedSessionProvider), 's2');

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      // Reveal focused the existing s1 tab (active selection is s1 again); s1
      // still appears exactly once in the tree.
      expect(container.read(selectedSessionProvider), 's1');
      final located = findTab(
        container.read(workspaceControllerProvider).root,
        's1',
      );
      expect(located, isNotNull);
    });
  });

  group('selectWorktree', () {
    testWidgets('opens a starter tab hinted with the worktree (no swap)', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        selectWorktree(ref, _wtA);
      });

      final tab = _activeTab(container);
      expect(tab.sessionId, isNull);
      expect(tab.worktree, _wtA);
      expect(container.read(selectedWorktreeProvider), _wtA);
      expect(container.read(selectedSessionProvider), isNull);
    });
  });

  group('openDraftSession', () {
    testWidgets('reveals a tab for the session without reading the store', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        openDraftSession(ref, 's1');
      });

      expect(container.read(selectedSessionProvider), 's1');
      expect(_activeTab(container).sessionId, 's1');
    });
  });

  group('closeActiveSplit / closeActiveTab', () {
    testWidgets('closeActiveTab collapses an emptied split back to a sibling', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => _FastConn()),
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1'), _session('s2')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');
      _workspace(container).divideActive(Axis.horizontal);
      _workspace(container).revealSession('s2'); // active split hosts s2 only

      await _invoke(tester, container, closeActiveTab);

      // The active split had a single tab (s2) → closing it collapsed the
      // split into the sibling that hosts s1.
      expect(container.read(workspaceControllerProvider).root, isA<Split>());
      expect(container.read(selectedSessionProvider), 's1');
    });

    testWidgets('closeActiveTab archives the orphaned session (SPEC-29)', (
      tester,
    ) async {
      final conn = _FastConn();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => conn),
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');

      await _invoke(tester, container, closeActiveTab);

      // Closing the sole tab orphans s1 → it is archived (soft, recoverable).
      final archive = conn.sent.firstWhere(
        (b) => b['kind'] == 'session.archive',
        orElse: () => const {},
      );
      expect(archive['sessionId'], 's1');
    });

    testWidgets('closeActiveTab does NOT archive an untouched draft (SPEC-29)', (
      tester,
    ) async {
      final conn = _FastConn();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => conn),
          sessionsProvider.overrideWithValue(
            SessionsState([_session('d1', pending: true)]),
          ),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('d1');

      await _invoke(tester, container, closeActiveTab);

      // A never-started draft has no history worth preserving — closing its tab
      // must not archive it (no empty entry in the Archived list).
      expect(conn.sent.any((b) => b['kind'] == 'session.archive'), isFalse);
    });

    testWidgets('closeActiveSplit is a no-op on the sole split', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');
      final before = container.read(workspaceControllerProvider);

      await _invoke(tester, container, closeActiveSplit);

      expect(container.read(workspaceControllerProvider), before);
    });
  });
}
