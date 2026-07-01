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

    if (items.isNotEmpty && items.last.seq != _lastSeq) {
      final firstLoad = _lastSeq == 0;
      _lastSeq = items.last.seq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        if (firstLoad) {
          // Opening the session: land on the newest message. Markdown / code /
          // images settle over several frames, so re-jump a few times.
          _jumpToBottom();
          for (final ms in const [60, 180, 360, 600]) {
            Future<void>.delayed(Duration(milliseconds: ms), _jumpToBottom);
          }
        } else {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }

    final fake = ref.watch(fakeGlassProvider);
    final cs = Theme.of(context).colorScheme;
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
            // Leave room so the first/last items clear the floating glass bars
            // (bottom = safe-area inset + composer height + a breathing gap).
            padding: EdgeInsets.only(
              top: topInset + 60,
              bottom: MediaQuery.of(context).padding.bottom + 160,
            ),
            itemCount:
                items.length +
                (session?.status == SessionStatus.running ? 1 : 0),
            itemBuilder: (context, i) {
              // Trailing "working…" indicator while the agent is running.
              if (i >= items.length) return const _WorkingIndicator();
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
                ErrorItem() => _ErrorBanner(message: item.message),
              };
            },
          ),
          // Scrim: fade the transcript under the top edge so the floating
          // controls stay legible (≈30%→20%→transparent).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: topInset + 96,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      cs.surface.withValues(alpha: 0.80),
                      cs.surface.withValues(alpha: 0.70),
                      cs.surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          // Scrim: fade the transcript under the bottom composer.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: 150,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      cs.surface.withValues(alpha: 0.80),
                      cs.surface.withValues(alpha: 0.70),
                      cs.surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          // Top controls: three separate pieces — (back) label (toggle) chip.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    _glassCircle(
                      icon: Icons.arrow_back,
                      onTap: () => context.go('/'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(
                                  color: cs.surface,
                                  blurRadius: 6,
                                ),
                                Shadow(
                                  color: cs.surface,
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _glassCircle(
                      icon: fake ? Icons.blur_off : Icons.blur_on,
                      tooltip: fake ? 'Fake glass (fast)' : 'Liquid glass',
                      onTap: () =>
                          ref.read(fakeGlassProvider.notifier).state = !fake,
                    ),
                    const SizedBox(width: 6),
                    const ConnectionChip(circular: true),
                  ],
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

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  /// A round glass button for the top bar (back / toggle).
  Widget _glassCircle({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    return GlassSurface(
      borderRadius: 23,
      child: SizedBox(
        width: 46,
        height: 46,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 20),
          onPressed: onTap,
        ),
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

/// Three softly-pulsing dots shown at the tail of the transcript while the
/// session status is `running` — the "agent is working" cue.
class _WorkingIndicator extends StatefulWidget {
  const _WorkingIndicator();

  @override
  State<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<_WorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // Stagger each dot's phase so they ripple.
              final phase = (_c.value + i * 0.2) % 1.0;
              final t = (phase < 0.5 ? phase : 1 - phase) * 2; // 0→1→0
              return Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.3 + 0.5 * t),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
