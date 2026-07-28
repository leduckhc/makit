import 'dart:async';
import 'dart:convert';

import 'package:ulid/ulid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'pinned_http.dart';
import 'protocol.dart';
import 'transport.dart';
// WsState now lives in transport.dart (breaks the interface↔impl import cycle);
// re-export so existing `import 'ws_client.dart'` consumers are unaffected.
export 'transport.dart' show WsState;

/// Reconnecting WebSocket client with fingerprint-pinned TLS.
///
/// If [pinnedFingerprint] is set, we accept any TLS cert whose DER sha256
/// matches it — that's how we trust the server's self-signed cert without
/// adding it to the OS trust store.
class WsClient implements Transport {
  WsClient();

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Timer? _pinger;
  int _attempt = 0;
  int _openGen = 0;

  final _stateCtrl = StreamController<WsState>.broadcast();
  final _frameCtrl = StreamController<Envelope>.broadcast();
  final _pending = <String, Completer<Envelope>>{};

  Map<String, dynamic> _helloBody = const {};
  String? _url;
  String? _pinnedFingerprint;

  @override
  Stream<WsState> get state => _stateCtrl.stream;
  @override
  Stream<Envelope> get frames => _frameCtrl.stream;

  WsState _current = WsState.idle;
  WsState get currentState => _current;

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async {
    _url = url;
    _helloBody = helloBody;
    _pinnedFingerprint = pinnedFingerprint?.toLowerCase();
    await _open();
  }

  @override
  Future<void> close() async {
    _retry?.cancel();
    _pinger?.cancel();
    await _sub?.cancel();
    // Closing a sink that's already erroring/closing can throw — swallow it.
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _sub = null;
    _ch = null;
    _setState(WsState.closed);
  }

  Future<Envelope> request(MsgType t, Map<String, dynamic> body) {
    final id = Ulid().toString();
    final env = Envelope(t: t, id: id, body: body);
    final c = Completer<Envelope>();
    _pending[id] = c;
    _send(env);
    return c.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('request $id timed out');
      },
    );
  }

  void send(MsgType t, Map<String, dynamic> body) {
    _send(Envelope(t: t, id: Ulid().toString(), body: body));
  }

  /// Like [send] but preserves a caller-supplied envelope id, so callers
  /// that correlate ack/err by id (see ConnectionController.request) match.
  @override
  void sendEnvelope(Envelope env) {
    _send(env);
  }

  /// Force an immediate reconnect (e.g. on app-foreground). Cancels pending
  /// backoff, resets the attempt counter, tears down any stale channel, and
  /// opens a fresh connection right away. No-op if never connected.
  @override
  void forceReconnect() {
    if (_url == null) return;
    _retry?.cancel();
    _pinger?.cancel();
    _attempt = 0;
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      unawaited(_ch?.sink.close());
    } catch (_) {}
    _ch = null;
    unawaited(_open());
  }

  // ---- internals -----------------------------------------------------------

  void _setState(WsState s) {
    _current = s;
    _stateCtrl.add(s);
  }

  Future<void> _open() async {
    // Serialize re-entrant opens. connect(), forceReconnect(), and the retry
    // timer can all call _open() while a previous one is still suspended at
    // `await ch.ready`. Each call supersedes the in-flight one; a superseded
    // open must NOT listen on its channel, or the single-subscription stream
    // gets listened twice -> "Bad state: Stream has already been listened to".
    final gen = ++_openGen;
    await _sub?.cancel();
    _sub = null;
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;

    _setState(_attempt == 0 ? WsState.connecting : WsState.reconnecting);
    final WebSocketChannel ch;
    try {
      ch = await _openChannel(_url!);
      await ch.ready;
    } catch (e) {
      if (gen != _openGen) return; // a newer open took over; it owns state
      // Surface connect errors so we can see TLS / refused / etc. in logs.
      // ignore: avoid_print
      print('[makit] ws connect to $_url failed: $e');
      _scheduleRetry();
      return;
    }

    if (gen != _openGen) {
      // Superseded while connecting -- discard this channel, don't listen.
      try {
        await ch.sink.close();
      } catch (_) {}
      return;
    }

    _ch = ch;
    _sub = ch.stream.listen(
      _onMessage,
      onDone: _onDone,
      onError: (_) => _onDone(),
      cancelOnError: true,
    );

    _send(Envelope(t: MsgType.hello, id: Ulid().toString(), body: _helloBody));

    _attempt = 0;
    _setState(WsState.connected);

    _pinger?.cancel();
    _pinger = Timer.periodic(const Duration(seconds: 25), (_) {
      send(MsgType.ping, {'ts': DateTime.now().millisecondsSinceEpoch});
    });
  }

  Future<WebSocketChannel> _openChannel(String url) async {
    final uri = Uri.parse(url);
    if (uri.scheme == 'wss' && _pinnedFingerprint != null) {
      // Pin the server cert fingerprint instead of requiring CA trust. Shared
      // with the media loader so both transports make the same trust decision.
      return IOWebSocketChannel.connect(
        uri,
        customClient: pinnedHttpClient(_pinnedFingerprint!),
      );
    }
    return WebSocketChannel.connect(uri);
  }

  void _send(Envelope env) {
    final ch = _ch;
    if (ch == null) return;
    // The sink can be closed mid-flight (during reconnect). Writing to a closed
    // sink throws "Bad state: Cannot add event after closing" and bubbles up
    // through the scheduler. Swallow it — the next reconnect will replay subs.
    try {
      ch.sink.add(jsonEncode(env.toJson()));
    } catch (e) {
      // ignore: avoid_print
      print('[makit] ws send dropped (channel closing): $e');
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final env = Envelope.decode(raw);
    if (env == null) return;

    final pending = _pending.remove(env.id);
    if (pending != null && (env.t == MsgType.ack || env.t == MsgType.err)) {
      if (env.t == MsgType.err) {
        pending.completeError(
          StateError(env.body['message'] as String? ?? 'error'),
        );
      } else {
        pending.complete(env);
      }
      return;
    }

    _frameCtrl.add(env);
  }

  void _onDone() {
    _pinger?.cancel();
    _sub = null;
    _ch = null;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_url == null) return;
    _attempt = (_attempt + 1).clamp(0, 10);
    final base = (1 << _attempt) * 250;
    final jitter = base ~/ 4;
    final delay = Duration(milliseconds: (base + jitter).clamp(250, 30000));
    _setState(WsState.reconnecting);
    _retry?.cancel();
    _retry = Timer(delay, _open);
  }
}
