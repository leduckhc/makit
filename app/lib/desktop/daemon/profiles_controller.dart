/// Observable state around [ProfileRegistry] for the Profiles UI.
///
/// The registry itself is a plain, synchronous value object — deliberately, so it
/// can be unit-tested without Flutter. This controller is the thin observable
/// layer over it: it persists after every mutation (a profile the user named but
/// which vanished on relaunch would be worse than no profiles at all) and
/// notifies listeners so the list repaints.
///
/// It also owns the per-profile *runtime* facts the registry cannot know —
/// whether a daemon is up, and how much disk the profile occupies — because those
/// are observations of the world, not persisted configuration.
library;

import 'package:flutter/foundation.dart';

import 'profile_registry.dart';
import 'server_profile.dart';

/// A profile plus the live facts the UI shows beside it.
@immutable
class ProfileStatus {
  /// Creates a status row.
  const ProfileStatus({
    required this.profile,
    required this.running,
    this.diskBytes,
    this.stale = false,
  });

  /// The profile this describes.
  final ServerProfile profile;

  /// Whether its daemon is currently up.
  final bool running;

  /// Recursive size of its `MAKIT_HOME`, or `null` while unmeasured.
  ///
  /// Nullable rather than `0` so the UI can say "measuring" instead of lying
  /// about an empty profile.
  final int? diskBytes;

  /// Whether this is a dev profile whose origin folder has gone (SPEC-50 D9).
  final bool stale;

  @override
  bool operator ==(Object other) =>
      other is ProfileStatus &&
      other.profile == profile &&
      other.running == running &&
      other.diskBytes == diskBytes &&
      other.stale == stale;

  @override
  int get hashCode => Object.hash(profile, running, diskBytes, stale);
}

/// Reads whether a profile's daemon is up. Injected so tests spawn nothing.
typedef RunningProbe = Future<bool> Function(ServerProfile profile);

/// Measures a profile's on-disk size. Injected so tests touch no filesystem.
typedef DiskProbe = Future<int> Function(ServerProfile profile);

/// Drives the Profiles settings section.
class ProfilesController extends ChangeNotifier {
  /// Creates a controller over [registry], reporting [activeProfileId] as active.
  ProfilesController({
    required ProfileRegistry registry,
    required this.activeProfileId,
    RunningProbe? isRunning,
    DiskProbe? diskUsage,
    bool Function(String path)? dirExists,
  }) : _registry = registry,
       _isRunning = isRunning,
       _diskUsage = diskUsage,
       _dirExists = dirExists;

  final ProfileRegistry _registry;
  final RunningProbe? _isRunning;
  final DiskProbe? _diskUsage;
  final bool Function(String path)? _dirExists;

  /// The id of the profile this window is currently connected to.
  final String activeProfileId;

  final Map<String, bool> _running = {};
  final Map<String, int> _disk = {};

  /// The registry behind this controller, for callers that need the raw model.
  ProfileRegistry get registry => _registry;

  /// The profile this window runs against, or `null` if the registry lost it.
  ServerProfile? get active => _registry.byId(activeProfileId);

  /// Every profile with its live status, active profile first, then user
  /// profiles, then dev ones — the order the user thinks in.
  List<ProfileStatus> get rows {
    final stale = {
      for (final p in _registry.staleProfiles(dirExists: _dirExists)) p.id,
    };
    final list = [
      for (final p in _registry.profiles)
        ProfileStatus(
          profile: p,
          running: _running[p.id] ?? false,
          diskBytes: _disk[p.id],
          stale: stale.contains(p.id),
        ),
    ];
    list.sort((a, b) {
      if (a.profile.id == activeProfileId) return -1;
      if (b.profile.id == activeProfileId) return 1;
      final byKind = a.profile.kind.index.compareTo(b.profile.kind.index);
      if (byKind != 0) return byKind;
      return a.profile.name.toLowerCase().compareTo(
        b.profile.name.toLowerCase(),
      );
    });
    return list;
  }

  /// The stale dev profiles, and their combined measured size.
  ///
  /// The count is the honest headline, not the bytes: each stale profile still
  /// holds a device pairing and a TLS keypair.
  ({List<ProfileStatus> rows, int bytes}) get staleSummary {
    final stale = rows.where((r) => r.stale).toList();
    var bytes = 0;
    for (final r in stale) {
      bytes += r.diskBytes ?? 0;
    }
    return (rows: stale, bytes: bytes);
  }

  /// Refreshes running state and disk usage for every profile.
  Future<void> refresh() async {
    final probeRunning = _isRunning;
    final probeDisk = _diskUsage;
    for (final p in _registry.profiles) {
      if (probeRunning != null) _running[p.id] = await probeRunning(p);
      if (probeDisk != null) _disk[p.id] = await probeDisk(p);
    }
    notifyListeners();
  }

  /// Creates a profile named [name] and persists it.
  ///
  /// Returns the new profile, or `null` when [name] is blank — the caller shows
  /// the validation message rather than this throwing into a button callback.
  Future<ServerProfile?> create(String name) async {
    if (name.trim().isEmpty) return null;
    final created = await _registry.createUserProfile(name: name);
    _registry.save();
    notifyListeners();
    return created;
  }

  /// Renames [id], persisting on success.
  bool rename(String id, String name) {
    if (!_registry.rename(id, name)) return false;
    _registry.save();
    notifyListeners();
    return true;
  }

  /// Drops [id] from the registry and persists.
  ///
  /// Erasing the on-disk stores is the deleter's job; this is the last step of
  /// that sequence, exposed here so the list repaints.
  bool forget(String id) {
    if (!_registry.remove(id)) return false;
    _registry.save();
    notifyListeners();
    return true;
  }

  /// Records an observed running state without a full [refresh].
  void noteRunning(String id, {required bool running}) {
    _running[id] = running;
    notifyListeners();
  }

  /// Repaints the list after the registry changed underneath it.
  ///
  /// Needed because a delete performed elsewhere (the host, after a
  /// switch-away-and-delete) mutates the shared registry directly, and
  /// `notifyListeners` is protected to subclasses.
  void notifyRegistryChanged() => notifyListeners();
}
