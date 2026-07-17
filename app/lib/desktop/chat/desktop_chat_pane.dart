import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/composer/composer.dart';
import '../../ui/session/chat_transcript.dart';
import '../../ui/session/tool_call_detail_screen.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'composer_focus.dart';
import 'harness_picker.dart';
import 'panes/pane_header.dart';
import 'selected_session.dart';
import '../../ui/composer/composer_selectors.dart';

// Re-export the pane-header + harness widgets so existing importers of
// `desktop_chat_pane.dart` (e.g. pane_tree_view, widget tests) keep resolving
// them after the SPEC-19 split.
export 'panes/pane_header.dart'
    show PaneHeader, SessionActionsMenu, UnfoldStrip, sessionPaneTitle;
export 'harness_picker.dart' show HarnessPicker, WorktreeStartView;

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
  /// Creates the desktop chat pane. When [sessionId] is null the pane falls
  /// back to the globally [selectedSessionProvider] (single-pane behaviour).
  const DesktopChatPane({
    super.key,
    this.sessionId,
    this.showHeader = true,
    this.trackGlobalSelection = true,
    this.composerFocusId,
  });

  /// The session this pane hosts, or null to defer to the global selection.
  final String? sessionId;

  /// Whether to render the in-pane session header (title + actions menu). The
  /// split pane tree shows a single merged header in its tab strip, so it
  /// passes false to avoid a second stacked bar.
  final bool showHeader;

  /// Whether a null [sessionId] should fall back to the global
  /// [selectedSessionProvider]. The split pane tree resolves the fallback
  /// itself (only the active pane tracks the global selection), so it passes
  /// false to keep inactive empty panes truly empty.
  final bool trackGlobalSelection;

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
    final sessionId =
        widget.sessionId ??
        (widget.trackGlobalSelection
            ? ref.watch(selectedSessionProvider)
            : null);
    if (sessionId == null) {
      // A sessionless worktree selected in the sidebar → harness picker to
      // start a session in that existing worktree. Only the active pane tracks
      // this global draft; inactive split panes stay empty.
      final worktree = widget.trackGlobalSelection
          ? ref.watch(selectedWorktreeProvider)
          : null;
      if (worktree != null) {
        return WorktreeStartView(
          key: ValueKey(worktree.path),
          worktree: worktree,
          composerFocusId: widget.composerFocusId,
        );
      }
      // No session yet, but the pane still owns the unfold affordance when the
      // sidebar is hidden — surface a minimal top strip above the placeholder.
      return Column(
        children: [
          if (widget.showHeader) const UnfoldStrip(),
          const Expanded(child: _NoSelection()),
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
        if (widget.showHeader)
          PaneHeader(session: session, fallbackId: sessionId),
        Expanded(
          child: (session?.pending == true && session?.branch == null)
              ? HarnessPicker(session: session!)
              : items.isEmpty
              ? const _EmptyTranscript()
              // The ListView fills the full pane width so the mouse wheel
              // scrolls the transcript anywhere in the pane, not just over the
              // centered content column. Each row keeps the readable-width cap
              // via its own centered ConstrainedBox, so the layout is unchanged.
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: items.length + (running ? 1 : 0),
                  itemBuilder: (context, i) {
                    final Widget child = i >= items.length
                        ? const WorkingIndicator(compact: true)
                        : chatItemWidget(
                            items[i],
                            onOpenTool: _openToolDetail,
                            compact: true,
                          );
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: kReadableContentMaxWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: child,
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
              child: Composer(
                commands: ref.watch(commandsProvider(sessionId)),
                onSend: (text) => _handleSend(sessionId, text),
                onCancel: () => _cancelTurn(sessionId),
                running: running,
                alwaysExpanded: true,
                footerActions: [
                  ComposerModelSelector(sessionId: sessionId),
                  ComposerThinkingSelector(sessionId: sessionId),
                  ComposerModeSelector(sessionId: sessionId),
                ],
                focusNode: widget.composerFocusId == null
                    ? null
                    : ref.watch(
                        desktopComposerFocusProvider(widget.composerFocusId!),
                      ),
                sendChord: ref
                    .watch(keymapProvider)
                    .chordFor(ShortcutAction.sendMessage),
                newlineChord: ref
                    .watch(keymapProvider)
                    .chordFor(ShortcutAction.composerNewline),
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

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.forum, size: 40, weight: 200, color: cs.outline),
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
