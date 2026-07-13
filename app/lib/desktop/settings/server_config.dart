/// User-configurable server endpoint for the desktop app.
///
/// This is the host + port makit's local daemon listens on. It drives both
/// `makit start --host <host> --port <port>` (see [DaemonLifecycle]) and the
/// loopback endpoint the chat client self-pairs against (see [LoopbackPairing]).
/// Defaults to `localhost:8787`.
library;

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The default bind host — loopback, covered by the daemon's TLS cert SAN.
const String kDefaultServerHost = 'localhost';

/// The default bind port.
const int kDefaultServerPort = 8787;

const String _kHostKey = 'desktop_server_host';
const String _kPortKey = 'desktop_server_port';

/// An immutable host+port pair.
class ServerConfig {
  /// Creates a config.
  const ServerConfig({
    this.host = kDefaultServerHost,
    this.port = kDefaultServerPort,
  });

  /// The host the daemon binds / the client connects to.
  final String host;

  /// The port the daemon binds / the client connects to.
  final int port;

  /// Returns a copy with the given overrides.
  ServerConfig copyWith({String? host, int? port}) =>
      ServerConfig(host: host ?? this.host, port: port ?? this.port);

  @override
  bool operator ==(Object other) =>
      other is ServerConfig && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Reads + persists the [ServerConfig] via [SharedPreferences].
class ServerConfigController extends StateNotifier<ServerConfig> {
  /// Creates a controller seeded from [initial]; writes go through [_prefs].
  ServerConfigController(this._prefs, ServerConfig initial) : super(initial);

  final SharedPreferences _prefs;

  /// The current config. Public accessor so non-widget composition code (the
  /// app root's `serveDefaults` closure) can read it without touching the
  /// protected `state`.
  ServerConfig get current => state;

  /// Loads the persisted config, falling back to defaults for missing/blank
  /// values.
  static ServerConfig load(SharedPreferences prefs) {
    final host = prefs.getString(_kHostKey);
    final port = prefs.getInt(_kPortKey);
    return ServerConfig(
      host: (host == null || host.trim().isEmpty)
          ? kDefaultServerHost
          : host.trim(),
      port: (port == null || port <= 0) ? kDefaultServerPort : port,
    );
  }

  /// Persists a new host (blank → default) and updates state.
  Future<void> setHost(String host) async {
    final h = host.trim().isEmpty ? kDefaultServerHost : host.trim();
    state = state.copyWith(host: h);
    await _prefs.setString(_kHostKey, h);
  }

  /// Persists a new port (non-positive → default) and updates state.
  Future<void> setPort(int port) async {
    final p = port <= 0 ? kDefaultServerPort : port;
    state = state.copyWith(port: p);
    await _prefs.setInt(_kPortKey, p);
  }
}

/// The active server config. Overridden at the app root (`runDesktopApp`) with
/// a controller backed by real [SharedPreferences]; tests override it too.
final serverConfigProvider =
    StateNotifierProvider<ServerConfigController, ServerConfig>(
      (ref) => throw UnimplementedError('overridden in runDesktopApp'),
    );
