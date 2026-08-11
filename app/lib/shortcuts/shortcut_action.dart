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

  /// Open the global Ports screen (SPEC-42 D9).
  openPorts(
    id: 'openPorts',
    label: 'Open Ports',
    description: 'Open the global Ports screen (everything, all repos)',
    scope: ShortcutScope.global,
  ),

  /// Split the active split into a left/right layout.
  splitVertical(
    id: 'splitVertical',
    label: 'Split vertically',
    description: 'Split the active split into a left/right layout',
    scope: ShortcutScope.global,
  ),

  /// Split the active split into a top/bottom layout.
  splitHorizontal(
    id: 'splitHorizontal',
    label: 'Split horizontally',
    description: 'Split the active split into a top/bottom layout',
    scope: ShortcutScope.global,
  ),

  /// Open the New session dialog for a new tab in the active split.
  newTab(
    id: 'newTab',
    label: 'New tab',
    description: 'Open the New session dialog for a tab in the active split',
    scope: ShortcutScope.global,
  ),

  /// Close the active split's view without ending its sessions.
  closeSplit(
    id: 'closeSplit',
    label: 'Close split',
    description: 'Close the active split (its sessions keep running)',
    scope: ShortcutScope.global,
  ),

  /// Close the active tab in the active split (the session keeps running).
  closeTab(
    id: 'closeTab',
    label: 'Close tab',
    description: 'Close the active tab (the session keeps running)',
    scope: ShortcutScope.global,
  ),

  /// Switch to the next tab in the active split.
  nextTab(
    id: 'nextTab',
    label: 'Next tab',
    description: 'Switch to the next tab in the active split',
    scope: ShortcutScope.global,
  ),

  /// Switch to the previous tab in the active split.
  prevTab(
    id: 'prevTab',
    label: 'Previous tab',
    description: 'Switch to the previous tab in the active split',
    scope: ShortcutScope.global,
  ),

  /// Put the newest notice on the clipboard (SPEC-49 D8).
  ///
  /// Reads the [StatusCenter] record rather than the screen, so it still works
  /// after the notice has faded — which is the half of "I cannot review what was
  /// just popping" that a card cannot answer.
  copyNewestNotice(
    id: 'copyNewestNotice',
    label: 'Copy latest notice',
    description: 'Copy the most recent status message to the clipboard',
    scope: ShortcutScope.global,
  ),

  // SPEC-30 decision 16: ⌘1…⌘9 switch to the 1st–9th group. There is
  // deliberately no action for a tenth group — no wrap-around, no "⌘9 = last";
  // groups past the ninth are reached by clicking or scrolling the rail.
  /// Switch to the 1st group in the group bar.
  switchGroup1(
    id: 'switchGroup1',
    label: 'Switch to group 1',
    description: 'Activate the 1st group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 2nd group in the group bar.
  switchGroup2(
    id: 'switchGroup2',
    label: 'Switch to group 2',
    description: 'Activate the 2nd group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 3rd group in the group bar.
  switchGroup3(
    id: 'switchGroup3',
    label: 'Switch to group 3',
    description: 'Activate the 3rd group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 4th group in the group bar.
  switchGroup4(
    id: 'switchGroup4',
    label: 'Switch to group 4',
    description: 'Activate the 4th group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 5th group in the group bar.
  switchGroup5(
    id: 'switchGroup5',
    label: 'Switch to group 5',
    description: 'Activate the 5th group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 6th group in the group bar.
  switchGroup6(
    id: 'switchGroup6',
    label: 'Switch to group 6',
    description: 'Activate the 6th group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 7th group in the group bar.
  switchGroup7(
    id: 'switchGroup7',
    label: 'Switch to group 7',
    description: 'Activate the 7th group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 8th group in the group bar.
  switchGroup8(
    id: 'switchGroup8',
    label: 'Switch to group 8',
    description: 'Activate the 8th group in the group bar',
    scope: ShortcutScope.global,
  ),

  /// Switch to the 9th group in the group bar.
  switchGroup9(
    id: 'switchGroup9',
    label: 'Switch to group 9',
    description: 'Activate the 9th group in the group bar',
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

  /// The 1st–9th group-switch actions, indexed 0–8 (SPEC-30 decision 16).
  static const List<ShortcutAction> _switchGroupActions = [
    switchGroup1,
    switchGroup2,
    switchGroup3,
    switchGroup4,
    switchGroup5,
    switchGroup6,
    switchGroup7,
    switchGroup8,
    switchGroup9,
  ];

  /// The group-switch action for the [index]th group (0-based), or null past
  /// the ninth — the tenth group onward has no shortcut (decision 16).
  static ShortcutAction? switchGroupAtIndex(int index) =>
      (index < 0 || index >= _switchGroupActions.length)
      ? null
      : _switchGroupActions[index];

  /// The 0-based group index this action switches to, or null when it is not a
  /// group-switch action.
  int? get groupIndex {
    final i = _switchGroupActions.indexOf(this);
    return i < 0 ? null : i;
  }
}

/// The focus context an action applies to. Global actions are installed at the
/// window root; composer actions only fire while the message field has focus.
enum ShortcutScope { global, composer }
