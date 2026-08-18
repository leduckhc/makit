/// Riverpod wiring for the shared [PreferencesController].
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../store/models.dart';
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
///
/// Written out per entry instead of through a helper that *returns* a provider:
/// a helper called inside a provider body constructs a brand-new provider on
/// every rebuild, which Riverpod treats as a different provider each time — the
/// cache never hits and the container accumulates them.
final themeModeValueProvider = Provider<ThemeMode>((ref) {
  ref.watch(
    preferencesControllerProvider.select(
      (overrides) => overrides[themeModePreference.id],
    ),
  );
  return ref
      .read(preferencesControllerProvider.notifier)
      .get(themeModePreference);
});

/// Where pending mid-turn messages render (SPEC-pending-queue-edit-reorder). A provider (not only the
/// [PreferencesRefX] extension) so shared `ui/` reads it without importing
/// `desktop/`, on both surfaces.
final pendingQueuePlacementProvider = Provider<PendingQueuePlacement>((ref) {
  ref.watch(
    preferencesControllerProvider.select(
      (overrides) => overrides[pendingQueuePlacementPreference.id],
    ),
  );
  return ref
      .read(preferencesControllerProvider.notifier)
      .get(pendingQueuePlacementPreference);
});

/// Current UI text scale (see [textScalePreference]).
final textScaleValueProvider = Provider<double>((ref) {
  ref.watch(
    preferencesControllerProvider.select(
      (overrides) => overrides[textScalePreference.id],
    ),
  );
  return ref
      .read(preferencesControllerProvider.notifier)
      .get(textScalePreference);
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
