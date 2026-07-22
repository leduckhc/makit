import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../store/elicitation.dart';
import '../../store/store.dart';
import '../composer/client_commands.dart';
import '../composer/composer.dart';
import '../composer/composer_selectors.dart';
import 'ask_card.dart';
import 'chat_transcript.dart';
import 'chat_metrics.dart';
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
  // Dedicated controller for free-text answers to an inline ask, kept separate
  // from the normal message draft so the two can never cross-contaminate.
  final _answerController = TextEditingController();
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
    final pendingAsk = ref.watch(pendingAskProvider(widget.sessionId));
    final trailer = trailerFor(
      running: session?.status == SessionStatus.running,
      awaiting: pendingAsk != null,
    );
    final hasTrailer = trailer != TranscriptTrailer.none;

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
      _lastSeq = items.last.seq;
      // Reversed list: the newest message lives at offset 0. Only pull to it if
      // the user is already near the bottom, so scrolling up to read history is
      // never yanked away by an incoming message.
      anchorToNewestIfNearBottom(_scroll);
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
              // Reversed so the resting position (offset 0) is the newest
              // message at the bottom: the session opens pinned to the latest
              // with no measuring pass, and older items build lazily only as
              // the user scrolls up.
              reverse: true,
              // Leave room so the first/last items clear the floating glass bars
              // (bottom = safe-area inset + composer height + a breathing gap).
              // Expanded composer is ~160px; use 200 for comfortable clearance.
              padding: EdgeInsets.only(
                top: topInset + 60,
                bottom: MediaQuery.of(context).padding.bottom + 200,
              ),
              itemCount: items.length + (hasTrailer ? 1 : 0),
              itemBuilder: (context, i) {
                // Reversed: i counts up from the visual bottom. The trailing
                // row (i == 0) is the inline ask card when awaiting (it takes
                // priority — Pi stays running while asking), else the
                // "working…" indicator while running.
                if (hasTrailer && i == 0) {
                  return trailer == TranscriptTrailer.ask
                      ? KeyedSubtree(
                          key: ValueKey('ask-${pendingAsk!.requestId}'),
                          child: transcriptRow(AskCard(ask: pendingAsk)),
                        )
                      : transcriptRow(const WorkingIndicator());
                }
                final index = items.length - 1 - (hasTrailer ? i - 1 : i);
                final item = items[index];
                return KeyedSubtree(
                  key: chatItemKey(item),
                  child: transcriptRow(chatItemWidget(item)),
                );
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
                      icon: PhosphorIconsLight.arrowLeft,
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
                  child: (pendingAsk != null && pendingAsk.freeText)
                      // Free-text answer mode: a dedicated, empty answer
                      // controller (keyed by requestId) so a pre-ask normal
                      // draft can never leak in as the answer. The normal draft
                      // lives in the composer's own controller and returns when
                      // the ask resolves.
                      ? Composer(
                          key: ValueKey('answer-${pendingAsk.requestId}'),
                          glass: true,
                          controller: _answerController,
                          onSend: (text) => _handleSend(text, pendingAsk),
                        )
                      : Composer(
                          key: const ValueKey('composer-normal'),
                          glass: true,
                          enabled: pendingAsk == null,
                          commands: ref.watch(
                            commandsProvider(widget.sessionId),
                          ),
                          onSend: (text) => _handleSend(text, pendingAsk),
                          running: session?.status == SessionStatus.running,
                          onCancel: _cancelTurn,
                          footerActions: [
                            ComposerModelSelector(sessionId: widget.sessionId),
                            ComposerThinkingSelector(
                              sessionId: widget.sessionId,
                            ),
                            ComposerModeSelector(sessionId: widget.sessionId),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
          popUpAnimationStyle: AnimationStyle.noAnimation,
          padding: EdgeInsets.zero,
          icon: const Icon(PhosphorIconsLight.dotsThree, size: 20),
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
          itemBuilder: (context) {
            final cs = Theme.of(context).colorScheme;
            return [
              const PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  leading: Icon(PhosphorIconsLight.pencilSimple),
                  title: Text('Rename session'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'model',
                child: ListTile(
                  leading: Icon(PhosphorIconsLight.robot),
                  title: Text('Model'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'thinking',
                child: ListTile(
                  leading: Icon(PhosphorIconsLight.brain),
                  title: Text('Thinking'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'quit',
                child: ListTile(
                  leading: Icon(PhosphorIconsLight.power, color: cs.error),
                  title: Text(
                    'Quit session',
                    style: TextStyle(color: cs.error),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ];
          },
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

  Future<void> _handleSend(String text, [PendingAsk? pendingAsk]) async {
    // Free-text answer to an inline ask: route to the elicitation response
    // instead of sending a normal message (single-question only).
    if (pendingAsk != null && pendingAsk.freeText) {
      ref
          .read(elicitationControllerProvider.notifier)
          .submitFreeText(pendingAsk.requestId, text);
      return;
    }
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
    _answerController.dispose();
    super.dispose();
  }
}
