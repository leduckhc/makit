import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'selected_session.dart';

/// When no session is selected, pick the most recently active one so the chat
/// pane is useful on first launch (SPEC-10 Phase 1 acceptance).
final desktopAutoSelectSessionProvider = Provider<void>((ref) {
  void pick(SessionsState next) {
    if (next.sessions.isEmpty) return;
    final current = ref.read(selectedSessionProvider);
    if (current != null && next.byId(current) != null) return;
    final sorted = [...next.sessions]
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    ref.read(selectedSessionProvider.notifier).state = sorted.first.id;
  }

  ref.listen(sessionsProvider, (_, next) => pick(next), fireImmediately: true);
});
