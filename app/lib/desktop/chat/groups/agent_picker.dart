/// SPEC-30 — the agent picker: the board half of decision 13 and one of the
/// four add paths of decision 14. Every session, grouped by `repo ·
/// branch`, with the board's current members pre-ticked; ticking a row pins or
/// unpins it, and a leading `New session…` row opens the New-worktree dialog.
///
/// A board is a **view, not a place**, so the picker never asks "where does it
/// run?" — that question only exists for the `New session…` row, which is why
/// it (and only it) opens the dialog.
library;

import 'package:flutter/material.dart' hide Tab;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../store/models.dart';
import '../../../store/store.dart';
import '../new_worktree_dialog.dart';
import '../panes/split_node.dart';
import '../panes/workspace_controller.dart';
import '../session_status_dot.dart';
import 'group.dart';
import 'group_providers.dart';
import 'groups_controller.dart';

/// Opens the agent picker for the active board as a modal dialog. A no-op when
/// the active group is not a board (a worktree group has no curated list to
/// edit — its `+` starts an agent in place instead, decision 13).
Future<void> showAgentPicker(BuildContext context, WidgetRef ref) {
  if (ref.read(activeGroupProvider).kind != GroupKind.board) {
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    builder: (_) => const Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(width: 430, child: AgentPicker()),
    ),
  );
}

/// The picker body: a header, the `New session…` row, the grouped session list
/// with checkboxes, and a footer counting the board's live members. Reused by
/// [showAgentPicker] and (potentially) an inline trailing region.
class AgentPicker extends ConsumerWidget {
  /// Creates the picker for the active board.
  const AgentPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final group = ref.watch(activeGroupProvider);
    // Guard: only a board has a curated list. Worktree groups never reach here
    // through [showAgentPicker], but a direct embed must not crash.
    if (group.kind != GroupKind.board) return const SizedBox.shrink();
    final members = ref.watch(groupMembersProvider(group.id)).toSet();
    final sessions = ref.watch(sessionsProvider).sessions;
    final grouped = _groupByRepoBranch(ref, sessions);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace16,
            kSpace12,
            kSpace16,
            kSpace10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add agents to “${group.label}”',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: kSpace2),
              Text(
                'A board is a view, not a place — anything running anywhere '
                'can join it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const _NewSessionRow(),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: kSpace6),
            children: [
              for (final section in grouped) ...[
                _SectionHeader(label: section.label),
                for (final session in section.sessions)
                  _PickerRow(
                    session: session,
                    checked: members.contains(session.id),
                    onToggle: () => _toggle(ref, group, session, members),
                  ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace16,
            kSpace10,
            kSpace12,
            kSpace10,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${members.length} on this board · drag from the sidebar '
                  'works too',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: kSpace10),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Ticks or unticks [session]: an unchecked row pins it (decision 14), a
  /// checked one unpins it (the agent keeps running). Both are explicit
  /// gestures, but since the picker only opens on a board neither can trigger
  /// decision 4's conversion.
  void _toggle(
    WidgetRef ref,
    Group group,
    Session session,
    Set<String> members,
  ) {
    final controller = ref.read(groupsControllerProvider.notifier);
    if (members.contains(session.id)) {
      controller.removeMember(group.id, session.id);
    } else {
      controller.addMember(group.id, session.id, location: locationOf(session));
    }
  }

  /// Groups [sessions] by `repo · branch`. Keyed by `(projectId, branch)` so
  /// two repos that share a display name stay in separate sections; the repo
  /// name (resolved through [reposProvider], falling back to the raw id) is
  /// only the section's shown label.
  List<_Section> _groupByRepoBranch(WidgetRef ref, List<Session> sessions) {
    final repos = ref.watch(reposProvider);
    // Preserve first-seen order; key by (projectId, branch) so two repos that
    // share a display name don't collapse into one section.
    final order = <String>[];
    final byKey = <String, List<Session>>{};
    final labels = <String, String>{};
    for (final s in sessions) {
      final repoName = repos.byId(s.projectId)?.name ?? s.projectId;
      final branch = s.branch ?? 'no branch';
      final key = '${s.projectId}\u0000$branch';
      if (byKey.putIfAbsent(key, () => []).isEmpty) {
        order.add(key);
        labels[key] = '$repoName · $branch';
      }
      byKey[key]!.add(s);
    }
    return [
      for (final key in order)
        _Section(label: labels[key]!, sessions: byKey[key]!),
    ];
  }
}

/// A `repo · branch` section of the picker list.
@immutable
class _Section {
  const _Section({required this.label, required this.sessions});
  final String label;
  final List<Session> sessions;
}

/// The leading `New session…` row (decision 13). A board has no branch, so it
/// asks where to run: this opens the New-worktree dialog, which creates the
/// worktree and lands the user on its Choose-a-harness starter.
/// Creates a worktree and opens it as a **tab on this board**, rather than
/// activating its own worktree group.
///
/// Activating would switch the canvas away from the board the user is editing —
/// and collapse this very picker, since it reads the active group — while pinning
/// nothing. A board cannot hold a *worktree*, only sessions, so what lands here
/// is an empty tab carrying the new worktree as its hint (decision 21): the
/// Choose-a-harness pane, in place, exactly as `⌘T` on a board does.
Future<void> _createWorktreeForBoard(
  BuildContext context,
  WidgetRef ref,
) async {
  final worktree = await showNewWorktreeDialog(
    context,
    ref,
    activateGroup: false,
  );
  if (worktree == null || !context.mounted) return;
  final workspace = ref.read(workspaceControllerProvider.notifier);
  workspace.openTab(
    ref.read(workspaceControllerProvider).activeSplitId,
    Tab(id: nextNodeId(SplitNodeKind.tab), worktree: worktree),
  );
}

class _NewSessionRow extends ConsumerWidget {
  const _NewSessionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: () => _createWorktreeForBoard(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace16,
          vertical: kSpace10,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: cs.outlineVariant)),
        ),
        child: Row(
          children: [
            const Icon(PhosphorIconsLight.plus, size: 16, color: kBoardSwatch),
            const SizedBox(width: kSpace10),
            Expanded(
              child: Text('New session…', style: theme.textTheme.bodyMedium),
            ),
            Text(
              'a board has no branch,\nso it asks where to run',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A `repo · branch` header above its sessions.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace16, kSpace8, kSpace16, kSpace4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelXs?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One session row: a checkbox (ticked when a member), a status dot, the title,
/// and the harness name.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.session,
    required this.checked,
    required this.onToggle,
  });

  final Session session;
  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = session.title.trim().isNotEmpty
        ? session.title.trim()
        : (session.agent.trim().isNotEmpty ? session.agent : session.id);
    return Semantics(
      checked: checked,
      label: title,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace16,
            vertical: kSpace6,
          ),
          child: Row(
            children: [
              _CheckBox(checked: checked),
              const SizedBox(width: kSpace8),
              if (session.status != SessionStatus.idle) ...[
                SessionStatusDot(status: session.status),
                const SizedBox(width: kSpace6),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: kSpace8),
              Text(
                session.agent,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The picker's ticked/unticked box, violet when a member (matching the board
/// swatch).
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? kBoardSwatch : Colors.transparent,
        border: Border.all(
          color: checked ? kBoardSwatch : Theme.of(context).colorScheme.outline,
          width: 1.4,
        ),
        borderRadius: BorderRadius.circular(kRadius6),
      ),
      child: checked
          ? const Icon(PhosphorIconsBold.check, size: 11, color: Colors.black)
          : null,
    );
  }
}
