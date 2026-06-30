import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../composer/client_commands.dart';
import '../composer/composer.dart';
import 'chat_message.dart';
import 'tool_call_card.dart';
import '../widgets/connection_chip.dart';

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  final _scroll = ScrollController();
  int _lastSeq = 0;

  @override
  void initState() {
    super.initState();
    // Subscribe so the fake server replays this session's events.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(storeControllerProvider.notifier)
          .subscribeSession(widget.sessionId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionsProvider).byId(widget.sessionId);
    final items = ref.watch(chatItemsProvider(widget.sessionId));
    debugPrint('[pino] SessionScreen.build sid=${widget.sessionId.substring(0, 8)} items=${items.length}');

    if (items.isNotEmpty && items.last.seq != _lastSeq) {
      _lastSeq = items.last.seq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session?.title ?? widget.sessionId,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${session?.agent ?? '?'} · ${_statusLabel(session?.status)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        actions: const [ConnectionChip()],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                return switch (item) {
                  UserMessageItem() => ChatBubble.user(text: item.text),
                  AgentMessageItem() => ChatBubble.agent(text: item.text),
                  ToolCallItem() => ToolCallCard(
                    item: item,
                    onTap: () => context.go(
                      '/session/${widget.sessionId}/tool/${item.callId}',
                    ),
                  ),
                  ApprovalRequestItem() => _ApprovalChip(
                    sessionId: widget.sessionId,
                    item: item,
                  ),
                  ErrorItem() => _ErrorBanner(message: item.message),
                };
              },
            ),
          ),
          Composer(
            commands: ref.watch(commandsProvider(widget.sessionId)),
            steering: session?.status == SessionStatus.running,
            onSend: (text) => _handleSend(text),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSend(String text) async {
    if (text.startsWith('/')) {
      final handled = await handleClientCommand(
        text,
        context: context,
        ref: ref,
        sessionId: widget.sessionId,
      );
      if (handled) return;
    }
    // Optimistic UI: show the message immediately so it doesn't look hung.
    // The server will echo it back; if there's a conflict we reconcile by seq.
    ref
        .read(storeControllerProvider.notifier)
        .appendOptimisticMessage(widget.sessionId, text);
    // Send to server (may arrive out of order w.r.t. the local append, but seq resolves it).
    ref
        .read(storeControllerProvider.notifier)
        .sendMessage(widget.sessionId, text);
  }

  String _statusLabel(SessionStatus? s) => switch (s) {
    SessionStatus.idle => 'idle',
    SessionStatus.running => 'running',
    SessionStatus.awaitingInput => 'waiting for you',
    SessionStatus.awaitingApproval => 'awaiting approval',
    SessionStatus.error => 'error',
    SessionStatus.exited => 'exited',
    null => '…',
  };

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _ApprovalChip extends ConsumerWidget {
  const _ApprovalChip({required this.sessionId, required this.item});
  final String sessionId;
  final ApprovalRequestItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.gavel, size: 18),
              const SizedBox(width: 8),
              Text(
                'Approval needed: ${item.tool}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              item.preview,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          if (item.decided)
            Text(
              'Decision: ${item.decision}',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Row(
              children: [
                FilledButton(
                  onPressed: () => ref
                      .read(storeControllerProvider.notifier)
                      .approve(sessionId, item.callId, ok: true),
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => ref
                      .read(storeControllerProvider.notifier)
                      .approve(sessionId, item.callId, ok: false),
                  child: const Text('Deny'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
