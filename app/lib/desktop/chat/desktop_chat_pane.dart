import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/models.dart';
import '../../store/elicitation.dart';
import '../../store/store.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/composer/composer.dart';
import '../../ui/session/ask_card.dart';
import '../../ui/session/chat_transcript.dart';
import '../../ui/session/chat_metrics.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'composer_focus.dart';
import 'composer_draft.dart';
import 'harness_picker.dart';
import 'new_session_dialog.dart';
import 'pr_bar.dart';
import 'panes/pane_header.dart';
import 'selected_session.dart';
import '../../ui/composer/composer_selectors.dart';

// Re-export the pane-header + harness widgets so existing importers of
// `desktop_chat_pane.dart` (e.g. pane_tree_view, widget tests) keep resolving
// them after the SPEC-19 split.
export 'panes/pane_header.dart'
    show PaneHeader, SessionActionsMenu, UnfoldStrip, sessionPaneTitle;
export 'harness_picker.dart' show HarnessPicker;

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
  /// persisted id that no longer resolves) it shows the harness picker for
  /// [worktree] — the enclosing tree's worktree — but only when that is a
  /// *real* worktree. A draft's virtual worktree (`draft:<id>`) has nothing on
  /// disk, so a missing/dead session there falls back to the empty placeholder
  /// (as does a null [worktree]).
  const DesktopChatPane({
    super.key,
    this.sessionId,
    this.worktree,
    this.showHeader = true,
    this.composerFocusId,
  });

  /// The session this pane hosts, or null to start one in [worktree].
  final String? sessionId;

  /// The enclosing tree's worktree; a null-session (or dead-session) leaf
  /// renders this worktree's harness picker when it is a real worktree. A draft
  /// virtual worktree (or null) falls back to the empty placeholder instead.
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

  @override
  ConsumerState<DesktopChatPane> createState() => _DesktopChatPaneState();
}

class _DesktopChatPaneState extends ConsumerState<DesktopChatPane> {
  final _scroll = ScrollController();
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
    final sessionId = widget.sessionId;
    // A bound session that no longer exists (e.g. a persisted layout pointing
    // at a quit session) resolves to null here and falls back to the tree's
    // worktree harness picker — no dead pane, no crash.
    final session = sessionId == null
        ? null
        : ref.watch(sessionsProvider).byId(sessionId);
    if (sessionId == null || session == null) {
      final worktree = widget.worktree;
      // A real worktree with no (or a dead) session pre-fills the New-session
      // dialog with it. A draft's virtual worktree (`draft:<id>`) has nothing
      // on disk, so it (and a null worktree) offers the dialog with no
      // pre-fill. Every sessionless pane reaches the same placeholder + button
      // (SPEC-27) — no dead-end panes.
      final prefill =
          (worktree != null && !worktree.path.startsWith(kDraftWorktreePrefix))
          ? worktree
          : null;
      return Column(
        children: [
          if (widget.showHeader) const UnfoldStrip(),
          Expanded(child: EmptyPaneStarter(worktree: prefill)),
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
          child: (session.pending == true && session.branch == null)
              ? HarnessPicker(session: session)
              : items.isEmpty
              ? const _EmptyTranscript()
              // The ListView fills the full pane width so the mouse wheel
              // scrolls the transcript anywhere in the pane, not just over the
              // centered content column. Each row keeps the readable-width cap
              // via its own centered ConstrainedBox, so the layout is unchanged.
              : ListView.builder(
                  controller: _scroll,
                  // Reversed so the resting position (offset 0) is the newest
                  // message: opens pinned to the latest, older rows build
                  // lazily as the user scrolls up.
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: items.length + (hasTrailer ? 1 : 0),
                  itemBuilder: (context, i) {
                    // Reversed: i counts up from the bottom. The trailing row
                    // (i == 0) is the inline ask card when awaiting (priority —
                    // Pi stays running while asking), else the "working…"
                    // indicator while running.
                    final bool isTrailer = hasTrailer && i == 0;
                    final ChatItem? item = isTrailer
                        ? null
                        : items[items.length - 1 - (hasTrailer ? i - 1 : i)];
                    final Widget child = !isTrailer
                        ? chatItemWidget(item!)
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
                  // Permanent PR bar (SPEC-23): status pill (opens the PR on
                  // the web; hover shows CI checks) + a canned-prompt actions
                  // split button. Reads the open PR for this session's
                  // worktree from the (poller-refreshed) repos snapshot, so it
                  // updates in place as CI/state changes.
                  PrComposerBar(
                    pr: ref
                        .watch(reposProvider)
                        .prForWorktreePath(session.worktreePath),
                    uncommittedFiles: ref
                        .watch(reposProvider)
                        .uncommittedFilesForWorktreePath(session.worktreePath),
                    commitsAhead: ref
                        .watch(reposProvider)
                        .aheadCountForWorktreePath(session.worktreePath),
                    commitsBehind: ref
                        .watch(reposProvider)
                        .behindCountForWorktreePath(session.worktreePath),
                    onInsertPrompt: (prompt) =>
                        _insertPrompt(sessionId, prompt),
                  ),
                  if (pendingAsk != null && pendingAsk.freeText)
                    // Free-text answer mode: a dedicated empty answer controller
                    // (keyed by requestId) so the per-session normal draft can
                    // never leak in as the answer, and is preserved for when the
                    // ask resolves.
                    Composer(
                      key: ValueKey('answer-${pendingAsk.requestId}'),
                      controller: _answerController,
                      alwaysExpanded: true,
                      onSend: (text) =>
                          _handleSend(sessionId, text, pendingAsk),
                    )
                  else
                    Composer(
                      // Key by session so switching the pane's bound session (same
                      // leaf id → same pane state) recreates the composer and
                      // re-seeds initialText, instead of leaking s1's text into s2.
                      key: ValueKey(sessionId),
                      enabled: pendingAsk == null,
                      controller: _composerControllerFor(sessionId),
                      commands: ref.watch(commandsProvider(sessionId)),
                      onSend: (text) =>
                          _handleSend(sessionId, text, pendingAsk),
                      onCancel: () => _cancelTurn(sessionId),
                      running: running,
                      alwaysExpanded: true,
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
                          ComposerConfigOptions(sessionId: sessionId)
                        else ...[
                          ComposerModelSelector(sessionId: sessionId),
                          ComposerThinkingSelector(sessionId: sessionId),
                          ComposerModeSelector(sessionId: sessionId),
                        ],
                      ],
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

/// The unified sessionless-pane placeholder (SPEC-27): a short prompt plus a
/// "New session" button that opens the New-session dialog, pre-filling the
/// Worktree field with [worktree] when it is a real on-disk worktree. Replaces
/// both the old `WorktreeStartView` and the button-less `_NoSelection` so every
/// empty pane state reaches the one starter (no dead-end panes).
class EmptyPaneStarter extends ConsumerWidget {
  /// Creates the placeholder; [worktree] pre-fills the dialog when known.
  const EmptyPaneStarter({super.key, this.worktree});

  /// The real worktree to pre-fill the dialog with, or null for no pre-fill.
  final SelectedWorktree? worktree;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsLight.chats, size: 40, color: cs.outline),
          const SizedBox(height: 12),
          Text(
            'Select a session, or start a new one',
            style: TextStyle(color: cs.outline),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(PhosphorIconsLight.plus, size: 16),
            label: const Text('New session'),
            onPressed: () => showNewSessionDialog(
              context,
              ref,
              projectId: worktree?.projectId,
              worktree: worktree,
            ),
          ),
        ],
      ),
    );
  }
}
