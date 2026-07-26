import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;

/// Harness picker shown in the main content while a session is still a draft
/// (no worktree yet). Selecting a card sets the harness the worktree will
/// start with; the user then sends a message to create the worktree.
/// (SPEC-19, moved from desktop_chat_pane.)
class HarnessPicker extends ConsumerWidget {
  const HarnessPicker({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final agentsAsync = ref.watch(agentsProvider);
    final selected = session.pendingAgent ?? session.agent;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kReadableContentMaxWidth),
        child: agentsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text(
              'Could not load harnesses: $e',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          data: (agents) {
            if (agents.isEmpty) {
              return Center(
                child: Text(
                  'Using the host default harness.',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(kSpace24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Choose a harness', style: theme.textTheme.titleMedium),
                  const SizedBox(height: kSpace4),
                  Text(
                    'Then send a message to create the worktree.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: kSpace16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final a in agents)
                        HarnessCard(
                          agent: a,
                          selected: a.id == selected,
                          onTap: a.available
                              ? () => ref
                                    .read(storeControllerProvider.notifier)
                                    .setSessionAgent(session.id, a.id)
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A selectable harness card (icon, label, transport). Selected cards get an
/// accent ring + check; unavailable agents are dimmed and non-tappable. Reused
/// by the draft [HarnessPicker] and the New-session dialog's harness grid.
class HarnessCard extends StatelessWidget {
  const HarnessCard({
    super.key,
    required this.agent,
    required this.selected,
    this.onTap,
  });

  final AgentDescriptor agent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SizedBox(
      width: 168,
      child: Card(
        margin: EdgeInsets.zero,
        color: selected ? cs.primaryContainer : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius12),
          side: BorderSide(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      PhosphorIconsLight.robot,
                      size: 20,
                      color: agent.available ? cs.onSurface : cs.outline,
                    ),
                    const Spacer(),
                    if (selected)
                      Icon(
                        PhosphorIconsFill.checkCircle,
                        size: 18,
                        color: cs.primary,
                      ),
                  ],
                ),
                const SizedBox(height: kSpace8),
                Text(
                  agent.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: kSpace2),
                Text(
                  agent.available ? agent.transport : 'unavailable',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
