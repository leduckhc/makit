import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_session_prune.dart';
import 'package:makit/desktop/chat/panes/split_node.dart' as node;
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(String id) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: id,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
);

final _snapshot = StateProvider<({List<Session> sessions, bool loaded})>(
  (ref) => (sessions: const [], loaded: false),
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    sessionsProvider.overrideWith(
      (ref) => SessionsState(ref.watch(_snapshot).sessions),
    ),
    sessionsLoadedProvider.overrideWith((ref) => ref.watch(_snapshot).loaded),
  ],
);

/// Mirrors the widget-level `ref.watch` in `desktop_app.dart`: the provider is
/// only alive (and listening) while something subscribes to it.
void _keepAlive(ProviderContainer container) => container.listen(
  desktopSessionPruneProvider,
  (_, _) {},
  fireImmediately: true,
);

/// Simulates a `sessions.snapshot` frame arriving from the server.
void _push(ProviderContainer container, List<Session> sessions) =>
    container.read(_snapshot.notifier).state = (
      sessions: sessions,
      loaded: true,
    );

List<String?> _tabSessions(WorkspaceState state) {
  final ids = <String?>[];
  void walk(node.SplitNode n) {
    if (n is node.Split) {
      ids.addAll(n.tabs.map((t) => t.sessionId));
    } else if (n is node.Splitter) {
      walk(n.first);
      walk(n.second);
    }
  }

  walk(state.root);
  return ids;
}

void main() {
  test('closes the tab of a session archived from another client', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ctrl = container.read(workspaceControllerProvider.notifier);
    ctrl.revealSession('a');
    ctrl.revealSession('b');
    _keepAlive(container);

    // Both sessions live on the server.
    _push(container, [_session('a'), _session('b')]);
    await Future<void>.delayed(Duration.zero);
    expect(_tabSessions(container.read(workspaceControllerProvider)), [
      'a',
      'b',
    ]);

    // 'b' is archived/quit elsewhere: the next snapshot drops it, so its tab
    // must go too instead of lingering as an empty pane.
    _push(container, [_session('a')]);
    await Future<void>.delayed(Duration.zero);
    expect(_tabSessions(container.read(workspaceControllerProvider)), ['a']);
  });

  test('drops restored tabs whose sessions are gone from the server', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ctrl = container.read(workspaceControllerProvider.notifier);
    // A persisted layout from a previous run: two of its sessions no longer
    // exist server-side.
    ctrl.revealSession('gone-1');
    ctrl.revealSession('alive');
    ctrl.revealSession('gone-2');
    _keepAlive(container);

    _push(container, [_session('alive')]);
    await Future<void>.delayed(Duration.zero);

    expect(_tabSessions(container.read(workspaceControllerProvider)), [
      'alive',
    ]);
  });

  test('keeps tabs until the first snapshot has arrived', () async {
    final container = _container();
    addTearDown(container.dispose);
    container.read(workspaceControllerProvider.notifier).revealSession('a');
    _keepAlive(container);
    await Future<void>.delayed(Duration.zero);

    // No snapshot yet (offline / still connecting): an empty session list is
    // "unknown", not "the server has none" — the layout must survive.
    expect(_tabSessions(container.read(workspaceControllerProvider)), ['a']);
  });

  test('an empty snapshot prunes every session tab', () async {
    final container = _container();
    addTearDown(container.dispose);
    container.read(workspaceControllerProvider.notifier).revealSession('a');
    _keepAlive(container);

    _push(container, const []);
    await Future<void>.delayed(Duration.zero);

    expect(_tabSessions(container.read(workspaceControllerProvider)), [null]);
  });
}
