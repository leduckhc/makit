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
import '../../ui/session/chat_transcript.dart';
import '../../ui/session/tool_call_detail_screen.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'composer_focus.dart';
import 'panes/pane_tree_controller.dart';
import 'selected_session.dart';
import 'sidebar_layout.dart';
import '../../ui/composer/composer_selectors.dart';

/// The right-hand pane of the desktop two-pane chat: transcript + docked
/// composer for [selectedSessionProvider].
///
/// Renders each item through the shared [chatItemWidget] and reuses the shared
/// [Composer] + [handleClientCommand] send path so desktop and mobile render
/// and behave identically. Unlike the mobile [SessionScreen] (a full-screen
/// route with floating glass bars), this is a docked pane: a plain scroll
/// transcript with the composer pinned at the bottom — the shape desktop chat
/// apps use.
class DesktopChatPane extends ConsumerStatefulWidget {
  /// Creates the desktop chat pane. When [sessionId] is null the pane falls
  /// back to the globally [selectedSessionProvider] (single-pane behaviour).
  const DesktopChatPane({
    super.key,
    this.sessionId,
    this.showHeader = true,
    this.trackGlobalSelection = true,
    this.composerFocusId,
  });

  /// The session this pane hosts, or null to defer to the global selection.
  final String? sessionId;

  /// Whether to render the in-pane session header (title + actions menu). The
  /// split pane tree shows a single merged header in its tab strip, so it
  /// passes false to avoid a second stacked bar.
  final bool showHeader;

  /// Whether a null [sessionId] should fall back to the global
  /// [selectedSessionProvider]. The split pane tree resolves the fallback
  /// itself (only the active pane tracks the global selection), so it passes
  /// false to keep inactive empty panes truly empty.
  final bool trackGlobalSelection;

  /// The hosting pane's leaf id, used to key this pane's composer
  /// [FocusNode] via [desktopComposerFocusProvider] so each split pane owns a
  /// distinct node (and the "focus composer" shortcut can target the active
  /// leaf). Null (standalone use) lets the [Composer] own its own node.
  final String? composerFocusId;

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
    final sessionId =
        widget.sessionId ??
        (widget.trackGlobalSelection
            ? ref.watch(selectedSessionProvider)
            : null);
    if (sessionId == null) {
      // A sessionless worktree selected in the sidebar → harness picker to
      // start a session in that existing worktree. Only the active pane tracks
      // this global draft; inactive split panes stay empty.
      final worktree = widget.trackGlobalSelection
          ? ref.watch(selectedWorktreeProvider)
          : null;
      if (worktree != null) {
        return _WorktreeStartView(
          key: ValueKey(worktree.path),
          worktree: worktree,
        );
      }
      // No session yet, but the pane still owns the unfold affordance when the
      // sidebar is hidden — surface a minimal top strip above the placeholder.
      return Column(
        children: [
          if (widget.showHeader) const _UnfoldStrip(),
          const Expanded(child: _NoSelection()),
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
        if (widget.showHeader)
          _PaneHeader(session: session, fallbackId: sessionId),
        Expanded(
          child: (session?.pending == true && session?.branch == null)
              ? _HarnessPicker(session: session!)
              : items.isEmpty
              ? const _EmptyTranscript()
              // The ListView fills the full pane width so the mouse wheel
              // scrolls the transcript anywhere in the pane, not just over the
              // centered content column. Each row keeps the readable-width cap
              // via its own centered ConstrainedBox, so the layout is unchanged.
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: items.length + (running ? 1 : 0),
                  itemBuilder: (context, i) {
                    final Widget child = i >= items.length
                        ? const WorkingIndicator(compact: true)
                        : chatItemWidget(
                            items[i],
                            onOpenTool: _openToolDetail,
                            compact: true,
                          );
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: kReadableContentMaxWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: child,
                        ),
                      ),
                    );
                  },
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
                focusNode: widget.composerFocusId == null
                    ? null
                    : ref.watch(
                        desktopComposerFocusProvider(widget.composerFocusId!),
                      ),
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
    final title = sessionPaneTitle(session, fallbackId);
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
          SessionActionsMenu(sessionId: fallbackId),
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
}

/// The session name shown in a pane header: title, else agent name, else id.
String sessionPaneTitle(Session? session, String fallbackId) {
  if (session != null && session.title.trim().isNotEmpty) {
    return session.title.trim();
  }
  if (session != null && session.agent.trim().isNotEmpty) return session.agent;
  return fallbackId;
}

/// The session-level overflow menu (Rename / Quit) for a pane header. Model and
/// thinking-effort live inline in the composer footer, so they are not repeated
/// here. Shared by the docked [_PaneHeader] and the split pane tree's tab strip.
class SessionActionsMenu extends ConsumerWidget {
  /// Creates the actions menu acting on [sessionId].
  const SessionActionsMenu({super.key, required this.sessionId});

  /// The session the menu's actions target.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              sessionId: sessionId,
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
    // Capture notifiers before the async gap so the model cleanup still runs if
    // this menu's widget is disposed (e.g. its pane closed) while killing.
    final store = ref.read(storeControllerProvider.notifier);
    final panes = ref.read(paneTreeControllerProvider.notifier);
    final selection = ref.read(selectedSessionProvider.notifier);
    try {
      await store.killSession(sessionId);
      // Drop any panes bound to the now-dead session back to their empty state
      // and clear the selection — regardless of whether this widget survived.
      panes.unbindSession(sessionId);
      if (selection.state == sessionId) {
        selection.state = null;
      }
    } catch (e) {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
      }
    }
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
