/// Riverpod wiring for the shared [PreferencesController].
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'preference.dart';
import 'preference_entries.dart';
import 'preferences_controller.dart';

/// The active preferences. Defaults to a non-persisting controller;
/// `runDesktopApp` and the mobile `main` override it with a
/// [SharedPreferences]-backed one, and tests may override it too. The state is
/// the diff-only overrides map.
final preferencesControllerProvider =
    StateNotifierProvider<PreferencesController, Map<String, Object?>>(
      (ref) => PreferencesController.ephemeral(),
    );

/// Current theme mode. A provider rather than only the [PreferencesRefX]
/// extension because the app root and tests read it without a `WidgetRef`.
final themeModeValueProvider = Provider<ThemeMode>(
  (ref) => ref.watch(_valueOf(themeModePreference)),
);

/// Current UI text scale (see [textScalePreference]).
final textScaleValueProvider = Provider<double>(
  (ref) => ref.watch(_valueOf(textScalePreference)),
);

/// A provider over one [entry]'s value, rebuilding only when that entry's
/// stored value changes.
Provider<T> _valueOf<T>(PreferenceEntry<T> entry) => Provider<T>((ref) {
  ref.watch(
    preferencesControllerProvider.select((overrides) => overrides[entry.id]),
  );
  return ref.read(preferencesControllerProvider.notifier).get(entry);
});

/// Reactive, typed read of a single [entry]: rebuilds when its stored value
/// changes and returns the default while unset.
extension PreferencesRefX on WidgetRef {
  /// Watches [entry] and returns its current value.
  T preference<T>(PreferenceEntry<T> entry) {
    watch(
      preferencesControllerProvider.select((overrides) => overrides[entry.id]),
    );
    return read(preferencesControllerProvider.notifier).get(entry);
  }

  /// Watches whether [entry] differs from its default.
  bool preferenceModified<T>(PreferenceEntry<T> entry) => watch(
    preferencesControllerProvider.select(
      (overrides) => overrides.containsKey(entry.id),
    ),
  );
}
