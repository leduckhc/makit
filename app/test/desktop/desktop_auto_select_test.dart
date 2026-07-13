import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_auto_select.dart';
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
  test('auto-selects the most recently active session when none selected', () {
    final container = _container([
      _session('older', 100),
      _session('newer', 200),
    ]);
    addTearDown(container.dispose);

    container.read(desktopAutoSelectSessionProvider);

    expect(container.read(selectedSessionProvider), 'newer');
  });

  test('does not override an existing valid selection', () {
    final container = _container([
      _session('older', 100),
      _session('newer', 200),
    ]);
    addTearDown(container.dispose);

    container.read(selectedSessionProvider.notifier).state = 'older';
    container.read(desktopAutoSelectSessionProvider);

    expect(container.read(selectedSessionProvider), 'older');
  });

  test('re-selects when the current session disappears', () {
    final container = _container([_session('only', 50)]);
    addTearDown(container.dispose);

    container.read(selectedSessionProvider.notifier).state = 'gone';
    container.read(desktopAutoSelectSessionProvider);

    expect(container.read(selectedSessionProvider), 'only');
  });
}
