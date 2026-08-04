import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/elicitation.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../composer/attachment_controller.dart';
import '../composer/client_commands.dart';
import '../composer/composer.dart';
import '../composer/composer_draft.dart';
import '../composer/composer_selectors.dart';
import '../composer/pending_queue.dart';
import '../composer/pending_queue_slot.dart';
import '../widgets/connection_chip.dart';
import '../widgets/glass.dart';
import '../widgets/menu_item.dart';
import 'chat_metrics.dart';
import 'chat_transcript.dart';
import 'navigator/message_navigator_overlay.dart';
import 'navigator/messages_sheet.dart';
import 'navigator/transcript_jumper.dart';
import 'session_pr_chip.dart';
import 'transcript_list.dart';

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  final _scroll = ScrollController();
  // SPEC-34: the render-layer handle jumps are resolved through, plus the jumper
  // the session-actions sheet drives. `itemCount`/`hasTrailer` are read at call
  // time, so a trailing "working…" row appearing mid-session cannot skew them.
  final _jumpTarget = TranscriptJumpTarget();
  late final TranscriptJumper _jumper = TranscriptJumper(
    target: _jumpTarget,
    itemCount: () => _items.length,
    hasTrailer: () => _hasTrailer,
    onFlash: (position) => recordJumpFlash(ref, widget.sessionId, position),
  );

  /// Latest transcript + trailer state, captured each build for [_jumper].
  List<ChatItem> _items = const [];
  bool _hasTrailer = false;
  // Dedicated controller for free-text answers to an inline ask, kept separate
  // from the normal message draft so the two can never cross-contaminate.
  final _answerController = TextEditingController();
  // The normal composer's field, one per session. Owned here (rather than left
  // inside Composer) so a PR action can write into it — see [_insertPrompt].
  // Keyed by session because rebinding the screen to another session must not
  // carry the previous session's text across, the same reason the composer
  // widget itself is keyed.
  final _composerControllers = <String, TextEditingController>{};
  int _lastSeq = 0;

  TextEditingController get _composerController => _composerControllers
      .putIfAbsent(widget.sessionId, TextEditingController.new);

  /// Put a canned PR prompt in the composer without sending it: append below any
  /// half-typed text rather than replacing it, and leave the caret at the end so
  /// the user can edit before sending. The draft is persisted by the composer's
  /// own controller listener.
  void _insertPrompt(String prompt) {
    final existing = _composerController.text;
    final next = existing.trim().isEmpty ? prompt : '$existing\n\n$prompt';
    _composerController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

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
    // Clear the dedicated free-text answer controller whenever the ask ends or
    // leaves free-text mode, so a later answer composer never reopens with a
    // stale draft.
    ref.listen(pendingAskProvider(widget.sessionId), (prev, next) {
      if (next == null || !next.freeText) _answerController.clear();
    });
    final trailer = trailerFor(
      running: session?.status == SessionStatus.running,
      awaiting: pendingAsk != null,
    );
    // SPEC-36: an inline queue keeps the trailer alive even when the agent has
    // gone idle with messages still pending — otherwise the row (and every
    // index shifted by it) would disappear under the user.
    final hasTrailer =
        trailer != TranscriptTrailer.none ||
        ref.watch(inlineQueueVisibleProvider(widget.sessionId));
    // Hand the current transcript shape to the sheet's jumper (read lazily by
    // its callbacks, so this must be the latest build's values).
    _items = items;
    _hasTrailer = hasTrailer;

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
    // The PR heading this session's worktree, if any (SPEC-23). Same resolver
    // the desktop composer bar uses, so both surfaces read one source.
    final pr = ref
        .watch(reposProvider)
        .prForWorktreePath(session?.worktreePath);
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
            child: TranscriptListView(
              controller: _scroll,
              jumpTarget: _jumpTarget,
              // Leave room so the first/last items clear the floating glass bars
              // (bottom = safe-area inset + composer height + a breathing gap).
              // Expanded composer is ~160px; use 200 for comfortable clearance.
              padding: EdgeInsets.only(
                top: topInset + 60,
                bottom: MediaQuery.of(context).padding.bottom + 200,
              ),
              itemCount: items.length + (hasTrailer ? 1 : 0),
              // Let the lazy list find each already-built row at its new index
              // when items stream in, instead of discarding every row (and its
              // fold state) because the slots shifted.
              findChildIndexCallback: transcriptChildIndexFinder(
                items,
                hasTrailer: hasTrailer,
              ),
              itemBuilder: (context, i) {
                // Reversed: i counts up from the visual bottom. The trailing
                // row (i == 0) is the inline ask card when awaiting (it takes
                // priority — Pi stays running while asking), else the
                // "working…" indicator while running.
                if (hasTrailer && i == 0) {
                  // SPEC-36: the trailer also hosts the INLINE pending queue, so
                  // no synthetic events are needed for it.
                  return KeyedSubtree(
                    key: trailer == TranscriptTrailer.ask
                        ? ValueKey('ask-${pendingAsk!.requestId}')
                        : null,
                    child: transcriptRow(
                      TranscriptTrailerRow(
                        sessionId: widget.sessionId,
                        trailer: trailer,
                        ask: pendingAsk,
                      ),
                    ),
                  );
                }
                final index = items.length - 1 - (hasTrailer ? i - 1 : i);
                final item = items[index];
                return KeyedSubtree(
                  key: chatItemKey(item),
                  child: transcriptRow(
                    chatItemWidget(widget.sessionId, item, position: index),
                  ),
                );
              },
            ),
          ),
          // SPEC-34: the message navigator, over the transcript and under the
          // floating bars. Renders nothing when the surface's style is `off`.
          MessageNavigatorOverlay(
            sessionId: widget.sessionId,
            controller: _scroll,
            target: _jumpTarget,
            items: items,
            hasTrailer: hasTrailer,
            // Clear the floating glass top bar, exactly as the list's padding does.
            topInset: topInset + 60,
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
                    const SizedBox(width: kSpace12),
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
                          // Subtitle line (SPEC-23): the pane label and/or the
                          // PR chip. Both are optional, so the line collapses
                          // to nothing on a headless, PR-less session.
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (session?.pane != null)
                                Flexible(
                                  child: Text(
                                    '\u29c9 ${session!.pane!.mux} '
                                    '${session.pane!.paneId}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: cs.onSurface.withValues(
                                            alpha: 0.45,
                                          ),
                                          shadows: [
                                            Shadow(
                                              color: cs.surface,
                                              blurRadius: 6,
                                            ),
                                          ],
                                        ),
                                  ),
                                ),
                              if (session?.pane != null && pr != null)
                                const SizedBox(width: kSpace6),
                              if (pr != null)
                                SessionPrChip(
                                  pr: pr,
                                  onInsertPrompt: _insertPrompt,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: kSpace8),
                    _glassMenu(),
                    const SizedBox(width: kSpace6),
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
                // Column grows *upward* from the bottom, so the jump button
                // appearing above the composer never nudges the composer.
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    JumpToNewestButton(scroll: _scroll),
                    const SizedBox(height: kSpace8),
                    GlassSurface(
                      borderRadius: 28,
                      // Unified design-system glass (see DESIGN.md) — same recipe
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
                              pendingQueue: PendingQueueSlot(
                                sessionId: widget.sessionId,
                                slot: PendingQueuePlacement.pinned,
                              ),
                              onSend: (text) => _handleSend(text, pendingAsk),
                            )
                          : Composer(
                              // Keyed by session so switching sessions in place
                              // gets a fresh field seeded from *that* session's
                              // draft, instead of carrying the old text over.
                              key: ValueKey('composer-${widget.sessionId}'),
                              // SPEC-33: the whole attachment capability, wired
                              // identically on both surfaces.
                              attachments: composerAttachments(
                                context,
                                ref,
                                widget.sessionId,
                              ),
                              glass: true,
                              controller: _composerController,
                              // SPEC-36: pending messages, when the user's
                              // placement preference is `pinned`.
                              pendingQueue: PendingQueueSlot(
                                sessionId: widget.sessionId,
                                slot: PendingQueuePlacement.pinned,
                              ),
                              enabled: pendingAsk == null,
                              commands: ref.watch(
                                commandsProvider(widget.sessionId),
                              ),
                              // Persist the draft per session so a half-typed
                              // message survives a route pop (SPEC-27).
                              initialText: ref.read(
                                composerDraftsProvider,
                              )[widget.sessionId],
                              onDraftChanged: (text) => ref
                                  .read(composerDraftsProvider.notifier)
                                  .set(widget.sessionId, text),
                              onSend: (text) => _handleSend(text, pendingAsk),
                              running: session?.status == SessionStatus.running,
                              onCancel: _cancelTurn,
                              footerActions: [
                                if (ref
                                        .watch(
                                          sessionMetaProvider(widget.sessionId),
                                        )
                                        ?.configOptions
                                        .isNotEmpty ??
                                    false)
                                  ComposerConfigOptions(
                                    sessionId: widget.sessionId,
                                  )
                                else ...[
                                  ComposerModelSelector(
                                    sessionId: widget.sessionId,
                                  ),
                                  ComposerThinkingSelector(
                                    sessionId: widget.sessionId,
                                  ),
                                  ComposerModeSelector(
                                    sessionId: widget.sessionId,
                                  ),
                                ],
                              ],
                            ),
                    ),
                  ],
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
          icon: Icon(
            PhosphorIconsRegular.dotsThree,
            size: 20,
            color: Theme.of(context).colorScheme.onSurface,
          ),
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
              case 'messages':
                showMyMessagesSheet(
                  context: context,
                  sessionId: widget.sessionId,
                  jumper: _jumper,
                );
              case 'archive':
                _confirmArchive();
            }
          },
          itemBuilder: (context) {
            // Only offer what this agent can actually do. An ACP agent carries
            // modes / config options instead of model + thinking, and offering
            // those anyway made the menu lie: Thinking used to open a picker and
            // report a level the agent never applied.
            //
            // `read`, not `watch`: this runs when the menu opens, outside this
            // widget's build, so a subscription made here would be scoped to the
            // wrong lifecycle. The menu is rebuilt on each open anyway, so it is
            // never stale in practice.
            final meta = ref.read(sessionMetaProvider(widget.sessionId));
            final canModel = sessionCanPickModel(meta);
            final canThink = sessionCanSetThinking(meta);
            return [
              themedMenuItem(
                value: 'rename',
                icon: PhosphorIconsLight.pencilSimple,
                label: 'Rename session',
              ),
              // SPEC-34: mobile's route back to your own prompts. Grouped with
              // Rename, not with Model/Thinking, because it is not capability
              // gated — it reads the transcript the client already holds, so it
              // works on every agent. Sitting above the rule also keeps that
              // rule's contract intact: it separates *configuration* from
              // Archive and disappears when there is no configuration.
              themedMenuItem(
                value: 'messages',
                icon: PhosphorIconsLight.listMagnifyingGlass,
                label: 'My messages',
              ),
              if (canModel)
                themedMenuItem(
                  value: 'model',
                  icon: PhosphorIconsLight.robot,
                  label: 'Model',
                ),
              if (canThink)
                themedMenuItem(
                  value: 'thinking',
                  icon: PhosphorIconsLight.brain,
                  label: 'Thinking',
                ),
              // The rule separates configuration from Archive, so it only earns
              // its place when there is configuration above it.
              if (canModel || canThink) const PopupMenuDivider(),
              themedMenuItem(
                value: 'archive',
                icon: PhosphorIconsLight.archiveBox,
                label: 'Archive session',
              ),
            ];
          },
        ),
      ),
    );
  }

  Future<void> _confirmArchive() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Archive session?'),
        content: const Text(
          'This stops the agent process and removes the session from the active list. '
          'The transcript stays on disk and can be restored later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(storeControllerProvider.notifier)
          .archiveSession(widget.sessionId);
      if (mounted) context.go('/');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not archive: $e')));
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
    // SPEC-33: take + clear in one step so a second tap cannot resend the same
    // images.
    final sending = takeAttachmentsForSend(ref, widget.sessionId);
    // Optimistic UI: show the message immediately so it doesn't look hung.
    // The server will echo it back; if there's a conflict we reconcile by seq.
    ref
        .read(storeControllerProvider.notifier)
        .appendOptimisticMessage(widget.sessionId, text, attachments: sending);
    // Send to server (may arrive out of order w.r.t. the local append, but seq resolves it).
    ref
        .read(storeControllerProvider.notifier)
        .sendMessage(widget.sessionId, text, attachments: sending);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _jumpTarget.dispose();
    _answerController.dispose();
    for (final c in _composerControllers.values) {
      c.dispose();
    }
    super.dispose();
  }
}
