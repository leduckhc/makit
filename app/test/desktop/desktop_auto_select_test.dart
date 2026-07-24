import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_auto_select.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
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

ProviderContainer _container(List<Session> sessions) {
  final sessionsState = StateProvider<SessionsState>(
    (ref) => SessionsState(sessions),
  );
  return ProviderContainer(
    overrides: [
      sessionsProvider.overrideWith((ref) => ref.watch(sessionsState)),
    ],
  );
}

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
}
