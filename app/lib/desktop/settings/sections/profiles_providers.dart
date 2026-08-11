/// Riverpod wiring for the Profiles settings section (SPEC-50 D7/D8/D9).
///
/// These three providers are the section's only dependencies. Each throws
/// [UnimplementedError] by default — following the `serverConfigProvider` /
/// `desktopControllerProvider` pattern — and is overridden in `runDesktopApp`
/// (with the process's real registry, home and active profile id) and in tests
/// (with fakes that touch no filesystem or daemon).
///
/// The wiring MUST share **one** [ProfileRegistry] instance across all three:
/// [ProfileDeleter] removes the registry entry directly, and the section then
/// calls [ProfilesController.refresh] to repaint — which only reflects the
/// removal if both read the same registry.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../daemon/profile_deleter.dart';
import '../../daemon/profile_lifecycle.dart';
import '../../daemon/profiles_controller.dart';
import '../../daemon/server_profile.dart';

/// The observable Profiles controller (list, create, rename, forget, refresh).
final profilesControllerProvider = Provider<ProfilesController>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp / tests'),
);

/// Starts and stops the daemon of an arbitrary profile (SPEC-50 D7).
final profileLifecycleProvider = Provider<ProfileLifecycle>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp / tests'),
);

/// Erases a profile across its four stores, or refuses with a reason (D8).
final profileDeleterProvider = Provider<ProfileDeleter>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp / tests'),
);

/// Switches the window to another profile, verifying the target is reachable
/// before anything is torn down (SPEC-50 D10).
///
/// Returns `null` on success, or a human-readable reason on failure — in which
/// case nothing changed. Overridden in `runDesktopApp`; tests supply a fake.
typedef ProfileSwitcher =
    Future<String?> Function(
      ServerProfile target, {
      ServerProfile? deleteAfter,
    });

/// The active [ProfileSwitcher], or `null` where switching is not wired.
///
/// Nullable with a `null` default on purpose: the title-bar badge is mounted by
/// many surfaces (and by most widget tests) that have no profile wiring at all.
/// A throwing default would turn those into crashes; instead the badge degrades
/// to a plain, calm label — which is also the honest UI when there is nothing to
/// switch to.
final profileSwitcherProvider = Provider<ProfileSwitcher?>((ref) => null);

/// The controller the title-bar switcher lists profiles from, or `null` where
/// profiles are not wired. Same reasoning as [profileSwitcherProvider].
final switcherProfilesProvider = Provider<ProfilesController?>((ref) => null);
