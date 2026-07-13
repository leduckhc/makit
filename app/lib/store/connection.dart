import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../pairing/mdns_browser.dart';
import '../pairing/pair_info.dart';
import '../notifications/push_registration.dart';
import '../transport/protocol.dart';
import '../transport/transport.dart';
import '../transport/ws_client.dart';
import 'fake_server.dart';

/// Compile-time switch: `--dart-define=MAKIT_WS_URL=wss://…` + optional
/// `--dart-define=MAKIT_FP=<sha256>` for fingerprint pinning. Useful for
/// localhost development against `makit serve --no-auth`.
const _wsUrl = String.fromEnvironment('MAKIT_WS_URL');
const _wsFp = String.fromEnvironment('MAKIT_FP');

/// Persisted info about the desktop server we're paired with.
class PairedServer {
  PairedServer({
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.bearer,
    required this.label,
    this.mdnsName,
  });

  final String host;
  final int port;
  final String fingerprint;
  final String bearer;
  final String label;

  /// mDNS service name (e.g., 'makit._tcp.local'). If present, we'll resolve
  /// this at connect time instead of using [host] directly, making the
  /// connection resilient to DHCP IP changes.
  final String? mdnsName;

  String get wssUrl => 'wss://$host:$port';

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'fingerprint': fingerprint,
    'bearer': bearer,
    'label': label,
    if (mdnsName != null) 'mdnsName': mdnsName,
  };

  static PairedServer fromJson(Map<String, dynamic> j) => PairedServer(
    host: j['host'] as String,
    port: j['port'] as int,
    fingerprint: j['fingerprint'] as String,
    bearer: j['bearer'] as String,
    label: j['label'] as String? ?? 'server',
    mdnsName: j['mdnsName'] as String?,
  );
}

class MakitConnState {
  MakitConnState({
    this.server,
    this.wsState = WsState.idle,
    this.useFake = false,
    this.lastError,
    this.pushRegistered = false,
  });

  final PairedServer? server;
  final WsState wsState;
  final bool useFake;
  final String? lastError;

  /// True once this device has sent `push.register` on the current connection
  /// (SPEC-07). Resets on reconnect; used by Settings to show wake status.
  final bool pushRegistered;

  bool get paired => server != null || useFake || _wsUrl.isNotEmpty;

  MakitConnState copyWith({
    PairedServer? server,
    WsState? wsState,
    bool? useFake,
    String? lastError,
    bool? pushRegistered,
    bool clearError = false,
    bool clearServer = false,
    bool clearPushRegistered = false,
  }) => MakitConnState(
    server: clearServer ? null : (server ?? this.server),
    wsState: wsState ?? this.wsState,
    useFake: useFake ?? this.useFake,
    lastError: clearError ? null : (lastError ?? this.lastError),
    pushRegistered: clearPushRegistered
        ? false
        : (pushRegistered ?? this.pushRegistered),
  );
}

const _kPairedServerKey = 'paired_server';

/// Signature of the mDNS LAN browse used for rediscovery. Mirrors the
/// top-level [browseLan] so it can be swapped for a fake in tests.
typedef BrowseLan = Future<List<DiscoveredServer>> Function({Duration timeout});

class ConnectionController extends StateNotifier<MakitConnState> {
  ConnectionController(
    this._storage, {
    Transport Function()? transportFactory,
    BrowseLan? browseLan,
    Duration? rediscoverStall,
    PushRegistrar? pushRegistrar,
  }) : _transportFactory = transportFactory ?? (() => WsClient()),
       _browseLan = browseLan ?? _defaultBrowseLan,
       _rediscoverStall = rediscoverStall ?? const Duration(seconds: 2),
       _pushRegistrar = pushRegistrar ?? const NoopPushRegistrar(),
       super(MakitConnState()) {
    // SPEC-07: the APNs token can arrive AFTER we connect. Subscribe so a late
    // token still triggers a `push.register` on the live socket.
    _pushRegistrar.onToken = registerPushToken;
    _boot();
  }

  final FlutterSecureStorage _storage;
  final Transport Function() _transportFactory;
  final BrowseLan _browseLan;

  /// SPEC-07: native push-token provider. Default Noop → no token → the app
  /// never sends `push.register` and the server stays on the Slice-1 fallback.
  final PushRegistrar _pushRegistrar;

  /// How long to wait for the fast-path connect before browsing mDNS to
  /// rediscover a moved server. Injectable so unit tests run instantly.
  final Duration _rediscoverStall;
  final _inFrames = StreamController<Envelope>.broadcast();
  final _responded = StreamController<String>.broadcast();

  FakeServer? _fake;
  Transport? _ws;
  StreamSubscription<Envelope>? _wsSub;
  StreamSubscription<WsState>? _wsStateSub;

  Stream<Envelope> get incoming => _inFrames.stream;

  /// Reverse-RPC requests from server: `srv.request` envelopes that need
  /// a UI to answer them. Subscribe at app startup; respond with [respondTo].
  Stream<Envelope> get srvRequests =>
      _inFrames.stream.where((e) => e.t == MsgType.srvRequest);

  /// Emits a [requestId] once its `srv.response` has been sent. Lets the UI
  /// drop any queued fallback/replay for a request that was answered
  /// elsewhere (e.g. from an actionable notification), avoiding a double
  /// prompt after the app resumes.
  Stream<String> get responded => _responded.stream;

  /// Send the matching `srv.response` for a previously-received [requestId].
  ///
  /// Idempotent: both the dialog path (`SrvRequestHandler._respond`) and the
  /// actionable-notification path funnel here, so a second response for the
  /// same [requestId] is a no-op — matching the server's first-wins semantics.
  void respondTo(String requestId, Map<String, dynamic> body) {
    if (!_respondedRequests.add(requestId)) return;
    send(Envelope(t: MsgType.srvResponse, id: requestId, body: body));
    _responded.add(requestId);
  }

  final Set<String> _respondedRequests = <String>{};

  /// Called when the app returns to the foreground. iOS suspends sockets and
  /// backoff timers while backgrounded, so a stalled connection can otherwise
  /// sit in "reconnecting" for a full backoff interval (up to ~30s) after
  /// resume. Nudge the transport to reconnect immediately — but only when we
  /// aren't already connected, so a healthy socket isn't needlessly dropped.
  void onAppResumed() {
    if (state.wsState != WsState.connected) {
      _ws?.forceReconnect();
    }
  }

  Future<void> _boot() async {
    if (_wsUrl.isNotEmpty) {
      // Dev override: connect directly, no pairing.
      await _attachReal(
        _wsUrl,
        fingerprint: _wsFp.isEmpty ? null : _wsFp,
        helloBody: const {},
      );
      return;
    }
    final raw = await _storage.read(key: _kPairedServerKey);
    if (raw != null) {
      try {
        final server = PairedServer.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        state = state.copyWith(server: server);
        await _connectPaired(server);
        return;
      } catch (_) {
        await _storage.delete(key: _kPairedServerKey);
      }
    }
    // No paired server, no dev override → leave transport unattached.
    // User lands on /pair. If they tap "Open with fake data" we'll attach
    // the FakeServer then.
  }

  /// Public entrypoint for the pairing screen's "Open with fake data".
  void useFakeServer() => _attachFake();

  void _attachFake() {
    _fake = FakeServer()..start();
    _fake!.outgoing.listen(_inFrames.add);
    state = state.copyWith(wsState: WsState.connected, useFake: true);
  }

  /// Connect to a previously-paired server.
  ///
  /// Strategy: try the stored host:port first (fast happy path). If the
  /// socket can't connect within a short window (most likely the desktop's
  /// LAN IP changed via DHCP), browse mDNS for a server with the **same
  /// fingerprint** — that's the only safe identity check — update the
  /// stored host:port, and reconnect there.
  Future<void> _connectPaired(PairedServer server) async {
    await _attachReal(
      server.wssUrl,
      fingerprint: server.fingerprint,
      helloBody: {'bearer': server.bearer},
    );
    unawaited(_maybeRediscover(server));
  }

  bool _rediscovering = false;

  Future<void> _maybeRediscover(PairedServer server) async {
    if (_rediscovering) return;
    _rediscovering = true;
    try {
      // Give the first attempt a brief window to succeed.
      await Future<void>.delayed(_rediscoverStall);
      if (state.wsState == WsState.connected) return;

      debugPrint(
        '[makit] connect stalled; browsing mDNS for fp ${server.fingerprint.substring(0, 12)}…',
      );
      final found = await _browseLan(timeout: const Duration(seconds: 4));
      final matches = found
          .where((d) => d.fingerprint == server.fingerprint)
          .toList();
      if (matches.isEmpty) {
        debugPrint('[makit] no mDNS match for stored fingerprint.');
        state = state.copyWith(
          lastError: 'Server unreachable at ${server.host}:${server.port}',
        );
        return;
      }
      final match = matches.first;
      if (match.host == server.host && match.port == server.port) return;

      debugPrint(
        '[makit] mDNS rediscovered: ${server.host}:${server.port} → ${match.host}:${match.port}',
      );
      final updated = PairedServer(
        host: match.host,
        port: match.port,
        fingerprint: server.fingerprint,
        bearer: server.bearer,
        label: server.label,
        mdnsName: server.mdnsName,
      );
      await _storage.write(
        key: _kPairedServerKey,
        value: jsonEncode(updated.toJson()),
      );
      state = state.copyWith(server: updated, clearError: true);
      await _attachReal(
        updated.wssUrl,
        fingerprint: updated.fingerprint,
        helloBody: {'bearer': updated.bearer},
      );
    } finally {
      _rediscovering = false;
    }
  }

  /// Force a reconnect attempt with mDNS rediscovery on stall. Used by the
  /// AppBar status chip on tap.
  Future<void> retry() async {
    final server = state.server;
    if (server == null) return;
    await _connectPaired(server);
  }

  Future<void> _attachReal(
    String url, {
    String? fingerprint,
    required Map<String, dynamic> helloBody,
  }) async {
    await _ws?.close();
    _wsSub?.cancel();
    _wsStateSub?.cancel();
    _fake?.stop();
    _fake = null;

    final ws = _transportFactory();
    _ws = ws;
    _wsSub = ws.frames.listen(_inFrames.add);
    _wsStateSub = ws.state.listen((s) {
      // Clear any stale "unreachable" error once we're actually connected, so
      // the connection chip doesn't keep showing a dead-server message after a
      // successful (re)connect.
      state = state.copyWith(
        wsState: s,
        useFake: false,
        clearError: s == WsState.connected,
      );
      // SPEC-07: (re)register the content-free wake push token on every
      // successful (re)connect. Reset the per-connection guard first so a
      // fresh socket always re-registers; no-op when no token is available.
      if (s == WsState.connected) {
        _registeredToken = null;
        state = state.copyWith(clearPushRegistered: true);
        unawaited(_registerPush());
      }
    });
    state = state.copyWith(
      useFake: false,
      wsState: WsState.connecting,
      clearError: true,
    );
    await ws.connect(url, helloBody: helloBody, pinnedFingerprint: fingerprint);
  }

  /// Run the full QR pair handshake: connect, present pair token, receive
  /// bearer + deviceId in `hello.ack`, persist.
  Future<PairedServer> pairWith(PairInfo info, {String label = 'phone'}) async {
    final ws = _transportFactory();
    final completer = Completer<PairedServer>();

    // We're the only thing on this socket during pairing, so we just take
    // the first helloAck/err that arrives — no need to correlate by id
    // (WsClient generates its own ULID for the hello frame).
    final stateSub = ws.state.listen(null);
    final frameSub = ws.frames.listen((env) {
      if (completer.isCompleted) return;
      if (env.t == MsgType.helloAck) {
        final bearer = env.body['bearer'] as String?;
        if (bearer == null) {
          completer.completeError(
            StateError('server did not return a bearer token'),
          );
          return;
        }
        completer.complete(
          PairedServer(
            host: info.host,
            port: info.port,
            fingerprint: info.fingerprint,
            bearer: bearer,
            label: label,
            mdnsName:
                'makit._tcp.local', // Store the service name for future mDNS resolution.
          ),
        );
      } else if (env.t == MsgType.err) {
        completer.completeError(
          StateError(env.body['message'] as String? ?? 'pair failed'),
        );
      }
    });

    // Open the connection but DON'T let WsClient send its own auto-hello —
    // it would carry no pair token. Instead we call _open directly via
    // `connect` and rely on it sending hello with the body we configure.
    await ws.connect(
      info.wssUrl,
      pinnedFingerprint: info.fingerprint,
      helloBody: {'pair': info.token, 'label': label},
    );

    // Race with a 15s timeout.
    final result = await completer.future
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException('pairing timed out');
          },
        )
        .whenComplete(() async {
          await frameSub.cancel();
          await stateSub.cancel();
          await ws.close();
        });

    // Persist + switch the live connection over to the new paired creds.
    await _storage.write(
      key: _kPairedServerKey,
      value: jsonEncode(result.toJson()),
    );
    state = state.copyWith(server: result, clearError: true);
    await _attachReal(
      result.wssUrl,
      fingerprint: result.fingerprint,
      helloBody: {'bearer': result.bearer},
    );
    return result;
  }

  /// Send a command and await its `ack`/`err` reply. Times out at 10s.
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) {
    final id = 'req-${DateTime.now().microsecondsSinceEpoch}';
    final env = Envelope(t: t, id: id, body: body);
    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription<Envelope> sub;
    sub = _inFrames.stream.listen((frame) {
      if (frame.id != id) return;
      if (frame.t == MsgType.ack) {
        if (!completer.isCompleted) completer.complete(frame.body);
      } else if (frame.t == MsgType.err) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError(frame.body['message'] as String? ?? 'error'),
          );
        }
      }
    });
    send(env);
    return completer.future
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('$t request timed out'),
        )
        .whenComplete(() => sub.cancel());
  }

  void send(Envelope env) {
    if (_fake != null) {
      _fake!.send(env);
      return;
    }
    final ws = _ws;
    if (ws == null) return;
    if (env.t == MsgType.hello) return; // sent automatically on connect
    ws.sendEnvelope(env);
  }

  /// Force a fresh connection to the currently-paired server. No-op if we're
  /// only attached to the dev fake or have no paired server.
  Future<void> reconnect() async {
    final server = state.server;
    if (server == null) return;
    await _connectPaired(server);
  }

  /// SPEC-07: the push token most recently sent on the CURRENT connection.
  /// Reset on every (re)connect so a fresh socket re-registers, but guards
  /// against re-sending the same token within one connection (idempotent).
  String? _registeredToken;

  /// SPEC-07: called when a native push token becomes available (possibly
  /// after the socket connected). Sends `push.register` immediately if we're
  /// connected; otherwise the next successful connect picks it up via
  /// [_registerPush]. Idempotent per connection.
  void registerPushToken(String token) {
    if (token.isEmpty) return;
    if (state.wsState == WsState.connected) _sendPushRegister(token);
  }

  /// SPEC-07: send the `push.register` cmd once a native push token is
  /// available. Best-effort; a missing token (Noop registrar, permission
  /// declined) simply skips registration.
  Future<void> _registerPush() async {
    try {
      final token = await _pushRegistrar.getToken();
      if (token == null || token.isEmpty) return;
      _sendPushRegister(token);
    } catch (_) {
      // Best-effort: a failed registration never breaks the connection.
    }
  }

  /// Emit the `push.register` cmd for [token], unless the same token was
  /// already registered on this connection.
  void _sendPushRegister(String token) {
    if (token == _registeredToken) return;
    _registeredToken = token;
    state = state.copyWith(pushRegistered: true);
    send(
      Envelope(
        t: MsgType.cmd,
        id: 'push-reg-${DateTime.now().microsecondsSinceEpoch}',
        body: pushRegisterBody(token: token, platform: _pushRegistrar.platform),
      ),
    );
  }

  Future<void> unpair() async {
    await _storage.delete(key: _kPairedServerKey);
    await _ws?.close();
    _fake?.stop();
    state = MakitConnState();
    _attachFake();
  }

  @override
  void dispose() {
    // Detach the app-lifetime registrar's callback so a late native
    // `didRegister` can't call registerPushToken on this disposed notifier
    // (which would throw when it reads `state`).
    _pushRegistrar.onToken = null;
    _wsSub?.cancel();
    _wsStateSub?.cancel();
    _ws?.close();
    _fake?.stop();
    _inFrames.close();
    _responded.close();
    super.dispose();
  }
}

/// Real mDNS browse used by the production composition root. Captured as a
/// top-level tear-off so the constructor default doesn't shadow it.
const BrowseLan _defaultBrowseLan = browseLan;

final _secureStorageProvider = Provider<FlutterSecureStorage>(
  // macOS: use the legacy (file-based) keychain instead of the data-protection
  // keychain. The data-protection keychain requires a `keychain-access-groups`
  // entitlement, which needs a signing team; the desktop app ships ad-hoc
  // ("Sign to Run Locally", CODE_SIGN_IDENTITY = "-"), so writes would fail with
  // errSecMissingEntitlement (-34018). `mOptions` is read only on macOS — iOS
  // uses `iOptions` — so this does not affect the mobile app.
  (_) => const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  ),
);

/// SPEC-07: the native push-token provider injected into the controller.
/// Defaults to [NoopPushRegistrar] (safe for tests + platforms without a
/// native provider). The real mobile app overrides this with a
/// [ChannelPushRegistrar] in `main.dart`.
final pushRegistrarProvider = Provider<PushRegistrar>(
  (_) => const NoopPushRegistrar(),
);

final connectionControllerProvider =
    StateNotifierProvider<ConnectionController, MakitConnState>((ref) {
      return ConnectionController(
        ref.watch(_secureStorageProvider),
        pushRegistrar: ref.watch(pushRegistrarProvider),
      );
    });

final connectionProvider = Provider<MakitConnState>(
  (ref) => ref.watch(connectionControllerProvider),
);

final connectionListenableProvider = Provider<Listenable>((ref) {
  // Only notify on `paired` transitions — that's all the router's redirect
  // depends on. A ValueNotifier<bool> won't fire for wsState/lastError churn
  // (connecting/reconnecting/errors), so GoRouter doesn't refresh on every
  // connection tick (which previously remounted screens mid-build).
  final notifier = ValueNotifier<bool>(
    ref.read(connectionControllerProvider).paired,
  );
  ref.listen<MakitConnState>(
    connectionControllerProvider,
    (_, next) => notifier.value = next.paired,
  );
  return notifier;
});
