/// Control-plane client for the pino desktop app (SPEC-03).
///
/// A thin request/response client over the daemon's unix-domain control socket
/// (`~/.pino/control.sock`). It speaks the frozen NDJSON protocol from
/// `server/src/daemon/protocol.ts` (ported in `control_types.dart` /
/// `control_codec.dart`):
///
///   - single-shot verbs resolve on the first response frame matching the
///     request id ([request] + the typed convenience methods);
///   - `logs.tail` streams many `{ line }` frames for one id, terminated by a
///     `{ done: true }` frame or the socket closing ([tailLogs]).
///
/// The transport is abstracted behind [ControlConnection] so tests can inject a
/// scripted fake instead of a real socket.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'control_codec.dart';
import 'control_contract.dart';
import 'control_types.dart';

/// The default per-request timeout for single-shot verbs.
const _defaultRequestTimeout = Duration(seconds: 30);

/// Cap on the un-terminated inbound buffer. A local peer that never sends a
/// newline must not be able to grow this without bound.
const _maxBufferBytes = 1 << 20; // 1 MiB

/// A bidirectional line-oriented connection to the control socket.
///
/// Abstracts `dart:io` [Socket] so the client can be tested with a scripted
/// in-memory fake.
abstract class ControlConnection {
  /// Raw inbound bytes from the peer.
  Stream<List<int>> get stream;

  /// Write an already-encoded (newline-terminated) wire line.
  void write(String data);

  /// Close the underlying transport.
  Future<void> close();
}

/// Opens a control connection given a socket path. Injected for testing.
typedef ControlConnector =
    Future<ControlConnection> Function(String socketPath);

/// A [ControlConnection] backed by a real `dart:io` unix-domain [Socket].
class _SocketControlConnection implements ControlConnection {
  _SocketControlConnection(this._socket);

  final Socket _socket;

  @override
  Stream<List<int>> get stream => _socket;

  @override
  void write(String data) => _socket.write(data);

  @override
  Future<void> close() async => _socket.destroy();
}

Future<ControlConnection> _connectUnixSocket(String socketPath) async {
  final socket = await Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  return _SocketControlConnection(socket);
}

/// Default monotonically-increasing id generator (`c1`, `c2`, …).
class _SeqIdGenerator {
  int _seq = 0;
  String next() => 'c${++_seq}';
}

class _Pending {
  _Pending(this.verb, this.completer);
  final ControlVerb verb;
  final Completer<ControlResponse<Object?>> completer;
}

class _LogStream {
  _LogStream(this.controller, {required this.follow});
  final StreamController<LogLine> controller;

  /// Whether the consumer asked to keep streaming live lines. A [follow]
  /// stream that ends because the socket dropped is a failure, not a clean EOF.
  final bool follow;
}

/// A control-plane client for a running pino daemon.
class PinoControlClient implements ControlClient {
  /// Creates a client for the daemon at [socketPath].
  ///
  /// [idGenerator] supplies request ids (injectable for deterministic tests);
  /// [requestTimeout] caps single-shot verbs; [connector] opens the transport
  /// (defaults to a real unix-domain socket).
  PinoControlClient({
    required this.socketPath,
    String Function()? idGenerator,
    Duration requestTimeout = _defaultRequestTimeout,
    ControlConnector? connector,
  }) : _requestTimeout = requestTimeout,
       _connector = connector ?? _connectUnixSocket,
       _nextId = idGenerator ?? _SeqIdGenerator().next;

  /// Path to the daemon's control socket.
  final String socketPath;

  final Duration _requestTimeout;
  final ControlConnector _connector;
  final String Function() _nextId;

  ControlConnection? _conn;
  StreamSubscription<List<int>>? _sub;
  bool _closed = false;
  String _buffer = '';

  final _pending = <String, _Pending>{};
  final _streams = <String, _LogStream>{};

  /// Open the control socket. Throws (e.g. [SocketException]) if the daemon is
  /// not listening.
  ///
  /// A client is single-use: calling [connect] more than once, or after
  /// [dispose], throws a [StateError] rather than silently leaking the previous
  /// socket and its subscription.
  Future<void> connect() async {
    if (_closed) {
      throw StateError('control client has been disposed');
    }
    if (_conn != null) {
      throw StateError('control client is already connected');
    }
    final conn = await _connector(socketPath);
    _conn = conn;
    _sub = conn.stream.listen(
      _onData,
      onError: (Object _) => _onClosed('control socket error'),
      onDone: () => _onClosed('control socket closed'),
      cancelOnError: true,
    );
  }

  /// Issue [verb] and resolve the first response frame matching its id.
  ///
  /// The returned response's `data` is typed per verb (see [parseVerbData]).
  /// Times out after the configured request timeout. Not usable for the
  /// multi-frame `logs.tail` stream — use [tailLogs] for that.
  Future<ControlResponse<Object?>> request(
    ControlVerb verb, {
    Map<String, dynamic>? args,
  }) {
    if (_closed || _conn == null) {
      return Future.error(
        const ControlException('control client not connected'),
      );
    }
    final id = _nextId();
    final completer = Completer<ControlResponse<Object?>>();
    _pending[id] = _Pending(verb, completer);
    _conn!.write(encodeRequest(verb, id: id, args: args));
    return completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('control request $id (${verb.wire}) timed out');
      },
    );
  }

  /// Stream the daemon log tail.
  ///
  /// Emits one [LogLine] per `{ line }` frame. The stream closes on a
  /// `{ done: true }` frame (non-follow) or when the socket closes, and errors
  /// with a [ControlException] on an error frame. When [follow] is true the
  /// daemon keeps streaming new lines until the subscription is cancelled.
  @override
  Stream<LogLine> tailLogs({int? lines, bool follow = false}) {
    late final StreamController<LogLine> controller;
    final id = _nextId();
    controller = StreamController<LogLine>(
      onCancel: () {
        _streams.remove(id);
        if (follow && !_closed && _conn != null) {
          _conn!.write(
            encodeRequest(
              ControlVerb.logsCancel,
              id: _nextId(),
              args: {'id': id},
            ),
          );
        }
      },
    );
    controller.onListen = () {
      if (_closed || _conn == null) {
        controller.addError(
          const ControlException('control client not connected'),
        );
        unawaited(controller.close());
        return;
      }
      _streams[id] = _LogStream(controller, follow: follow);
      final args = <String, dynamic>{};
      if (lines != null) args['lines'] = lines;
      if (follow) args['follow'] = true;
      _conn!.write(
        encodeRequest(
          ControlVerb.logsTail,
          id: id,
          args: args.isEmpty ? null : args,
        ),
      );
    };
    return controller.stream;
  }

  /// Close the socket and fail any in-flight requests/streams.
  Future<void> dispose() async {
    _onClosed('control client disposed');
    await _sub?.cancel();
    _sub = null;
    await _conn?.close();
    _conn = null;
  }

  // ---- convenience verbs ---------------------------------------------------

  /// Fetch daemon [StatusData].
  @override
  Future<StatusData> status() async =>
      _require<StatusData>(await request(ControlVerb.status));

  /// Mint a fresh pairing token ([PairMintData]).
  @override
  Future<PairMintData> pairMint({int? ttlMs}) async => _require<PairMintData>(
    await request(
      ControlVerb.pairMint,
      args: ttlMs == null ? null : {'ttlMs': ttlMs},
    ),
  );

  /// The active unexpired pairing token, or `null` if none.
  @override
  Future<PairCurrentData?> pairCurrent() async =>
      _optional<PairCurrentData>(await request(ControlVerb.pairCurrent));

  /// List paired devices.
  @override
  Future<List<DeviceInfo>> devicesList() async =>
      _require<DevicesListData>(await request(ControlVerb.devicesList)).devices;

  /// Revoke a paired device by [id]; returns whether one was removed.
  @override
  Future<bool> devicesRevoke(String id) async => _require<DevicesRevokeData>(
    await request(ControlVerb.devicesRevoke, args: {'id': id}),
  ).removed;

  /// List running sessions.
  @override
  Future<List<ControlSession>> sessionsList() async =>
      _require<SessionsListData>(
        await request(ControlVerb.sessionsList),
      ).sessions;

  /// Ask the daemon to shut down.
  @override
  Future<void> serverStop() async =>
      _require<ServerStopData>(await request(ControlVerb.serverStop));

  // ---- internals -----------------------------------------------------------

  /// Extract required typed [data] from a response, throwing on error/mismatch.
  T _require<T>(ControlResponse<Object?> res) {
    switch (res) {
      case ControlErr(:final error):
        throw ControlException(error);
      case ControlOk(:final data):
        if (data is T) return data;
        throw ControlException(
          'malformed or missing payload for response ${res.id}',
        );
    }
  }

  /// Extract optional typed [data] (a `null` ok payload is a valid absence).
  T? _optional<T>(ControlResponse<Object?> res) {
    switch (res) {
      case ControlErr(:final error):
        throw ControlException(error);
      case ControlOk(:final data):
        return data as T?;
    }
  }

  void _onData(List<int> chunk) {
    _buffer += utf8.decode(chunk, allowMalformed: true);
    final parts = _buffer.split('\n');
    _buffer = parts.removeLast();
    for (final line in parts) {
      if (line.isEmpty) continue;
      _dispatch(line);
    }
    if (_buffer.length > _maxBufferBytes) {
      _onClosed('control socket line exceeded $_maxBufferBytes bytes');
    }
  }

  void _dispatch(String line) {
    final raw = decodeResponse(line);
    if (raw == null) return;
    final id = raw.id;

    final pending = _pending.remove(id);
    if (pending != null) {
      switch (raw) {
        case ControlErr(:final error):
          pending.completer.complete(ControlErr<Object?>(id, error));
        case ControlOk(:final data):
          pending.completer.complete(
            ControlOk<Object?>(id, parseVerbData(pending.verb, data)),
          );
      }
      return;
    }

    final logStream = _streams[id];
    if (logStream != null) {
      final controller = logStream.controller;
      switch (raw) {
        case ControlErr(:final error):
          _streams.remove(id);
          controller.addError(ControlException(error));
          unawaited(controller.close());
        case ControlOk(:final data):
          final chunk = LogChunk.fromJson(data);
          switch (chunk) {
            case LogLine():
              controller.add(chunk);
            case LogDone():
              _streams.remove(id);
              unawaited(controller.close());
            case null:
              break; // ignore an unrecognized chunk
          }
      }
    }
  }

  void _onClosed(String reason) {
    if (_closed) return;
    _closed = true;
    final err = ControlException(reason);
    for (final entry in _pending.values) {
      if (!entry.completer.isCompleted) entry.completer.completeError(err);
    }
    _pending.clear();
    for (final logStream in _streams.values) {
      // A follow stream that ends because the socket dropped is a failure the
      // consumer must be able to detect; a non-follow tail ending is a normal
      // EOF, so close it cleanly.
      if (logStream.follow && !logStream.controller.isClosed) {
        logStream.controller.addError(err);
      }
      unawaited(logStream.controller.close());
    }
    _streams.clear();
  }
}
