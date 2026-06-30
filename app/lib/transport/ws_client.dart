import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:ulid/ulid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

/// State of the underlying WebSocket.
enum WsState { idle, connecting, connected, reconnecting, closed }

/// Reconnecting WebSocket client with fingerprint-pinned TLS.
///
/// If [pinnedFingerprint] is set, we accept any TLS cert whose DER sha256
/// matches it — that's how we trust the server's self-signed cert without
/// adding it to the OS trust store.
class WsClient {
  WsClient();

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Timer? _pinger;
  int _attempt = 0;

  final _stateCtrl = StreamController<WsState>.broadcast();
  final _frameCtrl = StreamController<Envelope>.broadcast();
  final _pending = <String, Completer<Envelope>>{};

  Map<String, int> _resumeCursors = const {};
  String? _url;
  Map<String, dynamic> _helloBody = const {};
  String? _pinnedFingerprint;

  Stream<WsState> get state => _stateCtrl.stream;
  Stream<Envelope> get frames => _frameCtrl.stream;

  WsState _current = WsState.idle;
  WsState get currentState => _current;

  void setResumeCursors(Map<String, int> cursors) => _resumeCursors = cursors;

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

  Future<void> close() async {
    _retry?.cancel();
    _pinger?.cancel();
    await _sub?.cancel();
    await _ch?.sink.close();
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
  void sendEnvelope(Envelope env) {
    _send(env);
  }

  // ---- internals -----------------------------------------------------------

  void _setState(WsState s) {
    _current = s;
    _stateCtrl.add(s);
  }

  Future<void> _open() async {
    _setState(_attempt == 0 ? WsState.connecting : WsState.reconnecting);
    try {
      _ch = await _openChannel(_url!);
      await _ch!.ready;
    } catch (e) {
      // Surface connect errors so we can see TLS / refused / etc. in logs.
      // ignore: avoid_print
      print('[pino] ws connect to $_url failed: $e');
      _scheduleRetry();
      return;
    }

    _sub = _ch!.stream.listen(
      _onMessage,
      onDone: _onDone,
      onError: (_) => _onDone(),
      cancelOnError: true,
    );

    _send(
      Envelope(
        t: MsgType.hello,
        id: Ulid().toString(),
        body: {..._helloBody, 'resumeFrom': _resumeCursors},
      ),
    );

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
      // Custom HttpClient that pins the server cert fingerprint instead of
      // requiring CA trust. dart:io exposes the X.509 DER via `cert.der`.
      final client = HttpClient(
        context: SecurityContext(withTrustedRoots: false),
      );
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            final fp = _hexSha256(cert.der);
            return fp == _pinnedFingerprint;
          };
      // Allow short-lived connection upgrade.
      return IOWebSocketChannel.connect(uri, customClient: client);
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
      print('[pino] ws send dropped (channel closing): $e');
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

String _hexSha256(Uint8List bytes) => sha256
    .convert(bytes)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
