/// A [ControlClient] decorator that transparently (re)connects its underlying
/// client.
///
/// The concrete [PinoControlClient] is single-use: it must be `connect()`-ed
/// before use and becomes unusable once its socket closes (e.g. when the daemon
/// is stopped or restarted from the control app itself). Since a *control* app
/// exists precisely to start/stop the daemon, the socket comes and goes — so we
/// wrap the client and rebuild it on demand:
///
/// - The underlying client is created + connected lazily on first use.
/// - It is reused across calls while healthy.
/// - When a call fails (the socket likely died), the dead client is disposed so
///   the next call creates a fresh one. The failure is rethrown so the UI can
///   show an error and the caller can retry.
library;

import 'dart:async';

import 'control_contract.dart';

/// Creates a fresh underlying [ControlClient] (unconnected).
typedef ControlClientFactory = ControlClient Function();

/// Connects a freshly-created client (e.g. `PinoControlClient.connect`).
typedef ControlClientConnect = Future<void> Function(ControlClient client);

/// Disposes a client (e.g. `PinoControlClient.dispose`).
typedef ControlClientDispose = Future<void> Function(ControlClient client);

/// See the library doc.
class ReconnectingControlClient implements ControlClient {
  /// Creates a reconnecting client.
  ///
  /// [create] builds a fresh underlying client; [connect] connects it; [dispose]
  /// tears a dead one down (defaults to a no-op).
  ReconnectingControlClient({
    required ControlClientFactory create,
    required ControlClientConnect connect,
    ControlClientDispose? dispose,
  }) : _create = create,
       _connect = connect,
       _dispose = dispose ?? ((_) async {});

  final ControlClientFactory _create;
  final ControlClientConnect _connect;
  final ControlClientDispose _dispose;

  ControlClient? _current;
  Future<ControlClient>? _connecting;

  /// Returns a live, connected client, creating and connecting one if needed.
  /// Concurrent callers share a single in-flight connect.
  Future<ControlClient> _ensure() {
    final current = _current;
    if (current != null) return Future.value(current);
    return _connecting ??= _connectNew();
  }

  Future<ControlClient> _connectNew() async {
    final client = _create();
    try {
      await _connect(client);
      _current = client;
      return client;
    } catch (_) {
      // Connect failed (daemon down): drop it so the next attempt retries.
      await _safeDispose(client);
      rethrow;
    } finally {
      _connecting = null;
    }
  }

  /// Runs [op] against the live client; on failure, drops the connection so the
  /// next call reconnects, then rethrows.
  Future<T> _guard<T>(Future<T> Function(ControlClient client) op) async {
    final client = await _ensure();
    try {
      return await op(client);
    } catch (_) {
      await _drop(client);
      rethrow;
    }
  }

  Future<void> _drop(ControlClient client) async {
    if (identical(_current, client)) _current = null;
    await _safeDispose(client);
  }

  Future<void> _safeDispose(ControlClient client) async {
    try {
      await _dispose(client);
    } catch (_) {
      // Disposing a dead client must never mask the original error.
    }
  }

  /// Disposes any live connection. Safe to call multiple times.
  Future<void> close() async {
    final current = _current;
    _current = null;
    if (current != null) await _safeDispose(current);
  }

  @override
  Future<StatusData> status() => _guard((c) => c.status());

  @override
  Future<PairMintData> pairMint({int? ttlMs}) =>
      _guard((c) => c.pairMint(ttlMs: ttlMs));

  @override
  Future<PairCurrentData?> pairCurrent() => _guard((c) => c.pairCurrent());

  @override
  Future<List<DeviceInfo>> devicesList() => _guard((c) => c.devicesList());

  @override
  Future<bool> devicesRevoke(String id) => _guard((c) => c.devicesRevoke(id));

  @override
  Future<List<ControlSession>> sessionsList() =>
      _guard((c) => c.sessionsList());

  @override
  Future<void> serverStop() => _guard((c) => c.serverStop());

  @override
  Stream<LogLine> tailLogs({int? lines, bool follow = false}) async* {
    final client = await _ensure();
    yield* client.tailLogs(lines: lines, follow: follow);
  }
}
