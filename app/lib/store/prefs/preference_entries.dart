/// Concrete [PreferenceEntry] declarations for the desktop settings.
///
/// This is the central, extensible list of stored desktop preferences. Wave 2
/// agents add a setting by declaring a new `const` entry here (plus a control
/// in the owning section body) — no controller or provider changes required.
library;

import 'package:flutter/material.dart' show ThemeMode;

import '../models.dart' show PendingQueuePlacement;
import '../../../ui/session/navigator/navigator_style.dart';
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

/// User override for the "Commit and push" canned prompt (empty = built-in).
const PreferenceEntry<String> prCommitPushPromptPreference = PreferenceEntry(
  id: 'chat.prPrompt.commitPush',
  defaultValue: '',
  encode: _encodeString,
  decode: _decodeString,
);

/// User override for the "Push" canned prompt (empty = built-in).
const PreferenceEntry<String> prPushPromptPreference = PreferenceEntry(
  id: 'chat.prPrompt.push',
  defaultValue: '',
  encode: _encodeString,
  decode: _decodeString,
);

const PreferenceEntry<String> prPullPromptPreference = PreferenceEntry(
  id: 'chat.prPrompt.pull',
  defaultValue: '',
  encode: _encodeString,
  decode: _decodeString,
);

/// Whether the GitHub API budget popover's "Burn history" detail is expanded.
/// Backs the popover's in-place expander so the user's choice survives opens
/// and restarts (SPEC-32 §7.2). Internal bookkeeping — a remembered UI state,
/// not a user-facing setting.
const PreferenceEntry<bool> budgetHistoryExpandedPreference = PreferenceEntry(
  id: 'chat.budgetHistoryExpanded',
  defaultValue: false,
  encode: _encodeBool,
  decode: _decodeBool,
  internal: true,
);

/// Whether the metrics popover's "History" detail is expanded. Same role as
/// [budgetHistoryExpandedPreference] for the sibling footer popover (SPEC-37
/// Tier 1): a remembered UI state, not a user-facing setting.
const PreferenceEntry<bool> metricsHistoryExpandedPreference = PreferenceEntry(
  id: 'chat.metricsHistoryExpanded',
  defaultValue: false,
  encode: _encodeBool,
  decode: _decodeBool,
  internal: true,
);

/// How many agents a group opens side by side before it starts placing new ones
/// as tabs (SPEC-30 decision 9). A **placement policy**, not a rendering mode:
/// changing it never re-arranges a group the user already arranged — it only
/// decides where the *next* session lands in groups with no manual override.
const PreferenceEntry<int> autoSplitThresholdPreference = PreferenceEntry(
  id: 'layout.autoSplitThreshold',
  defaultValue: 3,
  encode: _encodeInt,
  decode: _decodeInt,
);

/// SPEC-34 — whether the **desktop** transcript renders the message rail. Mobile
/// does not read this (it reaches its messages through a sheet instead; see
/// `messageNavigatorStyleProvider`), so this is a desktop-only preference.
const PreferenceEntry<MessageNavigatorStyle> messageNavigatorStylePreference =
    PreferenceEntry(
      id: 'chat.navigator.style',
      defaultValue: MessageNavigatorStyle.rail,
      encode: _encodeNavigatorStyle,
      decode: _decodeNavigatorStyle,
    );

/// Where a session's pending mid-turn messages render (SPEC-38). Read by BOTH
/// surfaces, unlike the navigator style: a phone is exactly where a queue
/// matters, so this is not a desktop-only preference.
///
/// Default [PendingQueuePlacement.pinned] — the floor that keeps a pending
/// message visible however far the transcript is scrolled.
const PreferenceEntry<PendingQueuePlacement> pendingQueuePlacementPreference =
    PreferenceEntry(
      id: 'chat.queue.placement',
      defaultValue: PendingQueuePlacement.pinned,
      encode: _encodeQueuePlacement,
      decode: _decodeQueuePlacement,
    );

/// Gap between the rail's ticks, in logical pixels: 6 (cosy) / 10 / 14 (roomy).
/// A plain `int` rather than an enum so a future value needs no migration.
const PreferenceEntry<int> railTickSpacingPreference = PreferenceEntry(
  id: 'chat.navigator.rail.spacing',
  defaultValue: 6,
  encode: _encodeInt,
  decode: _decodeInt,
);

/// Whether hovering the rail ripples its neighbours (width + vertical push).
const PreferenceEntry<bool> railRipplePreference = PreferenceEntry(
  id: 'chat.navigator.rail.ripple',
  defaultValue: true,
  encode: _encodeBool,
  decode: _decodeBool,
);

/// Whether a tick's length encodes its message's length (a session fingerprint).
const PreferenceEntry<bool> railEncodeLengthPreference = PreferenceEntry(
  id: 'chat.navigator.rail.encodeLength',
  defaultValue: true,
  encode: _encodeBool,
  decode: _decodeBool,
);

/// Every entry known to the app. Extend this list to register new preferences;
/// nothing else needs to change to persist them.
const List<PreferenceEntry<Object?>> kPreferenceEntries = [
  themeModePreference,
  notificationsReminderDelayPreference,
  lastSectionPreference,
  sidebarWidthPreference,
  sidebarStartCollapsedPreference,
  autoSplitThresholdPreference,
  textScalePreference,
  preferredIdePreference,
  lastPrActionPreference,
  prCreatePromptPreference,
  prFixPromptPreference,
  prResolveCommentsPromptPreference,
  prCommitPushPromptPreference,
  prPushPromptPreference,
  prPullPromptPreference,
  budgetHistoryExpandedPreference,
  metricsHistoryExpandedPreference,
  messageNavigatorStylePreference,
  pendingQueuePlacementPreference,
  railTickSpacingPreference,
  railRipplePreference,
  railEncodeLengthPreference,
];

Object? _encodeQueuePlacement(PendingQueuePlacement value) => value.name;

/// Returns `null` for an unknown or wrong-typed name so the controller falls
/// back to the default — a downgrade can never leave a pending message with
/// nowhere to render.
PendingQueuePlacement? _decodeQueuePlacement(Object? json) {
  if (json is! String) return null;
  for (final placement in PendingQueuePlacement.values) {
    if (placement.name == json) return placement;
  }
  return null;
}

Object? _encodeNavigatorStyle(MessageNavigatorStyle value) => value.name;

/// Returns `null` for an unknown or wrong-typed name so the controller falls
/// back to the default — a downgrade, or a style removed later, can never
/// corrupt the chat pane.
MessageNavigatorStyle? _decodeNavigatorStyle(Object? json) {
  if (json is! String) return null;
  for (final style in MessageNavigatorStyle.values) {
    if (style.name == json) return style;
  }
  return null;
}

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
