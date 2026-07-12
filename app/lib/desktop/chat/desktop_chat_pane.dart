import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/composer/composer.dart';
import '../../ui/session/chat_message.dart';
import '../../ui/session/tool_call_card.dart';
import 'selected_session.dart';

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

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(selectedSessionProvider);
    if (sessionId == null) return const _NoSelection();

    _ensureSubscribed(sessionId);

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
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const _EmptyTranscript()
              : ListView.builder(
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
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Composer(
            commands: ref.watch(commandsProvider(sessionId)),
            onSend: (text) => _handleSend(sessionId, text),
            onCancel: () => _cancelTurn(sessionId),
            running: running,
          ),
        ),
      ],
    );
  }

  Widget _buildItem(ChatItem item) => switch (item) {
        UserMessageItem() => ChatBubble.user(text: item.text, ts: item.ts),
        AgentMessageItem() => AgentMessage(text: item.text, ts: item.ts),
        ThinkingItem() => _ThinkingLine(text: item.text),
        ToolCallItem() => ToolCallCard(item: item, onTap: () {}),
        ErrorItem() => _ErrorBanner(message: item.message),
      };

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.session, required this.fallbackId});
  final Session? session;
  final String fallbackId;

  @override
  Widget build(BuildContext context) {
    final title = (session?.title.trim().isNotEmpty ?? false)
        ? session!.title.trim()
        : fallbackId;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (session != null)
                  Text(
                    session!.agent,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinkingLine extends StatelessWidget {
  const _ThinkingLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.outline,
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
