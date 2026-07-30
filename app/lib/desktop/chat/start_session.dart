import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import 'selected_session.dart';

/// Spawn a session in an EXISTING [worktreePath] with [agent] and the pending
/// config [picks], send [text] as its first message, and select it in the
/// active pane. Shared by the New-session dialog (after it resolves/creates the
/// worktree) and the in-pane starter (which already has one), so both doors
/// start a session exactly the same way.
Future<String> startSessionInWorktree(
  WidgetRef ref, {
  required String projectId,
  required String text,
  String? agent,
  String? worktreePath,
  String? branch,
  Map<String, Object> picks = const {},
}) async {
  final store = ref.read(storeControllerProvider.notifier);
  final sid = await store.spawnSession(
    projectId,
    agent: agent,
    worktreePath: worktreePath,
    branch: branch,
    configOptions: picks.isEmpty
        ? null
        : [
            for (final e in picks.entries)
              ConfigOptionPick(id: e.key, value: e.value),
          ],
  );
  store.appendOptimisticMessage(sid, text);
  store.sendMessage(sid, text);
  selectSessionExclusive(ref, sid);
  return sid;
}
