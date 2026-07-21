/// Concrete [PreferenceEntry] declarations for the desktop settings.
///
/// This is the central, extensible list of stored desktop preferences. Wave 2
/// agents add a setting by declaring a new `const` entry here (plus a control
/// in the owning section body) — no controller or provider changes required.
library;

import 'package:flutter/material.dart' show ThemeMode;

import 'preference.dart';

/// App theme: System / Light / Dark. Drives `MaterialApp.themeMode`.
const PreferenceEntry<ThemeMode> themeModePreference = PreferenceEntry(
  id: 'appearance.themeMode',
  defaultValue: ThemeMode.system,
  encode: _encodeThemeMode,
  decode: _decodeThemeMode,
);

/// Desktop notification reminder delay, in whole minutes. When a server
/// request goes unanswered for this long the desktop fires a system
/// notification as a nudge (see `SrvRequestHandler.reminderDelay`). Default: 2.
const PreferenceEntry<int> notificationsReminderDelayPreference =
    PreferenceEntry(
      id: 'notifications.reminderDelayMinutes',
      defaultValue: 2,
      encode: _encodeInt,
      decode: _decodeInt,
    );

/// The section id shown when the Settings window last closed, so reopening
/// restores the same spot. Defaults to the first section (`general`).
const PreferenceEntry<String> lastSectionPreference = PreferenceEntry(
  id: 'settings.lastSection',
  defaultValue: 'general',
  encode: _encodeString,
  decode: _decodeString,
  internal: true,
);

/// Default desktop sidebar width, in logical pixels. Backs the in-memory
/// `sidebarWidthProvider` so a resized sidebar survives restarts. The default
/// mirrors `kSidebarDefaultWidth` (320); values are clamped to the sidebar's
/// min/max at the call sites.
const PreferenceEntry<double> sidebarWidthPreference = PreferenceEntry(
  id: 'layout.sidebarWidth',
  defaultValue: 320,
  encode: _encodeDouble,
  decode: _decodeDouble,
);

/// Whether the desktop sidebar starts folded away. Backs the in-memory
/// `sidebarCollapsedProvider` so the fold state survives restarts.
const PreferenceEntry<bool> sidebarStartCollapsedPreference = PreferenceEntry(
  id: 'layout.startCollapsed',
  defaultValue: false,
  encode: _encodeBool,
  decode: _decodeBool,
);

/// UI text scale applied via `MediaQuery.textScaler` in `desktop_app.dart`.
/// 1.0 is the system default; the slider offers a 0.9–1.3 range.
const PreferenceEntry<double> textScalePreference = PreferenceEntry(
  id: 'appearance.textScale',
  defaultValue: 1,
  encode: _encodeDouble,
  decode: _decodeDouble,
);

/// The editor the title-bar "Open in…" split button opens by default — the last
/// one the user picked from its dropdown. Stored as an [IdeTarget] name; the
/// button falls back to VS Code for an unknown/legacy value. Internal
/// bookkeeping (a remembered choice, not a user-facing setting).
const PreferenceEntry<String> preferredIdePreference = PreferenceEntry(
  id: 'chat.preferredIde',
  defaultValue: 'vscode',
  encode: _encodeString,
  decode: _decodeString,
  internal: true,
);

/// The last PR action the composer's "PR actions" split button ran, so its
/// main segment repeats it. Stored as a [PrPromptAction] name; falls back to
/// the first action for an unknown/legacy value. Internal bookkeeping.
const PreferenceEntry<String> lastPrActionPreference = PreferenceEntry(
  id: 'chat.lastPrAction',
  defaultValue: 'createPr',
  encode: _encodeString,
  decode: _decodeString,
  internal: true,
);

/// User override for the "Create PR" canned prompt. Empty string means "use the
/// built-in default" (see `pr_actions.dart`), so the built-in can evolve
/// without stomping a user's edit or vice-versa.
const PreferenceEntry<String> prCreatePromptPreference = PreferenceEntry(
  id: 'chat.prPrompt.create',
  defaultValue: '',
  encode: _encodeString,
  decode: _decodeString,
);

/// User override for the "Fix PR" canned prompt (empty = built-in default).
const PreferenceEntry<String> prFixPromptPreference = PreferenceEntry(
  id: 'chat.prPrompt.fix',
  defaultValue: '',
  encode: _encodeString,
  decode: _decodeString,
);

/// User override for the "Resolve comments" canned prompt (empty = built-in).
const PreferenceEntry<String> prResolveCommentsPromptPreference =
    PreferenceEntry(
      id: 'chat.prPrompt.resolveComments',
      defaultValue: '',
      encode: _encodeString,
      decode: _decodeString,
    );

/// Every entry known to the app. Extend this list to register new preferences;
/// nothing else needs to change to persist them.
const List<PreferenceEntry<Object?>> kPreferenceEntries = [
  themeModePreference,
  notificationsReminderDelayPreference,
  lastSectionPreference,
  sidebarWidthPreference,
  sidebarStartCollapsedPreference,
  textScalePreference,
  preferredIdePreference,
  lastPrActionPreference,
  prCreatePromptPreference,
  prFixPromptPreference,
  prResolveCommentsPromptPreference,
];

Object? _encodeThemeMode(ThemeMode value) => value.name;

ThemeMode? _decodeThemeMode(Object? json) {
  if (json is! String) return null;
  for (final mode in ThemeMode.values) {
    if (mode.name == json) return mode;
  }
  return null;
}

Object? _encodeString(String value) => value;

String? _decodeString(Object? json) => json is String ? json : null;

Object? _encodeInt(int value) => value;

int? _decodeInt(Object? json) => json is int ? json : null;

Object? _encodeDouble(double value) => value;

double? _decodeDouble(Object? json) => json is num ? json.toDouble() : null;

Object? _encodeBool(bool value) => value;

bool? _decodeBool(Object? json) => json is bool ? json : null;
