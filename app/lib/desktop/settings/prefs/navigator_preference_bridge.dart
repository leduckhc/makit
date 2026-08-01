/// Bridges the desktop preference system to the shared message-navigator
/// providers (SPEC-34).
///
/// Shared `ui/` code must not import `desktop/`, so the style and the per-style
/// options reach the transcript as plain provider *values* that the desktop app
/// root overrides with the user's stored preferences. This file is that bridge —
/// and the only place that knows both sides.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ui/session/navigator/navigator_style.dart';
import 'preference.dart';
import 'preference_entries.dart';
import 'preferences_providers.dart';

/// Reads [entry] from the active controller and rebuilds when it changes.
T _watch<T>(Ref ref, PreferenceEntry<T> entry) {
  ref.watch(
    preferencesControllerProvider.select((overrides) => overrides[entry.id]),
  );
  return ref.read(preferencesControllerProvider.notifier).get(entry);
}

/// The stored navigator style. The desktop `ProviderScope` overrides the shared
/// [messageNavigatorStyleProvider] with this.
final desktopNavigatorStyleProvider = Provider<MessageNavigatorStyle>(
  (ref) => _watch(ref, messageNavigatorStylePreference),
);

/// The stored breadcrumb options.
final desktopBreadcrumbOptionsProvider = Provider<BreadcrumbOptions>(
  (ref) => BreadcrumbOptions(
    autoHide: _watch(ref, crumbAutoHidePreference),
    counter: _watch(ref, crumbCounterPreference),
  ),
);

/// The stored palette options.
final desktopPaletteOptionsProvider = Provider<PaletteOptions>(
  (ref) => PaletteOptions(searchAll: _watch(ref, paletteSearchAllPreference)),
);

/// The stored outline options.
final desktopOutlineOptionsProvider = Provider<OutlineOptions>(
  (ref) => OutlineOptions(
    hideTools: _watch(ref, outlineHideToolsPreference),
    showCounts: _watch(ref, outlineShowCountsPreference),
  ),
);

/// The stored rail options, for overriding the shared [railOptionsProvider].
final desktopRailOptionsProvider = Provider<RailOptions>(
  (ref) => RailOptions(
    spacing: _watch(ref, railTickSpacingPreference),
    ripple: _watch(ref, railRipplePreference),
    encodeLength: _watch(ref, railEncodeLengthPreference),
  ),
);
