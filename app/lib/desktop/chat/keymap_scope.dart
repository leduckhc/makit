import 'package:flutter/material.dart' hide Tab;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/store.dart';
import 'composer_focus.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'new_worktree_dialog.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';
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
        // Focus the composer of the active split's active tab (each tab owns
        // its own composer FocusNode, keyed by tab id).
        final tab = activeTab(ref.read(workspaceControllerProvider));
        if (tab != null) {
          ref.read(desktopComposerFocusProvider(tab.id)).requestFocus();
        }
      case ShortcutAction.openSettings:
        widget.onOpenSettings();
      case ShortcutAction.newSession:
        showNewWorktreeDialog(context, ref, projectId: _currentProjectId(ref));
      case ShortcutAction.nextSession:
        _cycleSession(ref, 1);
      case ShortcutAction.previousSession:
        _cycleSession(ref, -1);
      case ShortcutAction.splitVertical:
        _divide(context, ref, Axis.horizontal);
      case ShortcutAction.splitHorizontal:
        _divide(context, ref, Axis.vertical);
      case ShortcutAction.newTab:
        _newTab(context, ref);
      case ShortcutAction.closeSplit:
        closeActiveSplit(ref);
      case ShortcutAction.closeTab:
        closeActiveTab(ref);
      case ShortcutAction.nextTab:
        _cycleTab(ref, 1);
      case ShortcutAction.prevTab:
        _cycleTab(ref, -1);
      // SPEC-30 decision 16: ⌘1…⌘9 activate the 1st–9th group. A tenth group
      // has no binding, so it is only reachable by click or scroll.
      case ShortcutAction.switchGroup1:
      case ShortcutAction.switchGroup2:
      case ShortcutAction.switchGroup3:
      case ShortcutAction.switchGroup4:
      case ShortcutAction.switchGroup5:
      case ShortcutAction.switchGroup6:
      case ShortcutAction.switchGroup7:
      case ShortcutAction.switchGroup8:
      case ShortcutAction.switchGroup9:
        _switchToGroup(ref, action.groupIndex!);
      // Composer-scope actions are handled inside the Composer, not here.
      case ShortcutAction.sendMessage:
      case ShortcutAction.composerNewline:
        break;
    }
  }

  /// Activates the [index]th group (0-based) when it exists; a no-op otherwise,
  /// so a shortcut for a group that isn't there does nothing rather than
  /// wrapping around (SPEC-30 decision 16).
  void _switchToGroup(WidgetRef ref, int index) {
    final groups = ref.read(groupsControllerProvider).groups;
    if (index >= groups.length) return;
    ref.read(groupsControllerProvider.notifier).activate(groups[index].id);
  }

  /// Group-aware split (SPEC-30 decision 13). In a **worktree group** the branch
  /// already answers "where does it run?", so the new split is seeded with the
  /// group's scope and lands on the harness picker — **never a dialog**. On a
  /// **board** there is no scope, so it asks first with the New-worktree dialog
  /// and the confirmed worktree lands in the new split.
  void _divide(BuildContext context, WidgetRef ref, Axis axis) {
    final hint = _groupWorktreeHint(ref.read(activeGroupProvider));
    if (hint != null) {
      ref
          .read(workspaceControllerProvider.notifier)
          .divideActive(axis, worktree: hint);
      return;
    }
    // Pin the group the request came from: `workspaceControllerProvider` is
    // rebuilt whenever the active group changes, so placing into "whatever is
    // active when the dialog closes" could split a group the user never asked
    // about (they can switch groups with ⌘1–9 while it is open).
    final requestedGroup = ref.read(groupsControllerProvider).active.id;
    showNewWorktreeDialog(
      context,
      ref,
      projectId: _currentProjectId(ref),
      activateGroup: false,
    ).then((worktree) {
      if (worktree == null) return;
      final groups = ref.read(groupsControllerProvider.notifier);
      if (ref.read(groupsControllerProvider).active.id != requestedGroup) {
        groups.activate(requestedGroup);
      }
      ref
          .read(workspaceControllerProvider.notifier)
          .divideActive(axis, worktree: worktree);
    });
  }

  /// Group-aware new tab (SPEC-30 decision 13). A **worktree group** adds a tab
  /// hinted with the group's scope — the harness picker, no dialog. A **board**
  /// asks with the New-worktree dialog first, then opens the confirmed worktree
  /// as a new tab in the active split.
  void _newTab(BuildContext context, WidgetRef ref) {
    final hint = _groupWorktreeHint(ref.read(activeGroupProvider));
    if (hint != null) {
      final activeSplitId = ref.read(workspaceControllerProvider).activeSplitId;
      ref
          .read(workspaceControllerProvider.notifier)
          .openTab(
            activeSplitId,
            Tab(id: nextNodeId(SplitNodeKind.tab), worktree: hint),
          );
      return;
    }
    // Same reasoning as _divide: pin the group the request came from, since the
    // user can switch groups while the dialog is open.
    final requestedGroup = ref.read(groupsControllerProvider).active.id;
    showNewWorktreeDialog(
      context,
      ref,
      projectId: _currentProjectId(ref),
      activateGroup: false,
    ).then((worktree) {
      if (worktree == null) return;
      final groups = ref.read(groupsControllerProvider.notifier);
      if (ref.read(groupsControllerProvider).active.id != requestedGroup) {
        groups.activate(requestedGroup);
      }
      final activeSplitId = ref.read(workspaceControllerProvider).activeSplitId;
      ref
          .read(workspaceControllerProvider.notifier)
          .openTab(
            activeSplitId,
            Tab(id: nextNodeId(SplitNodeKind.tab), worktree: worktree),
          );
    });
  }

  /// The scope of a worktree [group] as a tab hint. Null for a board, which
  /// owns no scope — a worktree group always carries both halves.
  SelectedWorktree? _groupWorktreeHint(Group group) {
    if (group.kind != GroupKind.worktree) return null;
    final projectId = group.projectId;
    final path = group.worktreePath;
    if (projectId == null || path == null) return null;
    return SelectedWorktree(
      projectId: projectId,
      path: path,
      branch: group.label,
    );
  }

  /// Cycles the active split's active tab by [delta] (wrapping). No-op when the
  /// active split has a single tab.
  void _cycleTab(WidgetRef ref, int delta) {
    final state = ref.read(workspaceControllerProvider);
    final split = firstSplitWhere(
      state.root,
      (s) => s.id == state.activeSplitId ? s : null,
    );
    if (split == null || split.tabs.length < 2) return;
    final index = split.tabs.indexWhere((t) => t.id == split.activeTabId);
    if (index < 0) return;
    // Dart's `%` returns a non-negative result for a positive divisor, so this
    // already wraps correctly for delta = ±1.
    final next = (index + delta) % split.tabs.length;
    ref
        .read(workspaceControllerProvider.notifier)
        .setActiveTab(split.id, split.tabs[next].id);
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
