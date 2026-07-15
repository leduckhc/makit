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
);

/// Every entry known to the app. Extend this list to register new preferences;
/// nothing else needs to change to persist them.
const List<PreferenceEntry<Object?>> kPreferenceEntries = [
  themeModePreference,
  notificationsReminderDelayPreference,
  lastSectionPreference,
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
