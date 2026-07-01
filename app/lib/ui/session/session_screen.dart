import 'package:collection/collection.dart';
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
import '../widgets/glass.dart';

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

    final fake = ref.watch(fakeGlassProvider);
    final topInset = MediaQuery.of(context).padding.top;
    // Session titles are usually gibberish ids — prefer the repo/project name.
    final project = ref
        .watch(projectsProvider)
        .projects
        .firstWhereOrNull((p) => p.id == session?.projectId);
    final label = project?.name ?? session?.title ?? widget.sessionId;
    return Scaffold(
      // Edge-to-edge so the transcript scrolls *behind* the glass bars.
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        children: [
          ListView.builder(
            controller: _scroll,
            // Leave room so the first/last items clear the floating glass bars.
            padding: EdgeInsets.only(top: topInset + 60, bottom: 96),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return switch (item) {
                UserMessageItem() =>
                  ChatBubble.user(text: item.text, ts: item.ts),
                AgentMessageItem() =>
                  AgentMessage(text: item.text, ts: item.ts),
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
          // Top floating glass bar: back · title/status · glass toggle · chip.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: GlassSurface(
                  borderRadius: 24,
                  child: SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, size: 20),
                          onPressed: () => context.go('/'),
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.45),
                            shape: const CircleBorder(),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: fake ? 'Fake glass (fast)' : 'Liquid glass',
                          icon: Icon(
                            fake ? Icons.blur_off : Icons.blur_on,
                            size: 20,
                          ),
                          onPressed: () =>
                              ref.read(fakeGlassProvider.notifier).state = !fake,
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.45),
                            shape: const CircleBorder(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const ConnectionChip(circular: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Bottom floating glass composer.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: GlassSurface(
                  borderRadius: 28,
                  // Composer sits over the keyboard/typing — frostier + less
                  // transparent than the top bar so text stays legible.
                  blur: 24,
                  tint: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0x66FFFFFF)
                      : const Color(0x59FFFFFF),
                  child: Composer(
                    glass: true,
                    commands: ref.watch(commandsProvider(widget.sessionId)),
                    steering: session?.status == SessionStatus.running,
                    onSend: (text) => _handleSend(text),
                  ),
                ),
              ),
            ),
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
