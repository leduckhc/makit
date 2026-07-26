import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import 'repo_chips.dart';

/// A single session row inside a repo card (SPEC-19, moved from home_screen).
/// Swipe-to-quit, tap to open. [indented] nudges it under its worktree row.
class SessionTile extends ConsumerWidget {
  const SessionTile({super.key, required this.session, this.indented = false});
  final Session session;
  final bool indented;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('sess-${session.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: cs.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: kSpace24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsLight.power, color: cs.onErrorContainer),
            const SizedBox(width: kSpace8),
            Text(
              'Quit',
              style: TextStyle(
                color: cs.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) => _confirmAndQuit(context, ref),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: indented ? 30 : 16, right: 12),
        onTap: () => context.go('/session/${session.id}'),
        leading: AgentAvatar(agent: session.agent),
        title: Row(
          children: [
            Expanded(
              child: Text(
                session.pending && session.title.trim().isEmpty
                    ? 'new session'
                    : session.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (session.pending)
              TagChip(label: 'draft', color: cs.outline)
            else if (session.status != SessionStatus.idle)
              SessionStatusChip(status: session.status),
          ],
        ),
        subtitle: Text(
          session.pending
              ? 'Send a message to create a branch'
              : session.lastPreview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// Confirms the archive, then requests it and only reports the row as
  /// dismissed once the server acknowledges. Returning false on failure keeps
  /// the row in place (the session is still in [sessionsProvider]), so a failed
  /// archive never desyncs the list from server state.
  Future<bool> _confirmAndQuit(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirmQuit(context);
    if (!confirmed) return false;
    try {
      await ref
          .read(storeControllerProvider.notifier)
          .archiveSession(session.id);
      return true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
      return false;
    }
  }

  Future<bool> _confirmQuit(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit session?'),
        content: Text(
          'Stop “${session.title}” and remove it? '
          'The transcript stays on disk and can be re-attached.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
