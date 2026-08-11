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
