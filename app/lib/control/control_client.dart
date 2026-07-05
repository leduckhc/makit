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
import 'control_types.dart';

/// The default per-request timeout for single-shot verbs.
const _defaultRequestTimeout = Duration(seconds: 30);

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
typedef ControlConnector = Future<ControlConnection> Function(String socketPath);

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

/// A control-plane client for a running pino daemon.
class PinoControlClient {
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
  final _streams = <String, StreamController<LogLine>>{};

  /// Open the control socket. Throws (e.g. [SocketException]) if the daemon is
  /// not listening.
  Future<void> connect() async {
    final conn = await _connector(socketPath);
    _conn = conn;
    _closed = false;
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
      return Future.error(const ControlException('control client not connected'));
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
  Stream<LogLine> tailLogs({int? lines, bool follow = false}) {
    late final StreamController<LogLine> controller;
    final id = _nextId();
    controller = StreamController<LogLine>(
      onCancel: () {
        _streams.remove(id);
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
      _streams[id] = controller;
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
  Future<StatusData> status() async =>
      _require<StatusData>(await request(ControlVerb.status));

  /// Mint a fresh pairing token ([PairMintData]).
  Future<PairMintData> pairMint() async =>
      _require<PairMintData>(await request(ControlVerb.pairMint));

  /// The active unexpired pairing token, or `null` if none.
  Future<PairCurrentData?> pairCurrent() async =>
      _optional<PairCurrentData>(await request(ControlVerb.pairCurrent));

  /// List paired devices.
  Future<List<DeviceInfo>> devicesList() async =>
      _require<DevicesListData>(await request(ControlVerb.devicesList)).devices;

  /// Revoke a paired device by [id]; returns whether one was removed.
  Future<bool> devicesRevoke(String id) async => _require<DevicesRevokeData>(
    await request(ControlVerb.devicesRevoke, args: {'id': id}),
  ).removed;

  /// List running sessions.
  Future<List<ControlSession>> sessionsList() async =>
      _require<SessionsListData>(
        await request(ControlVerb.sessionsList),
      ).sessions;

  /// Ask the daemon to shut down.
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

    final stream = _streams[id];
    if (stream != null) {
      switch (raw) {
        case ControlErr(:final error):
          _streams.remove(id);
          stream.addError(ControlException(error));
          unawaited(stream.close());
        case ControlOk(:final data):
          final chunk = LogChunk.fromJson(data);
          switch (chunk) {
            case LogLine():
              stream.add(chunk);
            case LogDone():
              _streams.remove(id);
              unawaited(stream.close());
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
    for (final controller in _streams.values) {
      // Close cleanly rather than erroring: a `logs.tail` consumer may not have
      // attached an error handler, and a socket close is a normal stream end.
      unawaited(controller.close());
    }
    _streams.clear();
  }
}
