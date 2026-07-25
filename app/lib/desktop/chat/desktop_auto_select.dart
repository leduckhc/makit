import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'panes/workspace_controller.dart';
import 'selected_session.dart';

/// When no session is shown (the active tab is empty or its session no longer
/// resolves), reveal the most recently active one so the workspace is useful on
/// first launch (SPEC-10 Phase 1 acceptance). Reveal opens/focuses a tab in the
/// active split via [WorkspaceController].
final desktopAutoSelectSessionProvider = Provider<void>((ref) {
  void pick(SessionsState next) {
    if (next.sessions.isEmpty) return;
    final current = ref.read(selectedSessionProvider);
    if (current != null && next.byId(current) != null) return;
    final sorted = [...next.sessions]
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    ref
        .read(workspaceControllerProvider.notifier)
        .revealSession(sorted.first.id);
  }

  ref.listen(sessionsProvider, (_, next) => pick(next));
  Future.microtask(() => pick(ref.read(sessionsProvider)));
});
