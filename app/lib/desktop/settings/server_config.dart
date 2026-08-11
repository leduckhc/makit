/// User-configurable server endpoint for the desktop app.
///
/// The desktop app is the single control plane for the local makit server: it
/// owns how the daemon binds (see [DaemonLifecycle]), which `makit` binary
/// drives it (see [MakitCliResolver]), and the loopback endpoint its own chat
/// client self-pairs against (always `127.0.0.1`, see [LoopbackPairing]).
///
/// Reachability is one question with two answers plus a fallback (SPEC-50 D5):
///
/// - [Reachability.myDevices] (default) → let the server run its secure-default
///   decision (`chooseBindHost` in `server/src/pairing`): Tailscale IP if
///   online, else loopback. Other devices reach it over Tailscale.
/// - [Reachability.thisMacOnly] → `127.0.0.1` only; unreachable from other
///   devices.
/// - [allowLanFallback] → adds `--lan`, a documented *fallback* for when
///   Tailscale is down. It is a preference, not a mode: the server still
///   prefers Tailscale when it is up.
/// - [ServerConfig.customHost] → an explicit host that bypasses the decision
///   entirely (escape hatch, e.g. `0.0.0.0`); lives behind Diagnostics →
///   Advanced.
library;

import 'package:flutter_riverpod/legacy.dart';

import '../../store/prefs/profile_scoped_prefs.dart';

/// The default bind port. Matches the server's own default (`serve.ts`).
const int kDefaultServerPort = 7777;

const String _kReachabilityKey = 'desktop_server_reachability';
const String _kAllowLanFallbackKey = 'desktop_server_allow_lan_fallback';
const String _kCustomHostKey = 'desktop_server_custom_host';
const String _kPortKey = 'desktop_server_port';
const String _kCliPathKey = 'desktop_server_cli_path';

/// Legacy key: the pre-SPEC-50 four-way bind mode. Migrated on load.
const String _kLegacyBindModeKey = 'desktop_server_bind_mode';

/// Legacy key: the pre-unification single host string. Migrated on load.
const String _kLegacyHostKey = 'desktop_server_host';

/// Who can reach this server — one decision, two answers (SPEC-50 D5).
enum Reachability {
  /// Loopback only (`127.0.0.1`) — nothing else can connect.
  thisMacOnly,

  /// Reachable from the user's other devices (Tailscale, secure default), with
  /// [ServerConfig.allowLanFallback] adding plain-Wi-Fi fallback.
  myDevices,
}

/// Parses a persisted reachability string, defaulting to [Reachability.myDevices].
Reachability _parseReachability(String? value) => switch (value) {
  'thisMacOnly' => Reachability.thisMacOnly,
  _ => Reachability.myDevices,
};

bool _isLoopbackHost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1';
}

/// An immutable bind + CLI configuration for the local daemon.
class ServerConfig {
  /// Creates a config.
  const ServerConfig({
    this.reachability = Reachability.myDevices,
    this.allowLanFallback = false,
    this.customHost = '',
    this.port = kDefaultServerPort,
    this.cliPath = '',
  });

  /// Who can reach this server.
  final Reachability reachability;

  /// When [reachability] is [Reachability.myDevices], also allow plain-Wi-Fi
  /// access (`--lan`) as a fallback for when Tailscale is off.
  final bool allowLanFallback;

  /// An explicit host that overrides [reachability] entirely (escape hatch).
  final String customHost;

  /// The port the daemon binds to.
  final int port;

  /// An explicit path to the `makit` binary, or blank to auto-discover it.
  final String cliPath;

  /// Returns a copy with the given overrides.
  ServerConfig copyWith({
    Reachability? reachability,
    bool? allowLanFallback,
    String? customHost,
    int? port,
    String? cliPath,
  }) => ServerConfig(
    reachability: reachability ?? this.reachability,
    allowLanFallback: allowLanFallback ?? this.allowLanFallback,
    customHost: customHost ?? this.customHost,
    port: port ?? this.port,
    cliPath: cliPath ?? this.cliPath,
  );

  /// The `makit start`/`restart` arguments (excluding the verb) for this config.
  ///
  /// A non-empty [customHost] wins — it is the explicit escape hatch. Otherwise
  /// [Reachability.thisMacOnly] pins loopback, [Reachability.myDevices] passes
  /// no host flag (letting the server run its secure default) and only adds
  /// `--lan` when [allowLanFallback] is set.
  List<String> serveArgs() {
    final args = <String>[];
    final host = customHost.trim();
    if (host.isNotEmpty) {
      args
        ..add('--host')
        ..add(host);
    } else {
      switch (reachability) {
        case Reachability.thisMacOnly:
          args
            ..add('--host')
            ..add('127.0.0.1');
        case Reachability.myDevices:
          if (allowLanFallback) args.add('--lan');
      }
    }
    args
      ..add('--port')
      ..add('$port');
    return args;
  }

  @override
  bool operator ==(Object other) =>
      other is ServerConfig &&
      other.reachability == reachability &&
      other.allowLanFallback == allowLanFallback &&
      other.customHost == customHost &&
      other.port == port &&
      other.cliPath == cliPath;

  @override
  int get hashCode =>
      Object.hash(reachability, allowLanFallback, customHost, port, cliPath);
}

/// Reads + persists the [ServerConfig] via a profile-scoped [ScopedPrefs].
///
/// Server config is **server-bound** (SPEC-50 D11): each profile's port and
/// reachability belong to that profile alone, so writes go through a
/// [ScopedPrefs] whose key prefix is the profile's own. Switching profiles
/// rebuilds this controller against the target's scope, so the window never
/// reads the previous profile's port and talks to the wrong server.
class ServerConfigController extends StateNotifier<ServerConfig> {
  /// Creates a controller seeded from [initial]; writes go through [_prefs].
  ///
  /// [defaultPort] is this profile's fallback port (see [ServerProfile.port]);
  /// [setPort] restores it when given a non-positive value so a dev build never
  /// resets to the installed profile's 7777 and collides with it.
  ServerConfigController(this._prefs, ServerConfig initial, {int? defaultPort})
    : _defaultPort = defaultPort ?? kDefaultServerPort,
      super(initial);

  final ScopedPrefs _prefs;
  final int _defaultPort;

  /// The current config. Public accessor so non-widget composition code (the
  /// app root's `serveArgs`/CLI-resolver closures) can read it without touching
  /// the protected `state`.
  ServerConfig get current => state;

  /// Loads the persisted config, migrating any older schema in place.
  ///
  /// Three layers, newest first: the SPEC-50 [Reachability] keys; the
  /// pre-SPEC-50 four-way `desktop_server_bind_mode`; and the pre-unification
  /// single `desktop_server_host`. Each older layer is only consulted when the
  /// newer ones are absent, so an explicit choice always wins over stale data
  /// and no user silently loses a configured endpoint.
  static ServerConfig load(ScopedPrefs prefs, {int? defaultPort}) {
    final fallbackPort = defaultPort ?? kDefaultServerPort;
    final port = prefs.getInt(_kPortKey);
    final cliPath = prefs.getString(_kCliPathKey) ?? '';
    final resolvedPort = (port == null || port <= 0) ? fallbackPort : port;
    final storedHost = prefs.getString(_kCustomHostKey) ?? '';

    // Layer 1: the current SPEC-50 schema.
    final reachStr = prefs.getString(_kReachabilityKey);
    if (reachStr != null) {
      return ServerConfig(
        reachability: _parseReachability(reachStr),
        allowLanFallback: prefs.getBool(_kAllowLanFallbackKey) ?? false,
        customHost: storedHost,
        port: resolvedPort,
        cliPath: cliPath,
      );
    }

    // Layer 2: the pre-SPEC-50 four-way bind mode.
    final bindMode = prefs.getString(_kLegacyBindModeKey);
    if (bindMode != null) {
      return switch (bindMode) {
        'loopback' => ServerConfig(
          reachability: Reachability.thisMacOnly,
          port: resolvedPort,
          cliPath: cliPath,
        ),
        'lan' => ServerConfig(
          allowLanFallback: true,
          port: resolvedPort,
          cliPath: cliPath,
        ),
        // `custom` keeps its explicit host; `auto` drops any stale host so its
        // "let the server decide" behaviour is preserved exactly.
        'custom' => ServerConfig(
          customHost: storedHost,
          port: resolvedPort,
          cliPath: cliPath,
        ),
        _ => ServerConfig(port: resolvedPort, cliPath: cliPath),
      };
    }

    // Layer 3: the pre-unification single-host preference.
    final legacy = prefs.getString(_kLegacyHostKey)?.trim() ?? '';
    if (legacy.isNotEmpty && !_isLoopbackHost(legacy)) {
      return ServerConfig(
        customHost: legacy,
        port: resolvedPort,
        cliPath: cliPath,
      );
    }
    return ServerConfig(port: resolvedPort, cliPath: cliPath);
  }

  /// Persists the reachability answer and updates state.
  ///
  /// Clears any custom host at the same time: [ServerConfig.serveArgs] gives a
  /// non-empty [ServerConfig.customHost] precedence over the reachability
  /// choice, so leaving a stale `0.0.0.0` in place would keep the server
  /// network-reachable after the user explicitly picked “Just this Mac” — the
  /// UI would say “nothing else can connect” while the bind said otherwise. An
  /// explicit reachability choice is the newer intent and wins.
  Future<void> setReachability(Reachability reachability) async {
    state = state.copyWith(reachability: reachability, customHost: '');
    await _prefs.setString(_kReachabilityKey, reachability.name);
    await _prefs.setString(_kCustomHostKey, '');
  }

  /// Persists the LAN-fallback preference and updates state.
  Future<void> setAllowLanFallback(bool allow) async {
    state = state.copyWith(allowLanFallback: allow);
    await _prefs.setBool(_kAllowLanFallbackKey, allow);
  }

  /// Persists the custom host (the Advanced escape hatch).
  Future<void> setCustomHost(String host) async {
    final h = host.trim();
    state = state.copyWith(customHost: h);
    await _prefs.setString(_kCustomHostKey, h);
  }

  /// Persists a new port (non-positive → this profile's default) and updates
  /// state.
  Future<void> setPort(int port) async {
    final p = port <= 0 ? _defaultPort : port;
    state = state.copyWith(port: p);
    await _prefs.setInt(_kPortKey, p);
  }

  /// Persists an explicit `makit` binary path (blank → auto-discover).
  Future<void> setCliPath(String path) async {
    final p = path.trim();
    state = state.copyWith(cliPath: p);
    await _prefs.setString(_kCliPathKey, p);
  }
}

/// The active server config. Overridden at the app root (`runDesktopApp`) with
/// a controller backed by a profile-scoped [ScopedPrefs]; tests override it too.
final serverConfigProvider =
    StateNotifierProvider<ServerConfigController, ServerConfig>(
      (ref) => throw UnimplementedError('overridden in runDesktopApp'),
    );
