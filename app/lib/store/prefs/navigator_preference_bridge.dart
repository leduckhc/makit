/// Bridges stored preferences to the shared message-rail providers (SPEC-34).
///
/// The rail reads its on/off state and options as plain provider *values* that
/// an app root overrides, rather than reading `PreferenceEntry`s itself: that keeps
/// the transcript indifferent to where the values come from, and lets a surface
/// supply something else entirely (mobile supplies nothing — it has no navigator).
///
/// Only the **desktop** root wires these up today. Nothing stops mobile from
/// doing so — since the mobile-parity work the preference system lives here in
/// `store/` and both surfaces load it — mobile simply has no rail to
/// configure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/session/navigator/navigator_style.dart';
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

/// The stored rail options, for overriding the shared [railOptionsProvider].
final desktopRailOptionsProvider = Provider<RailOptions>(
  (ref) => RailOptions(
    spacing: _watch(ref, railTickSpacingPreference),
    ripple: _watch(ref, railRipplePreference),
    encodeLength: _watch(ref, railEncodeLengthPreference),
  ),
);
