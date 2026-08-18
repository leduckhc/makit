import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import 'selected_session.dart';

/// Spawn a session in an EXISTING [worktreePath] with [agent] and the pending
/// config [picks], send [text] as its first message, and select it in the
/// active pane. Shared by the New-session dialog (after it resolves/creates the
/// worktree) and the in-pane starter (which already has one), so both doors
/// start a session exactly the same way.
///
/// [takeAttachments] supplies the staged images for that first message and is
/// called **after** the spawn succeeds (SPEC-starter-pane-parity D6). It takes-and-clears, so
/// invoking it late is what keeps a refused spawn from eating an upload the user
/// would otherwise have to redo.
Future<String> startSessionInWorktree(
  WidgetRef ref, {
  required String projectId,
  required String text,
  String? agent,
  String? worktreePath,
  String? branch,
  Map<String, Object> picks = const {},
  List<MediaAttachmentRef> Function()? takeAttachments,
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
  final attachments = takeAttachments?.call() ?? const <MediaAttachmentRef>[];
  store.appendOptimisticMessage(sid, text, attachments: attachments);
  store.sendMessage(sid, text, attachments: attachments);
  selectSessionExclusive(ref, sid);
  return sid;
}
