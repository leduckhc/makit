import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_auto_select.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart' as node;
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(String id, int lastActivity) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: id,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: lastActivity,
);

final _sessionsState = StateProvider<SessionsState>(
  (ref) => SessionsState(const []),
);

ProviderContainer _container(List<Session> sessions) {
  final container = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWith((ref) => ref.watch(_sessionsState)),
    ],
  );
  container.read(_sessionsState.notifier).state = SessionsState(sessions);
  return container;
}

/// Pushes a new snapshot, as the store does on every agent message/status
/// change (each one bumps `lastActivityAt`).
void _pushSessions(ProviderContainer container, List<Session> sessions) =>
    container.read(_sessionsState.notifier).state = SessionsState(sessions);

void main() {
  test(
    'auto-reveals the most recently active session when the active tab is empty',
    () async {
      final container = _container([
        _session('older', 100),
        _session('newer', 200),
      ]);
      addTearDown(container.dispose);

      container.read(desktopAutoSelectSessionProvider);
      await Future<void>.delayed(Duration.zero);

      // Reveal opens/focuses a tab for the session in the active split; the
      // derived selection mirrors that tab.
      expect(container.read(selectedSessionProvider), 'newer');
    },
  );

  test('does not override an existing valid selection', () async {
    final container = _container([
      _session('older', 100),
      _session('newer', 200),
    ]);
    addTearDown(container.dispose);

    // A session already revealed into the active tab is a valid selection.
    container.read(workspaceControllerProvider.notifier).revealSession('older');
    container.read(desktopAutoSelectSessionProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(selectedSessionProvider), 'older');
  });

  test('re-reveals when the current session disappears', () async {
    final container = _container([_session('only', 50)]);
    addTearDown(container.dispose);

    // Reveal a session that isn't in the store (a stale tab): auto-select
    // replaces it with the surviving most-recent one.
    container.read(workspaceControllerProvider.notifier).revealSession('gone');
    container.read(desktopAutoSelectSessionProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(selectedSessionProvider), 'only');
  });

  test('output elsewhere does not pull focus off an empty active tab', () async {
    final container = _container([_session('a', 100)]);
    addTearDown(container.dispose);
    final ctrl = container.read(workspaceControllerProvider.notifier);

    // Session 'a' lives in a tab; the user then opens a fresh "New" tab and is
    // working in it (nothing bound yet).
    ctrl.revealSession('a');
    final splitId = container.read(workspaceControllerProvider).activeSplitId;
    final blank = node.Tab(id: node.nextNodeId(node.SplitNodeKind.tab));
    ctrl.openTab(splitId, blank);
    expect(container.read(selectedSessionProvider), isNull);

    container.read(desktopAutoSelectSessionProvider);
    await Future<void>.delayed(Duration.zero);
    // Session 'a' produces output (a new snapshot, later lastActivityAt).
    _pushSessions(container, [_session('a', 500)]);
    await Future<void>.delayed(Duration.zero);

    // The empty tab the user is working in keeps focus, and is not hijacked
    // into hosting session 'a'.
    expect(
      activeTab(container.read(workspaceControllerProvider))?.id,
      blank.id,
    );
    expect(container.read(selectedSessionProvider), isNull);
  });

  test('does not steal focus from an unfocused split', () async {
    final container = _container([_session('a', 100), _session('b', 200)]);
    addTearDown(container.dispose);
    final ctrl = container.read(workspaceControllerProvider.notifier);

    // Set up: split A holds session 'a' (older), split B holds session 'b' (newer).
    // Focus split A (user is reading there).
    ctrl.revealSession('a');
    ctrl.divideActive(Axis.vertical);
    ctrl.revealSession('b');
    // Now split B is active, so user clicks to split A.
    ctrl.selectSplit('a');
    expect(container.read(selectedSessionProvider), 'a');

    final workspace1 = container.read(workspaceControllerProvider);
    container.read(desktopAutoSelectSessionProvider);
    await Future<void>.delayed(Duration.zero);

    // Session 'b' produces output: a fresh snapshot with a later
    // lastActivityAt, which must NOT steal focus back to split B.
    _pushSessions(container, [_session('a', 100), _session('b', 900)]);
    await Future<void>.delayed(Duration.zero);

    // Split A should still be active.
    final workspace2 = container.read(workspaceControllerProvider);
    expect(workspace1.activeSplitId, workspace2.activeSplitId);
    expect(container.read(selectedSessionProvider), 'a');
  });
}

extension on WorkspaceController {
  /// Find a split by its session id (tab within that split).
  String? _splitIdForSession(String sessionId) {
    String? find(node.SplitNode nodeArg) {
      if (nodeArg is node.Split) {
        if (nodeArg.tabs.any((t) => t.sessionId == sessionId)) {
          return nodeArg.id;
        }
        return null;
      }
      if (nodeArg is node.Splitter) {
        return find(nodeArg.first) ?? find(nodeArg.second);
      }
      return null;
    }

    return find(state.root);
  }

  /// Switch active split by finding which split holds a given session.
  void selectSplit(String sessionId) {
    final splitId = _splitIdForSession(sessionId);
    if (splitId != null) {
      state = WorkspaceState(root: state.root, activeSplitId: splitId);
    }
  }
}
