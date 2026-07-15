/// Riverpod wiring for the desktop [PreferencesController].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'preference.dart';
import 'preferences_controller.dart';

/// The active desktop preferences. Defaults to a non-persisting controller;
/// `runDesktopApp` overrides it with a [SharedPreferences]-backed one, and
/// tests may override it too. The state is the diff-only overrides map.
final preferencesControllerProvider =
    StateNotifierProvider<PreferencesController, Map<String, Object?>>(
      (ref) => PreferencesController.ephemeral(),
    );

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
