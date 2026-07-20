// Unit tests for the ref-based session/worktree selection helpers. These take
// a [WidgetRef] rather than a [Ref], so tests capture one from a bare
// [Consumer] button press, mirroring the pattern used in
// new_session_dialog_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _pendingSession(String id, {String? worktreePath, String? branch}) =>
    Session(
      id: id,
      projectId: 'p1',
      agent: 'codex',
      title: '',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      pending: true,
      branch: branch,
      worktreePath: worktreePath,
    );

const _wtA = SelectedWorktree(projectId: 'p1', path: '/tmp/wt-a', branch: 'a');

/// Pumps a bare button whose press invokes [action] with a real [WidgetRef],
/// then taps it — the only way to exercise these WidgetRef-based helpers
/// outside of their production call sites.
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
  group('selectSessionExclusive', () {
    testWidgets('a still-pending session (no worktreePath) binds into its own '
        'virtual draft tree, not the currently-open tree', (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(
            SessionsState([_pendingSession('s1')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      // A real worktree tree is already open — the pre-fix behavior would
      // have bound the pending session into this tree instead.
      container.read(paneTreeControllerProvider.notifier).selectWorktree(_wtA);

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      expect(container.read(selectedSessionProvider), 's1');
      final current = container.read(paneTreeControllerProvider).current!;
      expect(current.worktree.path, 'draft:s1');
      // The previously-open real tree survives untouched, just no longer
      // current.
      expect(
        container.read(paneTreeControllerProvider).trees.containsKey(_wtA.path),
        isTrue,
      );
    });

    testWidgets('a session with a real worktreePath binds directly into that '
        'worktree (not a draft tree)', (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(
            SessionsState([
              _pendingSession('s1', worktreePath: '/wt/feat', branch: 'feat/x'),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      final current = container.read(paneTreeControllerProvider).current!;
      expect(current.worktree.path, '/wt/feat');
      expect(current.worktree.branch, 'feat/x');
    });

    testWidgets('an unknown session id (not yet in the store) binds into the '
        'currently-open tree rather than opening a draft tree', (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
        ],
      );
      addTearDown(container.dispose);
      container.read(paneTreeControllerProvider.notifier).selectWorktree(_wtA);

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 'not-yet-known');
      });

      expect(container.read(selectedSessionProvider), 'not-yet-known');
      expect(
        container.read(paneTreeControllerProvider).current!.worktree.path,
        _wtA.path,
      );
    });
  });

  group('closeActivePane', () {
    testWidgets('selects the surviving session after closing a split pane', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final panes = container.read(paneTreeControllerProvider.notifier);
      panes.bindActiveSession('s1', _wtA);
      panes.splitActive(Axis.horizontal);
      panes.bindActiveSession('s2', _wtA);
      container.read(selectedSessionProvider.notifier).state = 's2';

      await _invoke(tester, container, closeActivePane);

      expect(panes.activeLeafSessionId, 's1');
      expect(container.read(selectedSessionProvider), 's1');
    });
  });

  group('openDraftSession', () {
    testWidgets(
      'selects the session and binds a virtual draft tree immediately, '
      'without needing the session to exist in the store yet',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            // Deliberately empty: openDraftSession must not read the store.
            sessionsProvider.overrideWithValue(SessionsState(const [])),
          ],
        );
        addTearDown(container.dispose);

        await _invoke(tester, container, (ref) {
          openDraftSession(ref, 'p1', 's1');
        });

        expect(container.read(selectedSessionProvider), 's1');
        final current = container.read(paneTreeControllerProvider).current!;
        expect(current.worktree.path, 'draft:s1');
        expect(current.worktree.projectId, 'p1');
      },
    );

    testWidgets('opens a distinct draft tree per session id', (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        openDraftSession(ref, 'p1', 's1');
      });
      await _invoke(tester, container, (ref) {
        openDraftSession(ref, 'p1', 's2');
      });

      final trees = container.read(paneTreeControllerProvider).trees;
      expect(trees.containsKey('draft:s1'), isTrue);
      expect(trees.containsKey('draft:s2'), isTrue);
      expect(
        container.read(paneTreeControllerProvider).current!.worktree.path,
        'draft:s2',
      );
    });
  });
}
