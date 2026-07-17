import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/store.dart';
import 'composer_focus.dart';
import 'new_session_dialog.dart';
import 'panes/pane_tree_controller.dart';
import 'selected_session.dart';
import 'sidebar_layout.dart';
import '../settings/settings_window.dart' show settingsOpenProvider;

/// Installs the window-level (global-scope) keyboard shortcuts around the
/// desktop chat shell. Composer-scope actions (send / newline) are wired inside
/// the [Composer] itself; this scope handles navigation and window actions that
/// must fire regardless of which widget holds focus.
class DesktopKeymapScope extends ConsumerStatefulWidget {
  /// Wraps [child]; [onOpenSettings] backs the "Open settings" action.
  const DesktopKeymapScope({
    super.key,
    required this.onOpenSettings,
    required this.child,
  });

  /// Invoked by the "Open settings" shortcut.
  final VoidCallback onOpenSettings;

  /// The subtree the shortcuts apply to.
  final Widget child;

  @override
  ConsumerState<DesktopKeymapScope> createState() => _DesktopKeymapScopeState();
}

class _DesktopKeymapScopeState extends ConsumerState<DesktopKeymapScope> {
  /// The fallback focus holder for the whole window. Flutter dispatches key
  /// events to the primary focus and bubbles them **up** the focus tree, so a
  /// [Shortcuts] map only fires while the focused node is a descendant of it.
  /// This node keeps focus inside the scope whenever it would otherwise drain
  /// to a bare focus scope (e.g. after clicking an empty region or dismissing a
  /// dialog), which is what previously left the global shortcuts dead until the
  /// user clicked back into the composer.
  final FocusNode _scopeFocus = FocusNode(
    debugLabel: 'desktopKeymapScope',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_reclaimFocusWhenIdle);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_reclaimFocusWhenIdle);
    _scopeFocus.dispose();
    super.dispose();
  }

  /// Re-grabs focus for [_scopeFocus] when no concrete widget holds it. A real
  /// focusable (text field, button) is a leaf [FocusNode]; when focus instead
  /// rests on a [FocusScopeNode] with no focused children (or is null) nothing
  /// is truly focused, so we pull it back into the scope without stealing from
  /// any active widget.
  ///
  /// Focus is considered "idle" only when:
  /// 1. No widget has focus (primaryFocus is null)
  /// 2. Focus is on the framework root scope (empty focus)
  /// 3. Focus is on a [FocusScopeNode] that has no focused children (empty scope)
  /// 4. Focus is on a [FocusScopeNode] that is a descendant of our scope
  ///    (internal idle scope like an empty [FocusScope] wrapper in our subtree)
  ///
  /// We do NOT reclaim focus when a dialog, settings route, or other overlay
  /// holds focus, since those create their own focus scopes WITH focused children
  /// outside our subtree.
  void _reclaimFocusWhenIdle() {
    if (!mounted || !_scopeFocus.canRequestFocus) return;
    // Don't reclaim focus while the modal Settings overlay is open, otherwise
    // the scope steals focus back from the overlay (breaking Escape and the
    // overlay's own shortcuts, and re-exposing the chat to key events).
    if (ref.read(settingsOpenProvider)) return;
    final primary = FocusManager.instance.primaryFocus;
    final isIdle =
        primary == null ||
        primary == FocusManager.instance.rootScope ||
        _isEmptyFocusScope(primary) ||
        _isDescendantOfScopeFocus(primary);
    if (isIdle && !_scopeFocus.hasPrimaryFocus) {
      _scopeFocus.requestFocus();
    }
  }

  /// Returns true if [node] is a [FocusScopeNode] with no focused children,
  /// indicating an empty focus scope (idle focus).
  bool _isEmptyFocusScope(FocusNode node) {
    if (node is! FocusScopeNode) return false;
    return node.focusedChild == null;
  }

  /// Returns true if [node] is an empty [FocusScopeNode] that is [_scopeFocus]
  /// or a descendant of it in the focus tree. Used to distinguish internal idle
  /// scopes from external scopes (dialogs, routes) that should not have focus
  /// stolen.
  ///
  /// The [FocusScopeNode] guard is essential: a real focusable leaf (text
  /// field, button) inside our subtree is also a descendant of [_scopeFocus],
  /// and must keep its focus. Without this guard, focusing the composer would
  /// be treated as idle and immediately reclaimed, making the input impossible
  /// to type into.
  bool _isDescendantOfScopeFocus(FocusNode node) {
    if (node is! FocusScopeNode) return false;
    FocusNode? current = node;
    while (current != null) {
      if (current == _scopeFocus) return true;
      current = current.parent;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final keymap = ref.watch(keymapProvider);
    final shortcuts = <ShortcutActivator, Intent>{};
    for (final action in ShortcutAction.values) {
      if (action.scope != ShortcutScope.global) continue;
      shortcuts[keymap.chordFor(action).toActivator()] = VoidCallbackIntent(
        () => _invoke(context, ref, action),
      );
    }
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          VoidCallbackIntent: VoidCallbackAction(),
        },
        child: Focus(
          focusNode: _scopeFocus,
          autofocus: true,
          child: widget.child,
        ),
      ),
    );
  }

  void _invoke(BuildContext context, WidgetRef ref, ShortcutAction action) {
    // The Settings overlay is modal to keyboard input: while it is open, window
    // shortcuts must not leak through to the chat underneath (they could
    // collapse the sidebar or open dialogs behind the overlay). The
    // open-settings chord still toggles the overlay closed as a convenience.
    if (ref.read(settingsOpenProvider)) {
      if (action == ShortcutAction.openSettings) {
        ref.read(settingsOpenProvider.notifier).state = false;
      }
      return;
    }
    switch (action) {
      case ShortcutAction.toggleSidebar:
        ref.read(sidebarCollapsedProvider.notifier).update((v) => !v);
      case ShortcutAction.focusComposer:
        // Focus the composer of the currently active leaf pane (each leaf owns
        // its own composer FocusNode, keyed by leaf id).
        final activeLeafId = ref.read(paneTreeControllerProvider).activeLeafId;
        ref.read(desktopComposerFocusProvider(activeLeafId)).requestFocus();
      case ShortcutAction.openSettings:
        widget.onOpenSettings();
      case ShortcutAction.newSession:
        final projectId = _currentProjectId(ref);
        showNewSessionDialog(context, ref, projectId: projectId);
      case ShortcutAction.nextSession:
        _cycleSession(ref, 1);
      case ShortcutAction.previousSession:
        _cycleSession(ref, -1);
      case ShortcutAction.splitPaneVertical:
        _splitPane(context, ref, Axis.horizontal);
      case ShortcutAction.splitPaneHorizontal:
        _splitPane(context, ref, Axis.vertical);
      // Composer-scope actions are handled inside the Composer, not here.
      case ShortcutAction.sendMessage:
      case ShortcutAction.composerNewline:
        break;
    }
  }

  /// Splits the active pane and starts a new session in the SAME worktree as
  /// the current pane, landing the fresh pane directly on the harness picker.
  ///
  /// The current pane is pinned to its resolved session (explicit id, else the
  /// global selection) so it keeps its transcript. The fresh pane then shows
  /// the "Choose a harness" view for the current worktree; picking a harness
  /// and sending the first message spawns a new session in that worktree.
  ///
  /// Two cases share the same worktree:
  /// - a started session (or a selected sessionless worktree) has a real tree,
  ///   so the fresh pane binds to it directly;
  /// - an un-started draft has only a virtual (not-yet-forked) worktree, so the
  ///   split spawns a linked sibling draft; whichever sends first forks the
  ///   tree and the other reuses it (see [StoreController.spawnLinkedSession]).
  ///
  /// When there is nothing to reuse (no selection at all), fall back to the
  /// new-worktree dialog, removing the fresh pane if the dialog is cancelled.
  Future<void> _splitPane(
    BuildContext context,
    WidgetRef ref,
    Axis axis,
  ) async {
    final controller = ref.read(paneTreeControllerProvider.notifier);
    final pinned =
        controller.activeLeafSessionId ?? ref.read(selectedSessionProvider);
    final worktree = _currentWorktree(ref, pinned);
    // A pinned session that is still an un-started draft has only a virtual
    // worktree — capture it before the split so we can link a sibling to it.
    final draftId = (worktree == null && pinned != null &&
            (ref.read(sessionsProvider).byId(pinned)?.pending ?? false))
        ? pinned
        : null;
    controller.splitActive(axis, pinnedSessionId: pinned);
    if (worktree != null) {
      // Land the fresh (active) pane on the harness picker for the same
      // worktree; the new session spawns in it on the first message.
      selectWorktree(ref, worktree);
      return;
    }
    final freshId = ref.read(paneTreeControllerProvider).activeLeafId;
    if (draftId != null) {
      final messenger = ScaffoldMessenger.of(context);
      try {
        final newId = await ref
            .read(storeControllerProvider.notifier)
            .spawnLinkedSession(draftId);
        if (!mounted) return;
        selectSessionExclusive(ref, newId);
      } catch (e) {
        if (!mounted) return;
        // Spawn failed — drop the fresh pane so a failed split doesn't strand
        // an empty duplicate.
        if (ref.read(paneTreeControllerProvider).activeLeafId == freshId) {
          controller.closeActive();
        }
        messenger.showSnackBar(
          SnackBar(content: Text('Could not split session: $e')),
        );
      }
      return;
    }
    final worktreeBefore = ref.read(selectedWorktreeProvider);
    await showNewSessionDialog(context, ref, projectId: _currentProjectId(ref));
    // The scope may have unmounted while the dialog was open; bail before
    // touching providers through a potentially disposed ref.
    if (!mounted) return;
    final cancelled = identical(
      ref.read(selectedWorktreeProvider),
      worktreeBefore,
    );
    if (cancelled &&
        ref.read(paneTreeControllerProvider).activeLeafId == freshId) {
      controller.closeActive();
    }
  }

  /// The worktree the current pane sits in, derived from its resolved session
  /// (a started session carries its [Session.worktreePath] + branch), else the
  /// already-selected sessionless worktree. Null when nothing is selected or
  /// the session is a still-pending draft without a worktree yet.
  SelectedWorktree? _currentWorktree(WidgetRef ref, String? sessionId) {
    if (sessionId != null) {
      final session = ref.read(sessionsProvider).byId(sessionId);
      final path = session?.worktreePath;
      if (session != null && path != null) {
        return SelectedWorktree(
          projectId: session.projectId,
          path: path,
          branch: session.branch,
        );
      }
    }
    return ref.read(selectedWorktreeProvider);
  }

  /// Session ids in sidebar display order (repo order, then each repo's
  /// sessions), so next/previous match what the user sees.
  List<String> _orderedSessionIds(WidgetRef ref) {
    final repos = ref.read(reposProvider).repos;
    final sessions = ref.read(sessionsProvider);
    return [
      for (final repo in repos)
        for (final s in sessions.forProject(repo.id)) s.id,
    ];
  }

  String? _currentProjectId(WidgetRef ref) {
    final selected = ref.read(selectedSessionProvider);
    if (selected == null) {
      final repos = ref.read(reposProvider).repos;
      return repos.isEmpty ? null : repos.first.id;
    }
    final sessions = ref.read(sessionsProvider).sessions;
    for (final s in sessions) {
      if (s.id == selected) return s.projectId;
    }
    return null;
  }

  void _cycleSession(WidgetRef ref, int delta) {
    final ids = _orderedSessionIds(ref);
    if (ids.isEmpty) return;
    final selected = ref.read(selectedSessionProvider);
    final current = selected == null ? -1 : ids.indexOf(selected);
    // From no selection: forward → first, backward → last.
    final next = current == -1
        ? (delta > 0 ? 0 : ids.length - 1)
        : (current + delta) % ids.length;
    final wrapped = next < 0 ? next + ids.length : next;
    selectSessionExclusive(ref, ids[wrapped]);
  }
}
