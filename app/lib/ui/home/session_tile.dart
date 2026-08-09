import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/session_status_dot.dart';
import '../ports/session_ports_glyph.dart';
import 'repo_chips.dart';
import '../../app/routes.dart';

/// A session inside a repo card, as an inset block (SPEC-19, direction C).
///
/// The block sits on a raised surface so a session reads as living *in* its
/// worktree rather than as a sibling of it — the old flat list left the two
/// ambiguous. Swipe to quit, tap to open.
class SessionTile extends ConsumerWidget {
  const SessionTile({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final wantsUser = _needsUser(session.status);
    return Semantics(
      // Screen readers can neither swipe nor long-press, so quit is published
      // as a custom action instead of being gesture-only.
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: 'Quit session'): () =>
            _confirmAndQuit(context, ref),
      },
      child: _body(context, ref, cs, wantsUser),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    ColorScheme cs,
    bool wantsUser,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRadius8),
      child: Dismissible(
        key: ValueKey('sess-${session.id}'),
        direction: DismissDirection.endToStart,
        background: ColoredBox(
          color: cs.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSpace16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
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
        ),
        confirmDismiss: (_) => _confirmAndQuit(context, ref),
        child: Material(
          // A session waiting on the user tints its own block, so the card's
          // accent bar has a visible cause once the row is expanded.
          color: wantsUser
              ? kStatusCaution.withValues(alpha: 0.10)
              : cs.surfaceContainer,
          child: InkWell(
            onTap: () => context.go(routeForSession(session.id)),
            // Swipe is not an accessible gesture: it is invisible to assistive
            // tech and awkward one-handed. Long-press reaches the same confirm
            // dialog, matching WorktreeRow, which already long-presses for its
            // actions.
            onLongPress: () => _confirmAndQuit(context, ref),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kTouchRow),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSpace10,
                  vertical: kSpace8,
                ),
                child: Row(
                  children: [
                    // Same dot as the desktop sidebar and pane header, so a
                    // status reads identically everywhere (DESIGN.md). It also
                    // pulses for the active states, which a pill cannot.
                    if (session.pending)
                      Icon(
                        PhosphorIconsLight.pencilSimple,
                        size: 10,
                        color: cs.outline,
                      )
                    else
                      SessionStatusDot(status: session.status),
                    const SizedBox(width: kSpace10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  session.pending &&
                                          session.title.trim().isEmpty
                                      ? 'new session'
                                      : session.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              // The dot already carries running/idle/exited. A
                              // word is spent only where the session is actually
                              // waiting on the user.
                              if (session.pending)
                                TagChip(label: 'draft', color: cs.outline)
                              else if (wantsUser)
                                SessionStatusChip(status: session.status),
                            ],
                          ),
                          const SizedBox(height: kSpace2),
                          if (_handoffCaption(session) case final caption?) ...[
                            Row(
                              children: [
                                Icon(
                                  PhosphorIconsLight.arrowBendUpRight,
                                  size: 12,
                                  color: cs.outline,
                                ),
                                const SizedBox(width: kSpace4),
                                Expanded(
                                  child: Text(
                                    caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: cs.outline),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: kSpace2),
                          ],
                          Text(
                            session.pending
                                ? 'Send a message to create a branch'
                                : session.lastPreview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: cs.outline),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: kSpace8),
                    // The session's own ports glyph (D14): quiet, renders only
                    // when a listener is attributed to this session.
                    SessionPortsGlyph(sessionId: session.id),
                    // The agent is the least urgent fact here, so it sits last
                    // and small — the status leads.
                    AgentAvatar(agent: session.agent, size: 22),
                  ],
                ),
              ),
            ),
          ),
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

  /// SPEC-46 D10: a session with lineage was handed off from another session,
  /// so the row explains itself rather than appearing as a mystery title. The
  /// caption renders whenever [Session.parentId] is set and never depends on
  /// resolving the parent — which may be archived or simply not cached — and
  /// carries the outgoing agent's reason when one was written.
  static String? _handoffCaption(Session session) {
    if (session.parentId == null) return null;
    final reason = session.handoffReason?.trim();
    // Lineage with no reason is not necessarily a handoff: `makit fork` (U4)
    // branches a conversation natively and deliberately writes no reason, because
    // a fork is not a handoff (D6). "Continued from" is true of both; claiming a
    // handoff would mislabel every forked session in the one place the user meets
    // it.
    return reason == null || reason.isEmpty
        ? 'Continued from another session'
        : 'Handed off — $reason';
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
