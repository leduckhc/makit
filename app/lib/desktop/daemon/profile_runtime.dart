/// Everything that belongs to ONE profile, behind one disposable object.
///
/// Exists so a second one can be built at runtime: switching profiles inside a
/// running window (SPEC-50 D10) means standing up a whole parallel set of
/// per-profile objects — control client, daemon controller, scoped preference
/// controllers, lifecycle and deleter — and tearing the old set down. Leaving
/// that list inline in `runDesktopApp` made it impossible to have two.
///
/// The [overrides] getter returns a list *literal* rather than a typed field on
/// purpose: Riverpod does not export the `Override` base type, so naming it does
/// not compile. Inference handles it.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../control/control_client.dart';
import '../../control/reconnecting_control_client.dart';
import '../../store/prefs/profile_scoped_prefs.dart';
import '../chat/groups/groups_controller.dart';
import '../desktop_controller.dart';
import '../settings/server_config.dart';
import 'daemon_lifecycle.dart';
import 'profile_deleter.dart';
import 'profile_lifecycle.dart';
import 'profile_registry.dart';
import 'profiles_controller.dart';
import 'server_profile.dart';

/// Confirms [target] is reachable, and only then calls [handOver].
///
/// The order is the entire safety property of a profile switch (SPEC-50 D10):
/// the target is started and confirmed *answering* while the current profile is
/// still live, so a target that cannot come up leaves the window exactly as it
/// was. [handOver] performs the irreversible part — build the new runtime, swap
/// it in, dispose the old — and is called at most once, never on a failure.
///
/// Extracted from the widget that owns the `ProviderScope` so this sequence can
/// be tested without a widget tree; that scope swap is untestable in a unit test,
/// but the decision of *whether* to swap is the part that can go wrong.
Future<String?> verifyThenHandOver({
  required ServerProfile target,
  required ProfileLifecycle lifecycle,
  required Future<void> Function() handOver,
}) async {
  if (!await lifecycle.isRunning(target)) {
    final started = await lifecycle.start(target);
    if (!started.ok) {
      // Always name the profile. The CLI's own message can be as bare as
      // "makit start exited 1", and this string is sometimes surfaced on its own
      // (folded into the switch-away-and-delete report), where an unnamed
      // failure tells the user nothing.
      final why = started.message;
      return (why == null || why.trim().isEmpty)
          ? 'could not start “${target.name}”'
          : 'could not start “${target.name}”: ${why.trim()}';
    }
    if (!await lifecycle.isRunning(target)) {
      return '“${target.name}” started but is not answering on its control '
          'socket';
    }
  }
  await handOver();
  return null;
}

/// The per-profile half of the app's object graph.
class ProfileRuntime {
  ProfileRuntime._({
    required this.profile,
    required this.registry,
    required this.client,
    required this.controller,
    required this.configController,
    required this.groupsController,
    required this.profileLifecycle,
    required this.profileDeleter,
    required this.profilesController,
  });

  /// Builds the runtime for [profile].
  ///
  /// Synchronous by design: every dependency is constructed, none is awaited, so
  /// a switch cannot leave the app half-built while a future settles.
  factory ProfileRuntime.create({
    required ServerProfile profile,
    required ProfileRegistry registry,
    required SharedPreferences prefs,
  }) {
    final socketPath = profile.controlSocketPath;
    final client = ReconnectingControlClient(
      create: () => MakitControlClient(socketPath: socketPath),
      connect: (c) => (c as MakitControlClient).connect(),
      dispose: (c) => (c as MakitControlClient).dispose(),
    );

    // Namespace only SERVER-BOUND preferences per profile (SPEC-50 D11): server
    // config, groups, and the pane layouts groups persist. Appearance,
    // shortcuts, recent models and cached commands are user-level and stay
    // SHARED — the old blanket `SharedPreferences.setPrefix` is why a worktree
    // build opened with a default theme and empty shortcuts. Because the plugin
    // composes keys by plain concatenation, `prefsKeyPrefix` lands on the
    // byte-identical key `setPrefix` produced, so there is no migration.
    final scoped = ProfileScopedPrefs(prefs, profile.prefsKeyPrefix);
    final configController = ServerConfigController(
      scoped,
      ServerConfigController.load(scoped, defaultPort: profile.port),
      defaultPort: profile.port,
    );

    final controller = DesktopController(
      client: client,
      lifecycle: DaemonLifecycle(
        resolver: MakitCliResolver(
          // Read live, so a settings change takes effect without a restart.
          overridePath: () => configController.current.cliPath,
        ),
        // MAKIT_HOME so the spawned daemon writes its socket/pid/db under this
        // profile's home — matching the control socket the client connects to.
        environment: profile.environment,
      ),
      serveArgs: () => configController.current.serveArgs(),
    );

    // Lifecycle actions may target ANY profile, not just this one, so the CLI
    // path and endpoint arguments are resolved per target from that profile's
    // own scoped config. Using the active profile's values started a target on
    // the wrong binary and on the CLI's default port instead of its allocated
    // one (colliding with the legacy daemon).
    ServerConfig configFor(ServerProfile target) => identical(target, profile)
        ? configController.current
        : ServerConfigController.load(
            ProfileScopedPrefs(prefs, target.prefsKeyPrefix),
            defaultPort: target.port,
          );

    final profileLifecycle = ProfileLifecycle(
      resolver: MakitCliResolver(
        overridePath: () => configController.current.cliPath,
      ),
      cliPathFor: (target) => configFor(target).cliPath,
      serveArgsFor: (target) => configFor(target).serveArgs(),
    );
    // All three share ONE registry instance: the deleter removes the entry
    // directly and the controller repaints from the same list, so two copies
    // would show a profile that no longer exists.
    final profileDeleter = ProfileDeleter(
      registry: registry,
      lifecycle: profileLifecycle,
      activeProfileId: profile.id,
      // Store (3): a NON-active profile's keys are reachable now that prefs are
      // scoped by key prefix rather than the global setPrefix, so the deleter can
      // actually purge them instead of always reporting them skipped.
      purgePrefs: (target) =>
          ProfileScopedPrefs(prefs, target.prefsKeyPrefix).clearScope(),
    );

    return ProfileRuntime._(
      profile: profile,
      registry: registry,
      client: client,
      controller: controller,
      configController: configController,
      groupsController: GroupsController.load(scoped),
      profileLifecycle: profileLifecycle,
      profileDeleter: profileDeleter,
      profilesController: ProfilesController(
        registry: registry,
        activeProfileId: profile.id,
        isRunning: profileLifecycle.isRunning,
        diskUsage: profileDeleter.diskUsage,
      ),
    );
  }

  /// The profile this runtime serves.
  final ServerProfile profile;

  /// The shared registry (not per-profile; held for convenience).
  final ProfileRegistry registry;

  /// This profile's control-socket client.
  final ReconnectingControlClient client;

  /// This profile's daemon controller (owns the poll timer).
  final DesktopController controller;

  /// Server config, read from this profile's scoped preferences.
  final ServerConfigController configController;

  /// Groups + pane layouts, from this profile's scoped preferences.
  final GroupsController groupsController;

  /// Starts/stops any profile's daemon.
  final ProfileLifecycle profileLifecycle;

  /// Erases a profile across its four stores.
  final ProfileDeleter profileDeleter;

  /// Observable state for the Profiles list.
  final ProfilesController profilesController;

  /// Begins polling the daemon so state stays fresh whether it was started by
  /// the app, the CLI, or died underneath us.
  void startPolling() => controller.startPolling();

  /// Tears the runtime down.
  ///
  /// Order matters: the controller's poll timer is cancelled *before* the client
  /// closes, because a poll firing against a closed client throws.
  ///
  /// [profilesController] is disposed here because it is injected via
  /// `overrideWithValue` (see `desktop_app.dart`), which Riverpod does **not**
  /// dispose — without this it leaks one listened-to controller per profile
  /// switch. `configController` and `groupsController` use `overrideWith`, whose
  /// created value Riverpod does dispose, so they are not touched here.
  Future<void> dispose() async {
    controller.dispose();
    profilesController.dispose();
    await client.close();
  }
}
