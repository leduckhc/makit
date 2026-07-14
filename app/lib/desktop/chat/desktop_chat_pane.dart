import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/composer/composer.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/session/chat_message.dart';
import '../../ui/session/tool_call_card.dart';
import '../../ui/session/tool_call_detail_screen.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'selected_session.dart';
import 'sidebar_layout.dart';

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
    if (sessionId == null) return const _NoSelection();

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
          child: items.isEmpty
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

class _PaneHeader extends ConsumerWidget {
  const _PaneHeader({
    required this.session,
    required this.fallbackId,
    this.branch,
  });
  final Session? session;
  final String fallbackId;
  final String? branch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = (session?.title.trim().isNotEmpty ?? false)
        ? session!.title.trim()
        : fallbackId;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          if (session != null) ...[
            AgentAvatar(agent: session!.agent, size: 28),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (session != null)
                  Text(
                    session!.agent,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
          if (branch != null) ...[
            const SizedBox(width: 8),
            BranchChip(branch: branch!),
          ],
          if (session != null && session!.pending) ...[
            const SizedBox(width: 8),
            const TagChip(label: 'draft', color: Colors.amber),
          ] else if (session != null &&
              session!.status != SessionStatus.idle) ...[
            const SizedBox(width: 8),
            SessionStatusChip(status: session!.status),
          ],
          const SizedBox(width: 4),
          _actionsMenu(context, ref),
        ],
      ),
    );
  }

  /// Session-level overflow menu (Rename / Model / Thinking / Quit). Mirrors
  /// the mobile [SessionScreen] top-bar menu so both platforms expose the same
  /// actions.
  Widget _actionsMenu(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) {
        switch (value) {
          case 'rename':
            handleClientCommand(
              '/name',
              context: context,
              ref: ref,
              sessionId: fallbackId,
            );
          case 'model':
            handleClientCommand(
              '/model',
              context: context,
              ref: ref,
              sessionId: fallbackId,
            );
          case 'thinking':
            handleClientCommand(
              '/thinking',
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
            leading: Icon(Icons.drive_file_rename_outline),
            title: Text('Rename session'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'model',
          child: ListTile(
            leading: Icon(Icons.smart_toy_outlined),
            title: Text('Model'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'thinking',
          child: ListTile(
            leading: Icon(Icons.psychology_outlined),
            title: Text('Thinking'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'quit',
          child: ListTile(
            leading: Icon(Icons.power_settings_new),
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
              Icons.psychology_outlined,
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

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 40, color: cs.outline),
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
