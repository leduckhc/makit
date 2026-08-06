import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/elicitation.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/attachment_controller.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/composer/composer.dart';
import '../../ui/composer/composer_draft.dart';
import '../../ui/composer/composer_selectors.dart';
import '../../ui/composer/context_usage.dart';
import '../../ui/composer/pending_queue_slot.dart';
import '../../ui/session/ask_card.dart';
import '../../ui/session/chat_metrics.dart';
import '../../ui/session/chat_transcript.dart';
import '../../ui/session/navigator/message_navigator_overlay.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import '../../ui/session/transcript_list.dart';
import '../../ui/widgets/pr_signals.dart';
import 'composer_focus.dart';
import 'new_worktree_dialog.dart';
import 'panes/pane_header.dart';
import 'pr_bar.dart';
import 'groups/agent_picker.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'selected_session.dart';
import 'worktree_starter.dart';

// Re-export the pane-header + harness widgets so existing importers of
// `desktop_chat_pane.dart` (e.g. pane_tree_view, widget tests) keep resolving
// them after the SPEC-19 split.
export 'panes/pane_header.dart'
    show PaneHeader, SessionActionsMenu, UnfoldStrip, sessionPaneTitle;

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
  /// Creates the desktop chat pane. When [sessionId] resolves to an existing
  /// session the pane shows its transcript; otherwise (no [sessionId], or a
  /// persisted id that no longer resolves) it shows the starter placeholder,
  /// pre-filled with [worktree] — the enclosing tree's worktree — when known.
  const DesktopChatPane({
    super.key,
    this.sessionId,
    this.worktree,
    this.showHeader = true,
    this.composerFocusId,
    this.composerExpanded = true,
  });

  /// The session this pane hosts, or null to start one in [worktree].
  final String? sessionId;

  /// The enclosing tree's worktree. A null- or dead-session leaf renders the
  /// in-place [WorktreeStarter] when set; the no-worktree case shows
  /// [EmptyPaneStarter], whose action opens the New-worktree dialog.
  final SelectedWorktree? worktree;

  /// Whether to render the in-pane session header (title + actions menu). The
  /// split pane tree shows a single merged header in its tab strip, so it
  /// passes false to avoid a second stacked bar.
  final bool showHeader;

  /// The hosting pane's leaf id, used to key this pane's composer
  /// [FocusNode] via [desktopComposerFocusProvider] so each split pane owns a
  /// distinct node (and the "focus composer" shortcut can target the active
  /// leaf). Null (standalone use) lets the [Composer] own its own node.
  final String? composerFocusId;

  /// Whether this pane's composer stays in its full (multiline + footer) form.
  /// The split tree passes false for the panes that are not the active split,
  /// so their composers shrink to a single line — a stronger "this one is not
  /// where you're typing" signal than the pane's background step alone, and the
  /// same collapse mobile does when the field loses focus. Clicking into such a
  /// composer activates the split and focuses the field, which expands it.
  final bool composerExpanded;

  @override
  ConsumerState<DesktopChatPane> createState() => _DesktopChatPaneState();
}

class _DesktopChatPaneState extends ConsumerState<DesktopChatPane> {
  final _scroll = ScrollController();
  // SPEC-34: the render-layer handle the message navigator jumps through.
  final _jumpTarget = TranscriptJumpTarget();
  String? _subscribed;
  int _lastSeq = 0;

  /// Caller-owned composer controllers, one per bound session, so the PR-actions
  /// split button (a sibling of the composer) can inject prompt text into the
  /// field. Keyed by session id and disposed with the pane.
  final _composerControllers = <String, TextEditingController>{};
  // Dedicated controller for free-text answers to an inline ask, kept separate
  // from the per-session message drafts so the two never cross-contaminate.
  final _answerController = TextEditingController();

  TextEditingController _composerControllerFor(String sessionId) =>
      _composerControllers.putIfAbsent(sessionId, TextEditingController.new);

  /// Insert a canned PR-action [prompt] into the composer without sending it:
  /// set the field (or append below existing text so a half-typed message is
  /// never destroyed), persist the draft, and focus the field so the user can
  /// review and hit Send.
  void _insertPrompt(String sessionId, String prompt) {
    final ctrl = _composerControllerFor(sessionId);
    final existing = ctrl.text;
    final next = existing.trim().isEmpty ? prompt : '$existing\n\n$prompt';
    ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    ref.read(composerDraftsProvider.notifier).set(sessionId, next);
    final focusId = widget.composerFocusId;
    if (focusId != null) {
      ref.read(desktopComposerFocusProvider(focusId)).requestFocus();
    }
  }

  void _ensureSubscribed(String? sessionId) {
    if (sessionId == null || sessionId == _subscribed) return;
    _subscribed = sessionId;
    _lastSeq = 0;
    // Defer the subscribe (and its history replay) to after the first frame so
    // the sidebar paints first — the conversation fills in immediately after.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(storeControllerProvider.notifier).subscribeSession(sessionId);
    });
  }

  Future<void> _handleSend(
    String sessionId,
    String text, [
    PendingAsk? pendingAsk,
  ]) async {
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
        sessionId: sessionId,
      );
      if (handled) return;
    }
    final store = ref.read(storeControllerProvider.notifier);
    // SPEC-33: take + clear in one step so a second tap cannot resend the same
    // images.
    final sending = takeAttachmentsForSend(ref, sessionId);
    store.appendOptimisticMessage(sessionId, text, attachments: sending);
    store.sendMessage(sessionId, text, attachments: sending);
  }

  void _cancelTurn(String sessionId) => handleClientCommand(
    '/cancel',
    context: context,
    ref: ref,
    sessionId: sessionId,
  );

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    // A bound session that no longer exists (e.g. a persisted layout pointing
    // at a quit session) resolves to null here and falls back to the tree's
    // worktree harness picker — no dead pane, no crash.
    final session = sessionId == null
        ? null
        : ref.watch(sessionsProvider).byId(sessionId);
    if (sessionId == null || session == null) {
      // A pane that knows its worktree starts a session in place: harness +
      // model/reasoning pills + composer. Without one there is nothing to start
      // in, so it falls back to the placeholder that opens the dialog (which
      // picks the worktree). Either way no pane is a dead end (SPEC-27).
      final worktree = widget.worktree;
      return Column(
        children: [
          if (widget.showHeader) const UnfoldStrip(),
          Expanded(
            child: worktree == null
                ? const EmptyPaneStarter()
                : WorktreeStarter(worktree: worktree),
          ),
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

    final items = ref.watch(chatItemsProvider(sessionId));
    // The worktree behind the next-step bar, from the poller-refreshed snapshot.
    final at = ref.watch(reposProvider).locateWorktree(session.worktreePath);

    // Keep the transcript pinned to the newest message as items stream in,
    // but only when the user is already near the bottom so scrolling up to read
    // history is never yanked away. Reversed list: newest is at offset 0.
    if (items.isNotEmpty && items.last.seq != _lastSeq) {
      _lastSeq = items.last.seq;
      anchorToNewestIfNearBottom(_scroll);
    }

    final running = session.status == SessionStatus.running;
    final pendingAsk = ref.watch(pendingAskProvider(sessionId));
    // Clear the dedicated free-text answer controller when the ask ends or
    // leaves free-text mode, so a later answer composer starts empty.
    ref.listen(pendingAskProvider(sessionId), (prev, next) {
      if (next == null || !next.freeText) _answerController.clear();
    });
    final trailer = trailerFor(running: running, awaiting: pendingAsk != null);
    final hasTrailer = trailer != TranscriptTrailer.none;

    return Column(
      children: [
        if (widget.showHeader)
          PaneHeader(session: session, fallbackId: sessionId),
        Expanded(
          child: items.isEmpty
              ? const _EmptyTranscript()
              // The ListView fills the full pane width so the mouse wheel
              // scrolls the transcript anywhere in the pane, not just over the
              // centered content column. Each row keeps the readable-width cap
              // via its own centered ConstrainedBox, so the layout is unchanged.
              : Stack(
                  children: [
                    TranscriptListView(
                      controller: _scroll,
                      jumpTarget: _jumpTarget,
                      padding: const EdgeInsets.symmetric(vertical: kSpace12),
                      itemCount: items.length + (hasTrailer ? 1 : 0),
                      // Let the lazy list find each already-built row at its
                      // new index when items stream in, instead of discarding
                      // every row (and its fold state) because the slots
                      // shifted.
                      findChildIndexCallback: transcriptChildIndexFinder(
                        items,
                        hasTrailer: hasTrailer,
                      ),
                      itemBuilder: (context, i) {
                        // Reversed: i counts up from the bottom. The trailing row
                        // (i == 0) is the inline ask card when awaiting (priority —
                        // Pi stays running while asking), else the "working…"
                        // indicator while running.
                        final bool isTrailer = hasTrailer && i == 0;
                        final int position =
                            items.length - 1 - (hasTrailer ? i - 1 : i);
                        final ChatItem? item = isTrailer
                            ? null
                            : items[position];
                        final Widget child = !isTrailer
                            ? chatItemWidget(
                                sessionId,
                                item!,
                                position: position,
                              )
                            : (trailer == TranscriptTrailer.ask
                                  ? AskCard(ask: pendingAsk!)
                                  : const WorkingIndicator());
                        // Center each row within the same readable-width cap as
                        // the composer, so the transcript column lines up with the
                        // input instead of stretching edge-to-edge. The ListView
                        // itself stays full width so the mouse wheel scrolls
                        // anywhere in the pane; only the row *content* is capped.
                        // Key item rows by identity (via KeyedSubtree) so inline
                        // expand/collapse state stays with the right call as the
                        // reversed list reorders.
                        return KeyedSubtree(
                          key: !isTrailer
                              ? chatItemKey(item!)
                              : (trailer == TranscriptTrailer.ask
                                    ? ValueKey('ask-${pendingAsk!.requestId}')
                                    : null),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: kReadableContentMaxWidth,
                              ),
                              child: transcriptRow(child),
                            ),
                          ),
                        );
                      },
                    ),
                    // SPEC-34: the message navigator, over the transcript.
                    // Renders nothing when the chosen style is `off`.
                    MessageNavigatorOverlay(
                      sessionId: sessionId,
                      controller: _scroll,
                      target: _jumpTarget,
                      items: items,
                      hasTrailer: hasTrailer,
                    ),
                    // Floating "jump to newest" affordance over the transcript,
                    // just above the composer — the same widget as mobile.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: kSpace8,
                      child: Center(child: JumpToNewestButton(scroll: _scroll)),
                    ),
                  ],
                ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kReadableContentMaxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The next-step bar: one sentence about this worktree and
                  // the one action that moves it forward (direction B1). Reads
                  // the worktree out of the poller-refreshed repos snapshot, so
                  // it updates in place as CI/state changes.
                  //
                  // No `Builder` around this: `ref.watch` registers against the
                  // enclosing ConsumerState wherever it is called, so one bought
                  // no rebuild isolation — only a local name, which `at` now is.
                  PrComposerBar(
                    status: prStatusFor(at, fallbackBranch: session.branch),
                    pr: at?.worktree.pr,
                    projectId: at?.repo.id,
                    worktreePath: session.worktreePath,
                    branch: at?.worktree.branch ?? session.branch,
                    uncommittedFiles: at?.worktree.uncommittedFiles ?? 0,
                    onInsertPrompt: (prompt) =>
                        _insertPrompt(sessionId, prompt),
                  ),
                  // ABOVE the composer, not inside it: as a Composer child every
                  // queued message inflated the composer's own box and ate the
                  // room the field and transcript need. As a sibling it also stays
                  // visible while an inline ask disables the composer, which is
                  // why it lived inside in the first place (SPEC-35/38).
                  PendingQueueSlot(sessionId: sessionId),
                  if (pendingAsk != null && pendingAsk.freeText)
                    // Free-text answer mode: a dedicated empty answer controller
                    // (keyed by requestId) so the per-session normal draft can
                    // never leak in as the answer, and is preserved for when the
                    // ask resolves.
                    Composer(
                      key: ValueKey('answer-${pendingAsk.requestId}'),
                      controller: _answerController,
                      alwaysExpanded: widget.composerExpanded,
                      onSend: (text) =>
                          _handleSend(sessionId, text, pendingAsk),
                    )
                  else
                    Composer(
                      // Key by session so switching the pane's bound session (same
                      // leaf id → same pane state) recreates the composer and
                      // re-seeds initialText, instead of leaking s1's text into s2.
                      key: ValueKey(sessionId),
                      // SPEC-33: the whole attachment capability, wired
                      // identically on both surfaces. Nothing paired → nowhere to
                      // upload, so the clip stays inert with a reason and paste is
                      // left to the field's text handling.
                      attachments: composerAttachments(context, ref, sessionId),
                      enabled: pendingAsk == null,
                      controller: _composerControllerFor(sessionId),
                      commands: ref.watch(commandsProvider(sessionId)),
                      onSend: (text) =>
                          _handleSend(sessionId, text, pendingAsk),
                      onCancel: () => _cancelTurn(sessionId),
                      running: running,
                      alwaysExpanded: widget.composerExpanded,
                      // Persist the draft per session so it survives worktree
                      // switches and pane splits (the composer is recreated on both).
                      initialText: ref.read(composerDraftsProvider)[sessionId],
                      onDraftChanged: (text) => ref
                          .read(composerDraftsProvider.notifier)
                          .set(sessionId, text),
                      footerActions: [
                        if (ref
                                .watch(sessionMetaProvider(sessionId))
                                ?.configOptions
                                .isNotEmpty ??
                            false)
                          ComposerConfigOptions(
                            sessionId: sessionId,
                            desktop: true,
                          )
                        else ...[
                          ComposerModelSelector(sessionId: sessionId),
                          ComposerThinkingSelector(sessionId: sessionId),
                          ComposerModeSelector(sessionId: sessionId),
                        ],
                      ],
                      // SPEC-37: shown for every agent — it reads usage, not
                      // config — so it sits outside the configOptions branch.
                      //
                      // SPEC-40: trailing, not an action. As an action its
                      // equal-share `Flexible` reserved half the row for a 36pt
                      // control and starved the pill.
                      footerTrailing: ContextUsageButton(
                        sessionId: sessionId,
                        desktop: true,
                      ),
                      focusNode: widget.composerFocusId == null
                          ? null
                          : ref.watch(
                              desktopComposerFocusProvider(
                                widget.composerFocusId!,
                              ),
                            ),
                      sendChord: ref
                          .watch(keymapProvider)
                          .chordFor(ShortcutAction.sendMessage),
                      newlineChord: ref
                          .watch(keymapProvider)
                          .chordFor(ShortcutAction.composerNewline),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _jumpTarget.dispose();
    _scroll.dispose();
    for (final c in _composerControllers.values) {
      c.dispose();
    }
    _answerController.dispose();
    super.dispose();
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

/// The placeholder for a sessionless pane with NO worktree (SPEC-30): a short
/// prompt plus a "New worktree" button that opens the New-worktree dialog, where
/// the worktree is created. A pane that already has a worktree starts in place
/// via [WorktreeStarter] instead, so no empty pane is a dead end.
class EmptyPaneStarter extends ConsumerWidget {
  /// Creates the placeholder.
  const EmptyPaneStarter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    // On a board, starting a session is only half of what you want here: the
    // other half is pulling in an agent that is already running somewhere
    // (SPEC-30 decision 14). The tab-strip `+` covers a board that has panes;
    // an empty one has no strip worth aiming at, so the offer belongs here.
    // A worktree group never shows this widget (it gets [WorktreeStarter]), and
    // its membership is derived anyway — there would be no list to add to.
    final isBoard = ref.watch(activeGroupProvider).kind == GroupKind.board;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsLight.chats, size: 40, color: cs.outline),
          const SizedBox(height: kSpace12),
          Text(
            // Unchanged wording: the fresh-launch group is a board, so a
            // board-specific sentence here would replace this one almost
            // everywhere — and "add one" would be a lie when nothing is running
            // yet. The extra button below is the whole difference.
            'Select a session, or start a new one',
            style: TextStyle(color: cs.outline),
          ),
          const SizedBox(height: kSpace16),
          // Wrap, not Row: the canvas can be squeezed to ~350px when the
          // sidebar is dragged to its maximum, and two buttons side by side
          // overflow there.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: kSpace8,
            runSpacing: kSpace8,
            children: [
              FilledButton.icon(
                icon: const Icon(PhosphorIconsLight.plus, size: 16),
                label: const Text('New worktree'),
                onPressed: () => showNewWorktreeDialog(context, ref),
              ),
              if (isBoard)
                OutlinedButton.icon(
                  icon: const Icon(PhosphorIconsLight.robot, size: 16),
                  label: const Text('Add agent'),
                  onPressed: () => showAgentPicker(context, ref),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
