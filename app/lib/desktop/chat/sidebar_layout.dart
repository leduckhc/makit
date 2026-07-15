import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../settings/prefs/preference_entries.dart';
import '../settings/prefs/preferences_providers.dart';

/// Layout state for the desktop sidebar. The sidebar can be folded away
/// (fully hidden) and resized within [kSidebarMinWidth]–[kSidebarMaxWidth].
/// Both providers seed from and write through to the desktop preferences store
/// ([sidebarWidthPreference] / [sidebarStartCollapsedPreference]) so a resized
/// or folded sidebar survives restarts (SPEC-13 Appearance → Layout).

/// Smallest width the sidebar can be dragged to.
const double kSidebarMinWidth = 250;

/// Largest width the sidebar can be dragged to.
const double kSidebarMaxWidth = 450;

/// Width the sidebar opens at before the user resizes it.
const double kSidebarDefaultWidth = 320;

/// Height of the top drag strip that stands in for the hidden OS titlebar
/// (matches the standard macOS titlebar height, clearing the traffic lights).
const double kTitleBarStripHeight = 28;

/// Left inset that clears the macOS traffic-light buttons overlaying the
/// window's top-left corner — used by the sidebar fold button and, when the
/// sidebar is hidden, by the pane header's unfold button.
const double kTrafficLightInset = 90;

/// Whether the sidebar is folded away (fully hidden). Seeds from
/// [sidebarStartCollapsedPreference]; the [SidebarLayoutPrefsObserver] persists
/// changes back so the fold state survives restarts.
final sidebarCollapsedProvider = StateProvider<bool>(
  (ref) => ref
      .read(preferencesControllerProvider.notifier)
      .get(sidebarStartCollapsedPreference),
);

/// Current sidebar width in logical pixels, clamped to the min/max above.
/// Seeds from [sidebarWidthPreference]; the [SidebarLayoutPrefsObserver]
/// persists changes back.
final sidebarWidthProvider = StateProvider<double>(
  (ref) => ref
      .read(preferencesControllerProvider.notifier)
      .get(sidebarWidthPreference),
);

/// Persists sidebar layout state to the preferences store on change.
///
/// The sidebar providers are legacy [StateProvider]s mutated directly by many
/// call sites (drag handle, fold button, keymap). Rather than route every
/// mutation through the controller, this observer write-through-persists the
/// two providers whenever their value changes. Register it on the root
/// [ProviderScope]/[ProviderContainer]; the diff-only controller drops the
/// override again when a value returns to its default.
final class SidebarLayoutPrefsObserver extends ProviderObserver {
  /// Creates the observer.
  const SidebarLayoutPrefsObserver();

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final controller = context.container.read(
      preferencesControllerProvider.notifier,
    );
    if (identical(context.provider, sidebarWidthProvider) &&
        newValue is double) {
      unawaited(controller.set(sidebarWidthPreference, newValue));
    } else if (identical(context.provider, sidebarCollapsedProvider) &&
        newValue is bool) {
      unawaited(controller.set(sidebarStartCollapsedPreference, newValue));
    }
  }
}
