/// User-configurable server endpoint for the desktop app.
///
/// The desktop app is the single control plane for the local makit server: it
/// owns how the daemon binds (see [DaemonLifecycle]), which `makit` binary
/// drives it (see [MakitCliResolver]), and the loopback endpoint its own chat
/// client self-pairs against (always `127.0.0.1`, see [LoopbackPairing]).
///
/// Bind behaviour is expressed as a [ServerBindMode] that mirrors the server's
/// own secure-by-default decision (`chooseBindHost` in `server/src/pairing`):
///
/// - [ServerBindMode.auto] (default) → let the server decide: Tailscale IP if
///   online, else loopback. Other devices can reach it over Tailscale.
/// - [ServerBindMode.lan] → expose on the local network (`--lan`).
/// - [ServerBindMode.loopback] → `127.0.0.1` only; unreachable from other
///   devices.
/// - [ServerBindMode.custom] → an explicit host (escape hatch, e.g. `0.0.0.0`).
library;

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The default bind port. Matches the server's own default (`serve.ts`).
const int kDefaultServerPort = 7777;

const String _kBindModeKey = 'desktop_server_bind_mode';
const String _kCustomHostKey = 'desktop_server_custom_host';
const String _kPortKey = 'desktop_server_port';
const String _kCliPathKey = 'desktop_server_cli_path';

/// Legacy key: the pre-unification single host string. Migrated on load.
const String _kLegacyHostKey = 'desktop_server_host';

/// How the local daemon should choose its bind host.
enum ServerBindMode {
  /// Server decides: Tailscale if online, else loopback (secure default).
  auto,

  /// Expose on the local network (`--lan`). Note the server still prefers
  /// Tailscale when it is up (secure default); use [custom] to force a host.
  lan,

  /// Loopback only (`127.0.0.1`) — not reachable from other devices.
  loopback,

  /// An explicit host supplied via [ServerConfig.customHost].
  custom,
}

/// Parses a persisted bind-mode string, defaulting to [ServerBindMode.auto].
ServerBindMode _parseBindMode(String? value) => switch (value) {
  'lan' => ServerBindMode.lan,
  'loopback' => ServerBindMode.loopback,
  'custom' => ServerBindMode.custom,
  _ => ServerBindMode.auto,
};

bool _isLoopbackHost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1';
}

/// An immutable bind + CLI configuration for the local daemon.
class ServerConfig {
  /// Creates a config.
  const ServerConfig({
    this.bindMode = ServerBindMode.auto,
    this.customHost = '',
    this.port = kDefaultServerPort,
    this.cliPath = '',
  });

  /// How the daemon chooses its bind host.
  final ServerBindMode bindMode;

  /// The explicit host used only when [bindMode] is [ServerBindMode.custom].
  final String customHost;

  /// The port the daemon binds to.
  final int port;

  /// An explicit path to the `makit` binary, or blank to auto-discover it.
  final String cliPath;

  /// Returns a copy with the given overrides.
  ServerConfig copyWith({
    ServerBindMode? bindMode,
    String? customHost,
    int? port,
    String? cliPath,
  }) => ServerConfig(
    bindMode: bindMode ?? this.bindMode,
    customHost: customHost ?? this.customHost,
    port: port ?? this.port,
    cliPath: cliPath ?? this.cliPath,
  );

  /// The `makit start`/`restart` arguments (excluding the verb) for this
  /// config. [ServerBindMode.auto] passes no `--host`/`--lan`, letting the
  /// server run its secure-by-default decision. A blank custom host also falls
  /// back to auto.
  List<String> serveArgs() {
    final args = <String>[];
    switch (bindMode) {
      case ServerBindMode.auto:
        break;
      case ServerBindMode.lan:
        args.add('--lan');
      case ServerBindMode.loopback:
        args
          ..add('--host')
          ..add('127.0.0.1');
      case ServerBindMode.custom:
        final h = customHost.trim();
        if (h.isNotEmpty) {
          args
            ..add('--host')
            ..add(h);
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
      other.bindMode == bindMode &&
      other.customHost == customHost &&
      other.port == port &&
      other.cliPath == cliPath;

  @override
  int get hashCode => Object.hash(bindMode, customHost, port, cliPath);
}

/// Reads + persists the [ServerConfig] via [SharedPreferences].
class ServerConfigController extends StateNotifier<ServerConfig> {
  /// Creates a controller seeded from [initial]; writes go through [_prefs].
  ServerConfigController(this._prefs, ServerConfig initial) : super(initial);

  final SharedPreferences _prefs;

  /// The current config. Public accessor so non-widget composition code (the
  /// app root's `serveArgs`/CLI-resolver closures) can read it without touching
  /// the protected `state`.
  ServerConfig get current => state;

  /// Loads the persisted config.
  ///
  /// New installs (and users who never changed the pre-unification host)
  /// default to [ServerBindMode.auto]. A legacy host that was deliberately set
  /// to a non-loopback value migrates to [ServerBindMode.custom] so those
  /// users keep reaching their configured endpoint.
  static ServerConfig load(SharedPreferences prefs) {
    final port = prefs.getInt(_kPortKey);
    final cliPath = prefs.getString(_kCliPathKey) ?? '';
    final resolvedPort = (port == null || port <= 0)
        ? kDefaultServerPort
        : port;

    final modeStr = prefs.getString(_kBindModeKey);
    if (modeStr != null) {
      return ServerConfig(
        bindMode: _parseBindMode(modeStr),
        customHost: prefs.getString(_kCustomHostKey) ?? '',
        port: resolvedPort,
        cliPath: cliPath,
      );
    }

    // Migrate the legacy single-host preference.
    final legacy = prefs.getString(_kLegacyHostKey)?.trim() ?? '';
    if (legacy.isNotEmpty && !_isLoopbackHost(legacy)) {
      return ServerConfig(
        bindMode: ServerBindMode.custom,
        customHost: legacy,
        port: resolvedPort,
        cliPath: cliPath,
      );
    }
    return ServerConfig(port: resolvedPort, cliPath: cliPath);
  }

  /// Persists a new bind mode and updates state.
  Future<void> setBindMode(ServerBindMode mode) async {
    state = state.copyWith(bindMode: mode);
    await _prefs.setString(_kBindModeKey, mode.name);
  }

  /// Persists the custom host (used when [ServerBindMode.custom] is active).
  Future<void> setCustomHost(String host) async {
    final h = host.trim();
    state = state.copyWith(customHost: h);
    await _prefs.setString(_kCustomHostKey, h);
  }

  /// Persists a new port (non-positive → default) and updates state.
  Future<void> setPort(int port) async {
    final p = port <= 0 ? kDefaultServerPort : port;
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
/// a controller backed by real [SharedPreferences]; tests override it too.
final serverConfigProvider =
    StateNotifierProvider<ServerConfigController, ServerConfig>(
      (ref) => throw UnimplementedError('overridden in runDesktopApp'),
    );
