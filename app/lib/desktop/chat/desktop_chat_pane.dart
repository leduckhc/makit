import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/composer/composer.dart';
import '../../ui/session/chat_message.dart';
import '../../ui/session/tool_call_card.dart';
import '../../ui/session/tool_call_detail_screen.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'composer_focus.dart';
import 'selected_session.dart';
import 'sidebar_layout.dart';
import '../../ui/composer/composer_selectors.dart';

/// The right-hand pane of the desktop two-pane chat: transcript + docked
/// composer for [selectedSessionProvider].
///
/// Reuses the mobile chat item widgets ([ChatBubble], [AgentMessage],
/// [ToolCallCard]) and the shared [Composer] + [handleClientCommand] send path
/// so desktop and mobile render and behave identically. Unlike the mobile
/// [SessionScreen] (a full-screen route with floating glass bars), this is a
/// docked pane: a plain scroll transcript with the composer pinned at the
/// bottom — the shape desktop chat apps use.
class DesktopChatPane extends ConsumerStatefulWidget {
  /// Creates the desktop chat pane.
  const DesktopChatPane({super.key});

  @override
  ConsumerState<DesktopChatPane> createState() => _DesktopChatPaneState();
}

class _DesktopChatPaneState extends ConsumerState<DesktopChatPane> {
  final _scroll = ScrollController();
  String? _subscribed;
  int _lastSeq = 0;

  void _ensureSubscribed(String? sessionId) {
    if (sessionId == null || sessionId == _subscribed) return;
    _subscribed = sessionId;
    _lastSeq = 0;
    ref.read(storeControllerProvider.notifier).subscribeSession(sessionId);
  }

  Future<void> _handleSend(String sessionId, String text) async {
    if (text.startsWith('/')) {
      final handled = await handleClientCommand(
        text,
        context: context,
        ref: ref,
        sessionId: sessionId,
      );
      if (handled) return;
    }
    final store = ref.read(storeControllerProvider.notifier);
    store.appendOptimisticMessage(sessionId, text);
    store.sendMessage(sessionId, text);
  }

  void _cancelTurn(String sessionId) => handleClientCommand(
    '/cancel',
    context: context,
    ref: ref,
    sessionId: sessionId,
  );

  /// Push the fullscreen tool-call drilldown, matching the mobile chat where
  /// tapping a tool card opens its args / output / diff view.
  void _openToolDetail(ToolCallItem item) {
    final sessionId = _subscribed;
    if (sessionId == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ToolCallDetailScreen(sessionId: sessionId, callId: item.callId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(selectedSessionProvider);
    if (sessionId == null) {
      // A sessionless worktree selected in the sidebar → harness picker to
      // start a session in that existing worktree.
      final worktree = ref.watch(selectedWorktreeProvider);
      if (worktree != null) {
        return _WorktreeStartView(
          key: ValueKey(worktree.path),
          worktree: worktree,
        );
      }
      // No session yet, but the pane still owns the unfold affordance when the
      // sidebar is hidden — surface a minimal top strip above the placeholder.
      return const Column(
        children: [
          _UnfoldStrip(),
          Expanded(child: _NoSelection()),
        ],
      );
    }

    _ensureSubscribed(sessionId);

    // Surface transient action errors (compact/model/etc.) as snackbars,
    // matching the mobile session screen.
    ref.listen<ActionError?>(sessionActionErrorProvider(sessionId), (
      prev,
      next,
    ) {
      if (next == null || prev?.seq == next.seq) return;
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${next.action} failed: ${next.reason}')),
      );
    });

    final session = ref.watch(sessionsProvider).byId(sessionId);
    final items = ref.watch(chatItemsProvider(sessionId));

    // Keep the transcript pinned to the newest message as items stream in.
    if (items.isNotEmpty && items.last.seq != _lastSeq) {
      _lastSeq = items.last.seq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

    final running = session?.status == SessionStatus.running;

    return Column(
      children: [
        _PaneHeader(session: session, fallbackId: sessionId),
        Expanded(
          child: (session?.pending == true && session?.branch == null)
              ? _HarnessPicker(session: session!)
              : items.isEmpty
              ? const _EmptyTranscript()
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: kReadableContentMaxWidth,
                    ),
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      itemCount: items.length + (running ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= items.length) return const _WorkingIndicator();
                        return _buildItem(items[i]);
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
                commands: ref.watch(commandsProvider(sessionId)),
                onSend: (text) => _handleSend(sessionId, text),
                onCancel: () => _cancelTurn(sessionId),
                running: running,
                alwaysExpanded: true,
                footerActions: [
                  ComposerModelSelector(sessionId: sessionId),
                  ComposerThinkingSelector(sessionId: sessionId),
                  ComposerModeSelector(sessionId: sessionId),
                ],
                focusNode: ref.watch(desktopComposerFocusProvider),
                sendChord: ref
                    .watch(keymapProvider)
                    .chordFor(ShortcutAction.sendMessage),
                newlineChord: ref
                    .watch(keymapProvider)
                    .chordFor(ShortcutAction.composerNewline),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(ChatItem item) => switch (item) {
    UserMessageItem() => ChatBubble.user(text: item.text, ts: item.ts),
    AgentMessageItem() => AgentMessage(text: item.text, ts: item.ts),
    ThinkingItem() => _ThinkingLine(text: item.text),
    ToolCallItem() => ToolCallCard(
      item: item,
      onTap: () => _openToolDetail(item),
    ),
    ErrorItem() => _ErrorBanner(message: item.message),
  };

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

/// The pane header's leading control when the sidebar is hidden: restores it.
/// Styled to match the sidebar's fold button (see `desktop_sidebar.dart`).
IconButton _showSidebarButton(WidgetRef ref) => IconButton(
  iconSize: 19,
  visualDensity: VisualDensity.compact,
  padding: EdgeInsets.zero,
  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
  tooltip: 'Show sidebar',
  icon: const Icon(Symbols.thumbnail_bar, weight: 300),
  onPressed: () => ref.read(sidebarCollapsedProvider.notifier).state = false,
);

class _PaneHeader extends ConsumerWidget {
  const _PaneHeader({required this.session, required this.fallbackId});
  final Session? session;
  final String fallbackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    // Same fallback order as the sidebar tiles (SPEC-12 decision 8):
    // title → agent name → raw session id.
    final title = (session?.title.trim().isNotEmpty ?? false)
        ? session!.title.trim()
        : ((session?.agent.trim().isNotEmpty ?? false)
              ? session!.agent
              : fallbackId);
    final theme = Theme.of(context);
    final content = Padding(
      // When collapsed the pane starts at window x=0, so inset the leading
      // control past the traffic lights and align it to the traffic-light row;
      // otherwise use the normal gutter.
      padding: EdgeInsets.fromLTRB(
        collapsed ? kTrafficLightInset : 16,
        7,
        16,
        12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (collapsed) ...[_showSidebarButton(ref), const SizedBox(width: 8)],
          if (session != null) ...[
            // Match the sidebar-fold icon scale so the fold icon,
            // title, and actions menu all sit on the traffic-light row.
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 4),
          _actionsMenu(context, ref),
        ],
      ),
    );
    // Keep the window draggable where the sidebar's drag strip used to be.
    // DragToMoveArea sits UNDER the content (Stack sibling, like the sidebar's
    // _Header) rather than wrapping it: its double-tap recognizer would
    // otherwise delay every button tap by the gesture-disambiguation window.
    if (!collapsed) return content;
    return Stack(
      children: [
        const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
        content,
      ],
    );
  }

  /// Session-level overflow menu (Rename / Quit). Model and thinking-effort
  /// live inline in the composer footer now, so they are not repeated here.
  Widget _actionsMenu(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      padding: EdgeInsets.zero,
      // Use `child` (not `icon`): `icon` builds an internal IconButton that
      // enforces a 48px min tap target, which inflates the header row and
      // pushes the centered row content below the traffic-light line.
      child: const Padding(
        padding: EdgeInsets.all(3),
        child: Icon(Symbols.more_horiz, size: 18, weight: 200),
      ),
      onSelected: (value) {
        switch (value) {
          case 'rename':
            handleClientCommand(
              '/name',
              context: context,
              ref: ref,
              sessionId: fallbackId,
            );
          case 'quit':
            _confirmQuit(context, ref);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Symbols.drive_file_rename_outline, weight: 200),
            title: Text('Rename session'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'quit',
          child: ListTile(
            leading: Icon(Symbols.power_settings_new, weight: 200),
            title: Text('Quit session'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmQuit(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit session?'),
        content: const Text(
          'This stops the agent process and removes the session. '
          'The transcript stays on disk and can be re-attached later.',
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
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(storeControllerProvider.notifier).killSession(fallbackId);
      if (!context.mounted) return;
      // Clear the selection so the pane returns to its empty state (desktop's
      // analog of the mobile screen's pop-to-home after quit).
      if (ref.read(selectedSessionProvider) == fallbackId) {
        ref.read(selectedSessionProvider.notifier).state = null;
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
    }
  }
}

class _ThinkingLine extends StatefulWidget {
  const _ThinkingLine({required this.text});
  final String text;

  @override
  State<_ThinkingLine> createState() => _ThinkingLineState();
}

/// Reasoning/thinking trace. Folded to a single greyed one-liner with an
/// ellipsis; a single click toggles between the full text and the one-liner,
/// matching the mobile chat's `_ThinkingCard`.
class _ThinkingLineState extends State<_ThinkingLine> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      color: cs.onSurfaceVariant.withValues(alpha: 0.65),
      fontSize: 13,
      fontStyle: FontStyle.italic,
      height: 1.3,
    );
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Symbols.psychology,
              weight: 200,
              size: 15,
              color: cs.onSurfaceVariant.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.text.trim(),
                style: style,
                maxLines: _expanded ? null : 1,
                overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: TextStyle(color: cs.onErrorContainer)),
    );
  }
}

class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('working…'),
        ],
      ),
    );
  }
}

/// Harness picker shown in the main content while a session is still a draft
/// (no worktree yet). Selecting a card sets the harness the worktree will
/// start with; the user then sends a message to create the worktree.
class _HarnessPicker extends ConsumerWidget {
  const _HarnessPicker({required this.session});
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
                      Symbols.smart_toy,
                      weight: 200,
                      size: 20,
                      color: agent.available ? cs.onSurface : cs.outline,
                    ),
                    const Spacer(),
                    if (selected)
                      Icon(
                        Symbols.check_circle,
                        weight: 300,
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
class _WorktreeStartView extends ConsumerStatefulWidget {
  const _WorktreeStartView({super.key, required this.worktree});
  final SelectedWorktree worktree;

  @override
  ConsumerState<_WorktreeStartView> createState() => _WorktreeStartViewState();
}

class _WorktreeStartViewState extends ConsumerState<_WorktreeStartView> {
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
      selectSessionExclusive(ref, sid);
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
    final wt = widget.worktree;
    return Column(
      children: [
        const _UnfoldStrip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Icon(
                Symbols.fork_right,
                size: 18,
                weight: 200,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  wt.branch ?? wt.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
        ),
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
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choose a harness',
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
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Send a message to start.',
        style: TextStyle(color: cs.outline),
      ),
    );
  }
}

/// A slim top strip shown above the pane's empty state when the sidebar is
/// hidden, so the unfold control stays reachable with no session selected.
/// Renders nothing while the sidebar is visible. Mirrors the sidebar's
/// `_Header` drag-strip + overlaid fold button.
class _UnfoldStrip extends ConsumerWidget {
  const _UnfoldStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sidebarCollapsedProvider)) return const SizedBox.shrink();
    return SizedBox(
      height: kTitleBarStripHeight,
      width: double.infinity,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          Positioned(
            left: kTrafficLightInset,
            top: 7,
            child: _showSidebarButton(ref),
          ),
        ],
      ),
    );
  }
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.forum, size: 40, weight: 200, color: cs.outline),
          const SizedBox(height: 12),
          Text(
            'Select or start a session',
            style: TextStyle(color: cs.outline),
          ),
        ],
      ),
    );
  }
}
