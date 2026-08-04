import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/session_status_dot.dart';
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
        // Sits under its worktree's branch name (caret slot + glyph + gap), the
        // sidebar's indentation ladder, at a touch-sized height.
        contentPadding: EdgeInsets.only(left: indented ? 33 : 12, right: 12),
        minTileHeight: kTouchRow,
        visualDensity: VisualDensity.compact,
        onTap: () => context.go('/session/${session.id}'),
        leading: AgentAvatar(agent: session.agent),
        title: Row(
          children: [
            // Same dot as the desktop sidebar and pane header, so a status
            // reads identically everywhere (DESIGN.md). It also pulses for the
            // active states, which a static pill could not convey.
            if (!session.pending) ...[
              SessionStatusDot(status: session.status),
              const SizedBox(width: kSpace8),
            ],
            Expanded(
              child: Text(
                session.pending && session.title.trim().isEmpty
                    ? 'new session'
                    : session.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // The dot already carries running/idle/exited. A word is spent only
            // where the session is actually waiting on the user.
            if (session.pending)
              TagChip(label: 'draft', color: cs.outline)
            else if (_needsUser(session.status))
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

  /// Statuses that are a request for the user, not just progress — these keep
  /// their spelled-out chip next to the dot.
  static bool _needsUser(SessionStatus s) =>
      s == SessionStatus.awaitingInput ||
      s == SessionStatus.awaitingApproval ||
      s == SessionStatus.error;

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
