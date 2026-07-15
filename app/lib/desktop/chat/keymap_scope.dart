import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/store.dart';
import 'composer_focus.dart';
import 'new_session_dialog.dart';
import 'selected_session.dart';
import 'sidebar_layout.dart';

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
  /// rests on a [FocusScopeNode] (or is null) nothing is truly focused, so we
  /// pull it back into the scope without stealing from any active widget.
  void _reclaimFocusWhenIdle() {
    if (!mounted || !_scopeFocus.canRequestFocus) return;
    final primary = FocusManager.instance.primaryFocus;
    final idle = primary == null || primary is FocusScopeNode;
    if (idle && !_scopeFocus.hasPrimaryFocus) {
      _scopeFocus.requestFocus();
    }
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
    switch (action) {
      case ShortcutAction.toggleSidebar:
        ref.read(sidebarCollapsedProvider.notifier).update((v) => !v);
      case ShortcutAction.focusComposer:
        ref.read(desktopComposerFocusProvider).requestFocus();
      case ShortcutAction.openSettings:
        widget.onOpenSettings();
      case ShortcutAction.newSession:
        final projectId = _currentProjectId(ref);
        showNewSessionDialog(context, ref, projectId: projectId);
      case ShortcutAction.nextSession:
        _cycleSession(ref, 1);
      case ShortcutAction.previousSession:
        _cycleSession(ref, -1);
      // Composer-scope actions are handled inside the Composer, not here.
      case ShortcutAction.sendMessage:
      case ShortcutAction.composerNewline:
        break;
    }
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
