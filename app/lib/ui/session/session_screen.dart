import 'dart:math';

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
    final meta = ref.watch(sessionMetaProvider(widget.sessionId));

    ref.listen<ActionError?>(sessionActionErrorProvider(widget.sessionId), (
      prev,
      next,
    ) {
      if (next == null) return;
      if (prev?.seq == next.seq) return;
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${next.action} failed: ${next.reason}')),
      );
    });

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

    final cs = Theme.of(context).colorScheme;
    final topInset = MediaQuery.of(context).padding.top;
    // Prefer the session name (generated in the background by the session
    // namer). Fall back to the project name, then the raw session id.
    final project = ref
        .watch(projectsProvider)
        .projects
        .firstWhereOrNull((p) => p.id == session?.projectId);
    final sessionName = session?.title.trim() ?? '';
    final label = sessionName.isNotEmpty
        ? sessionName
        : (project?.name ?? widget.sessionId);
    return Scaffold(
      // Edge-to-edge so the transcript scrolls *behind* the glass bars.
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        children: [
          GestureDetector(
            onTap: () {
              // Dismiss composer focus when user taps on the chat transcript.
              FocusManager.instance.primaryFocus?.unfocus();
            },
            // HitTestBehavior.translucent so taps on empty space register,
            // while child widgets (bubbles, cards) still receive their own taps.
            behavior: HitTestBehavior.translucent,
            child: ListView.builder(
              controller: _scroll,
              // Leave room so the first/last items clear the floating glass bars
              // (bottom = safe-area inset + composer height + a breathing gap).
              // Expanded composer is ~160px; use 200 for comfortable clearance.
              padding: EdgeInsets.only(
                top: topInset + 60,
                bottom: MediaQuery.of(context).padding.bottom + 200,
              ),
              itemCount:
                  items.length +
                  (session?.status == SessionStatus.running ? 1 : 0),
              itemBuilder: (context, i) {
                // Trailing "working…" indicator while the agent is running.
                if (i >= items.length) return const _WorkingIndicator();
                final item = items[i];
                return switch (item) {
                  UserMessageItem() => ChatBubble.user(
                    text: item.text,
                    ts: item.ts,
                  ),
                  AgentMessageItem() => AgentMessage(
                    text: item.text,
                    ts: item.ts,
                  ),
                  ThinkingItem() => _ThinkingCard(text: item.text),
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
                    GlassCircleButton(
                      icon: Icons.arrow_back,
                      onTap: () => context.go('/'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(color: cs.surface, blurRadius: 6),
                                    Shadow(color: cs.surface, blurRadius: 12),
                                  ],
                                ),
                          ),
                          if (session?.pane != null)
                            Text(
                              '\u29c9 ${session!.pane!.mux} ${session.pane!.paneId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: cs.onSurface.withValues(alpha: 0.45),
                                    shadows: [
                                      Shadow(color: cs.surface, blurRadius: 6),
                                    ],
                                  ),
                            ),
                          if (meta?.model != null)
                            Text(
                              '${meta!.model!.name} · ${meta.thinking}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: cs.onSurface.withValues(alpha: 0.55),
                                    shadows: [
                                      Shadow(color: cs.surface, blurRadius: 6),
                                    ],
                                  ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _glassMenu(),
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
                  // Unified design-system glass (see MASTER.md) — same recipe
                  // as the top bar.
                  child: Composer(
                    glass: true,
                    commands: ref.watch(commandsProvider(widget.sessionId)),
                    onSend: (text) => _handleSend(text),
                    running: session?.status == SessionStatus.running,
                    onCancel: _cancelTurn,
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

  /// Glass overflow menu for the top bar — session-level actions (rename,
  /// quit). Mirrors the home screen's project overflow menu.
  Widget _glassMenu() {
    return GlassSurface(
      borderRadius: 23,
      child: SizedBox(
        width: 46,
        height: 46,
        child: PopupMenuButton<String>(
          tooltip: 'Session actions',
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (value) {
            switch (value) {
              case 'rename':
                handleClientCommand(
                  '/name',
                  context: context,
                  ref: ref,
                  sessionId: widget.sessionId,
                );
              case 'model':
                handleClientCommand(
                  '/model',
                  context: context,
                  ref: ref,
                  sessionId: widget.sessionId,
                );
              case 'thinking':
                handleClientCommand(
                  '/thinking',
                  context: context,
                  ref: ref,
                  sessionId: widget.sessionId,
                );
              case 'quit':
                _confirmQuit();
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
        ),
      ),
    );
  }

  Future<void> _confirmQuit() async {
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
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(storeControllerProvider.notifier)
          .killSession(widget.sessionId);
      if (mounted) context.go('/');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
    }
  }

  /// Cancel the in-flight agent turn (reuses the /cancel client command).
  void _cancelTurn() {
    handleClientCommand(
      '/cancel',
      context: context,
      ref: ref,
      sessionId: widget.sessionId,
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

/// Reasoning/thinking trace. Folded to a single greyed one-liner with an
/// ellipsis; tap to expand the full text.
class _ThinkingCard extends StatefulWidget {
  const _ThinkingCard({required this.text});
  final String text;

  @override
  State<_ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<_ThinkingCard> {
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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

/// Shimmering "working" text shown at the tail of the transcript while the
/// session status is `running`. Picks a random work-flavoured word per turn.
class _WorkingIndicator extends StatefulWidget {
  const _WorkingIndicator();

  @override
  State<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<_WorkingIndicator>
    with SingleTickerProviderStateMixin {
  static const _words = [
    'Thinking',
    'Cooking',
    'Pondering',
    'Crunching',
    'Conjuring',
    'Reasoning',
    'Tinkering',
    'Brewing',
    'Computing',
    'Noodling',
    'Scheming',
    'Percolating',
    'Wrangling',
    'Analyzing',
    'Plotting',
    'Untangling',
  ];

  late final String _word = _words[Random().nextInt(_words.length)];

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = cs.onSurfaceVariant.withValues(alpha: 0.18);
    final highlight = cs.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              colors: [base, highlight, base],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradient(_c.value),
            ).createShader(bounds),
            child: child,
          );
        },
        child: Text(
          _word,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// Slides a gradient horizontally across its bounds as [t] goes 0→1, so the
/// highlight band sweeps left→right (a shimmer). Clamp tiling keeps the
/// off-band area the base colour.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);
  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues((t * 2 - 1) * bounds.width, 0, 0);
  }
}
