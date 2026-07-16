/// The named, rebindable actions the desktop app exposes to the keyboard.
///
/// Each value carries a stable [id] (used as the persistence key — never
/// rename it) plus a user-facing [label] and [description]. [scope] groups
/// actions for display and, more importantly, bounds conflict detection: two
/// actions may share a chord only if they can never be active in the same
/// focus context.
enum ShortcutAction {
  /// Send the current composer text.
  sendMessage(
    id: 'sendMessage',
    label: 'Send message',
    description: 'Send the text in the composer',
    scope: ShortcutScope.composer,
  ),

  /// Insert a newline in the composer instead of sending.
  composerNewline(
    id: 'composerNewline',
    label: 'New line in composer',
    description: 'Insert a line break without sending',
    scope: ShortcutScope.composer,
  ),

  /// Move keyboard focus into the composer text field.
  focusComposer(
    id: 'focusComposer',
    label: 'Focus composer',
    description: 'Move the cursor into the message field',
    scope: ShortcutScope.global,
  ),

  /// Start a new session / worktree.
  newSession(
    id: 'newSession',
    label: 'New session',
    description: 'Open the new-worktree dialog',
    scope: ShortcutScope.global,
  ),

  /// Show or hide the sidebar.
  toggleSidebar(
    id: 'toggleSidebar',
    label: 'Toggle sidebar',
    description: 'Show or hide the session sidebar',
    scope: ShortcutScope.global,
  ),

  /// Select the next session in the sidebar.
  nextSession(
    id: 'nextSession',
    label: 'Next session',
    description: 'Select the next session in the sidebar',
    scope: ShortcutScope.global,
  ),

  /// Select the previous session in the sidebar.
  previousSession(
    id: 'previousSession',
    label: 'Previous session',
    description: 'Select the previous session in the sidebar',
    scope: ShortcutScope.global,
  ),

  /// Open Settings.
  openSettings(
    id: 'openSettings',
    label: 'Open settings',
    description: 'Open the Settings & Server page',
    scope: ShortcutScope.global,
  ),

  /// Split the active pane into a left/right layout.
  splitPaneVertical(
    id: 'splitPaneVertical',
    label: 'Split pane vertically',
    description: 'Split the active pane into a left/right layout',
    scope: ShortcutScope.global,
  ),

  /// Split the active pane into a top/bottom layout.
  splitPaneHorizontal(
    id: 'splitPaneHorizontal',
    label: 'Split pane horizontally',
    description: 'Split the active pane into a top/bottom layout',
    scope: ShortcutScope.global,
  );

  const ShortcutAction({
    required this.id,
    required this.label,
    required this.description,
    required this.scope,
  });

  /// Stable persistence key. Do not rename.
  final String id;

  /// User-facing name shown in the settings list.
  final String label;

  /// One-line explanation shown under the label.
  final String description;

  /// Which focus context the action lives in.
  final ShortcutScope scope;

  /// Looks up an action by its [id], or null when unknown (e.g. a persisted
  /// override from a newer/older build).
  static ShortcutAction? byId(String id) {
    for (final a in values) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// The focus context an action applies to. Global actions are installed at the
/// window root; composer actions only fire while the message field has focus.
enum ShortcutScope { global, composer }
