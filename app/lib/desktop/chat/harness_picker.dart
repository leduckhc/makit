import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/composer.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'composer_focus.dart';
import 'composer_draft.dart';
import 'panes/pane_header.dart';
import 'panes/pane_tree_controller.dart';
import 'pr_bar.dart';
import 'selected_session.dart';

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
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Choose a harness', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Then send a message to create the worktree.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final a in agents)
                        _HarnessCard(
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

class _HarnessCard extends StatelessWidget {
  const _HarnessCard({required this.agent, required this.selected, this.onTap});

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
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
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
                const SizedBox(height: 8),
                Text(
                  agent.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
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

/// Shown when a sessionless worktree is selected in the sidebar: pick a
/// harness, then send a message to start a session IN that existing worktree.
/// The session is spawned only on first send (no orphan drafts).
/// (SPEC-19, moved from desktop_chat_pane.)
class WorktreeStartView extends ConsumerStatefulWidget {
  const WorktreeStartView({
    super.key,
    required this.worktree,
    this.composerFocusId,
  });
  final SelectedWorktree worktree;

  /// The hosting pane's leaf id, used to key this view's composer [FocusNode]
  /// via [desktopComposerFocusProvider] so each split pane owns a distinct node
  /// (and the "focus composer" shortcut can target the active leaf). Null
  /// (standalone use) lets the [Composer] own its own node.
  final String? composerFocusId;

  @override
  ConsumerState<WorktreeStartView> createState() => _WorktreeStartViewState();
}

class _WorktreeStartViewState extends ConsumerState<WorktreeStartView> {
  String? _chosenAgent;
  bool _starting = false;

  String? _defaultAgent(List<AgentDescriptor> agents) {
    for (final a in agents) {
      if (a.available) return a.id;
    }
    return agents.isEmpty ? null : agents.first.id;
  }

  Future<void> _start(String text) async {
    if (_starting) return;
    final agents = ref.read(agentsProvider).value ?? const <AgentDescriptor>[];
    final agent = _chosenAgent ?? _defaultAgent(agents);
    final wt = widget.worktree;
    setState(() => _starting = true);
    final store = ref.read(storeControllerProvider.notifier);
    try {
      final sid = await store.spawnSession(
        wt.projectId,
        agent: agent,
        worktreePath: wt.path,
        branch: wt.branch,
      );
      // The widget may have unmounted while spawnSession was in flight; bail
      // before touching providers through a potentially disposed ref.
      if (!mounted) return;
      // Bind the new session into the REAL worktree tree the user is already
      // looking at. We can't route through selectSessionExclusive here: a
      // not-yet-started draft has no worktreePath, so that helper would misfile
      // it into a virtual `draft:<id>` tree — even though this session belongs
      // to an existing worktree on disk. That misfiling bounced the pane onto a
      // draft tree and, once the session materialized, back to this empty start
      // view, dropping the just-sent turn from view.
      ref.read(selectedSessionProvider.notifier).state = sid;
      ref.read(paneTreeControllerProvider.notifier).bindActiveSession(sid, wt);
      store.appendOptimisticMessage(sid, text);
      store.sendMessage(sid, text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start session: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final agentsAsync = ref.watch(agentsProvider);
    return Column(
      children: [
        const UnfoldStrip(),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: kReadableContentMaxWidth,
              ),
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
                        'Using the host default harness. Send a message to '
                        'start.',
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    );
                  }
                  final selected = _chosenAgent ?? _defaultAgent(agents);
                  // The worktree already exists on disk, so it may head an open
                  // PR (created in makit, by another agent, or on GitHub). Show
                  // its status here too so the state is visible before a session
                  // even starts. Reads the poller-refreshed repos snapshot, so
                  // it updates in place.
                  final pr = ref
                      .watch(reposProvider)
                      .prForWorktreePath(widget.worktree.path);
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select your harness',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Then send a message to start a session in this '
                          'worktree.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        if (pr != null) ...[
                          const SizedBox(height: 12),
                          PrStatusPill(pr: pr),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final a in agents)
                              _HarnessCard(
                                agent: a,
                                selected: a.id == selected,
                                onTap: a.available
                                    ? () => setState(() => _chosenAgent = a.id)
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
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kReadableContentMaxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Composer(
                onSend: _start,
                running: _starting,
                alwaysExpanded: true,
                // A not-yet-started session has no id, so scope the draft to
                // the worktree; it survives switching away and back.
                initialText: ref.read(
                  composerDraftsProvider,
                )['wt:${widget.worktree.path}'],
                onDraftChanged: (text) => ref
                    .read(composerDraftsProvider.notifier)
                    .set('wt:${widget.worktree.path}', text),
                focusNode: widget.composerFocusId == null
                    ? null
                    : ref.watch(
                        desktopComposerFocusProvider(widget.composerFocusId!),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
