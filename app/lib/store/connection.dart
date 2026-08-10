import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'secure_store.dart';

import '../pairing/mdns_browser.dart';
import '../pairing/pair_info.dart';
import '../notifications/push_registration.dart';
import '../diagnostics/app_log.dart';
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

  /// Stable identity for this server across restarts and DHCP moves.
  ///
  /// The TLS cert fingerprint is the only field that identifies the *machine*
  /// rather than where it currently sits — host/port drift, labels are
  /// user-editable. It's already what mDNS rediscovery matches on, so reusing
  /// it keeps one notion of "same server" everywhere.
  String get id => fingerprint;

  PairedServer copyWith({String? host, int? port, String? label}) =>
      PairedServer(
        host: host ?? this.host,
        port: port ?? this.port,
        fingerprint: fingerprint,
        bearer: bearer,
        label: label ?? this.label,
        mdnsName: mdnsName,
      );

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
    this.servers = const [],
    this.activeId,
    this.wsState = WsState.idle,
    this.useFake = false,
    this.lastError,
    this.pushRegistered = false,
    this.serverIsLocal = false,
  });

  /// Every server this device has paired with. Only [activeServer] holds a live
  /// socket — the rest are parked credentials the user can switch to.
  final List<PairedServer> servers;

  /// [PairedServer.id] of the server currently connected. A stale id (e.g. the
  /// server was forgotten) resolves to the first entry rather than to nothing,
  /// so the app never sits paired-but-serverless.
  final String? activeId;

  final WsState wsState;
  final bool useFake;
  final String? lastError;

  /// The server the live socket belongs to, or null when nothing is paired.
  PairedServer? get activeServer {
    if (servers.isEmpty) return null;
    for (final s in servers) {
      if (s.id == activeId) return s;
    }
    return servers.first;
  }

  /// Back-compat alias — most call sites only ever cared about the active one.
  PairedServer? get server => activeServer;

  /// True when the user has a choice worth surfacing a switcher for.
  bool get hasMultipleServers => servers.length > 1;

  /// True once this device has sent `push.register` on the current connection
  /// (SPEC-07). Resets on reconnect; used by Settings to show wake status.
  final bool pushRegistered;

  /// SPEC-46 D8 rev 2: whether this client shares a machine with the server,
  /// **as stated by the server** in `hello.ack`.
  ///
  /// Never inferred from [PairedServer.host]: mDNS rediscovery rewrites that
  /// behind us, and a loopback-looking host is not proof anyway. Governs whether
  /// a document can be opened directly (`docs.open`) or has to be published.
  /// Defaults false, so the safe path (publish) is the fallback.
  final bool serverIsLocal;

  bool get paired => activeServer != null || useFake || _wsUrl.isNotEmpty;

  MakitConnState copyWith({
    List<PairedServer>? servers,
    String? activeId,
    WsState? wsState,
    bool? useFake,
    String? lastError,
    bool? pushRegistered,
    bool? serverIsLocal,
    bool clearError = false,
    bool clearServer = false,
    bool clearPushRegistered = false,
  }) => MakitConnState(
    servers: clearServer ? const [] : (servers ?? this.servers),
    activeId: clearServer ? null : (activeId ?? this.activeId),
    wsState: wsState ?? this.wsState,
    useFake: useFake ?? this.useFake,
    lastError: clearError ? null : (lastError ?? this.lastError),
    pushRegistered: clearPushRegistered
        ? false
        : (pushRegistered ?? this.pushRegistered),
    serverIsLocal: serverIsLocal ?? this.serverIsLocal,
  );
}

/// Legacy single-server key, written by builds before multi-server support.
/// Read once at boot and migrated into [_kServersKey], then deleted.
const _kPairedServerKey = 'paired_server';

/// Current key: `{"servers": [...], "activeId": "<fingerprint>"}`.
const _kServersKey = 'paired_servers';

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

  final SecureStore _storage;
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
      // Dev override: connect directly, no pairing. No bearer (the server's
      // --no-auth pre-authenticates loopback clients); the pid comes from
      // [_attachReal] like every other path.
      await _attachReal(
        _wsUrl,
        fingerprint: _wsFp.isEmpty ? null : _wsFp,
        helloBody: const {},
      );
      return;
    }
    final (servers, activeId) = await _loadServers();
    if (servers.isNotEmpty) {
      state = state.copyWith(servers: servers, activeId: activeId);
      await _connectPaired(state.activeServer!);
      return;
    }
    // No paired server, no dev override → leave transport unattached.
    // User lands on /pair. If they tap "Open with fake data" we'll attach
    // the FakeServer then.
  }

  /// Read the server list, migrating a legacy single-server record if that's
  /// all we find. Corrupt records are dropped rather than crashing the boot.
  Future<(List<PairedServer>, String?)> _loadServers() async {
    final raw = await _storage.read(key: _kServersKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final servers = (j['servers'] as List)
            .map((e) => PairedServer.fromJson(e as Map<String, dynamic>))
            .toList();
        if (servers.isNotEmpty) return (servers, j['activeId'] as String?);
      } catch (_) {
        // Fall through to the legacy path, then to "unpaired".
      }
      await _storage.delete(key: _kServersKey);
    }

    // Migration: a pre-multi-server build's single record becomes entry one.
    final legacy = await _storage.read(key: _kPairedServerKey);
    if (legacy != null) {
      try {
        final server = PairedServer.fromJson(
          jsonDecode(legacy) as Map<String, dynamic>,
        );
        await _persistServers([server], server.id);
        await _storage.delete(key: _kPairedServerKey);
        appLog.info('conn', 'migrated legacy paired server → server list');
        return ([server], server.id);
      } catch (_) {
        await _storage.delete(key: _kPairedServerKey);
      }
    }
    return (const <PairedServer>[], null);
  }

  /// Write the whole list. Removing the key entirely when empty keeps
  /// "unpaired" a single unambiguous state on disk.
  Future<void> _persistServers(
    List<PairedServer> servers,
    String? activeId,
  ) async {
    if (servers.isEmpty) {
      await _storage.delete(key: _kServersKey);
      return;
    }
    await _storage.write(
      key: _kServersKey,
      value: jsonEncode({
        'servers': [for (final s in servers) s.toJson()],
        'activeId': ?activeId,
      }),
    );
  }

  /// Persist [servers]/[activeId] and mirror them into state in one step, so
  /// disk and memory can't drift.
  Future<void> _commitServers(
    List<PairedServer> servers,
    String? activeId,
  ) async {
    await _persistServers(servers, activeId);
    state = servers.isEmpty
        ? state.copyWith(clearServer: true)
        : state.copyWith(servers: servers, activeId: activeId);
  }

  /// Make [id] the live server. No-op when it's already active (so the UI can
  /// call this unconditionally) or unknown.
  Future<void> switchTo(String id) async {
    final target = state.servers.where((s) => s.id == id).firstOrNull;
    if (target == null) return;
    if (state.activeServer?.id == id && state.wsState != WsState.idle) return;
    appLog.info('conn', 'switching to server "${target.label}"');
    await _commitServers(state.servers, id);
    await _connectPaired(target);
  }

  /// Drop a server's stored credentials. Forgetting the active one fails over
  /// to whatever remains rather than stranding the user on an empty Home.
  Future<void> forget(String id) async {
    final wasActive = state.activeServer?.id == id;
    final remaining = state.servers.where((s) => s.id != id).toList();
    if (remaining.length == state.servers.length) return;

    if (remaining.isEmpty) {
      await _commitServers(const [], null);
      await _detach();
      return;
    }
    if (!wasActive) {
      await _commitServers(remaining, state.activeId);
      return;
    }
    final next = remaining.first;
    await _commitServers(remaining, next.id);
    await _connectPaired(next);
  }

  /// Rename a server for display only — credentials and the live socket are
  /// untouched, so renaming the active server never drops the connection.
  Future<void> renameServer(String id, String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return;
    final updated = [
      for (final s in state.servers)
        if (s.id == id) s.copyWith(label: trimmed) else s,
    ];
    await _commitServers(updated, state.activeId);
  }

  /// Close the live socket and any fake, without touching stored creds.
  Future<void> _detach() async {
    await _ws?.close();
    _ws = null;
    _wsSub?.cancel();
    _wsStateSub?.cancel();
    _fake?.stop();
    _fake = null;
    state = state.copyWith(wsState: WsState.idle, useFake: false);
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
  /// Authenticated `hello` body. Credentials only — [_attachReal] adds the pid.
  Map<String, dynamic> _authHelloBody(String bearer) => {'bearer': bearer};

  /// Our OS `pid`, so the server can measure the app surface (SPEC-37 decision
  /// 6: the app has no self-CPU API, so the server samples the pid we report and
  /// trusts it only on a loopback socket).
  ///
  /// Empty off desktop — web has no `dart:io` process, and on iOS/Android the
  /// socket is not loopback so the server ignores the value anyway.
  ///
  /// Added centrally in [_attachReal] rather than per call site: this was
  /// originally sent from only two of the four hello paths, so the dashboard's
  /// "App (Flutter)" row read "—" for the entire documented dev loop and for the
  /// first session after pairing.
  Map<String, dynamic> _pidHelloBody() {
    if (kIsWeb) return const {};
    if (!(io.Platform.isMacOS ||
        io.Platform.isWindows ||
        io.Platform.isLinux)) {
      return const {};
    }
    return {'pid': io.pid};
  }

  Future<void> _connectPaired(PairedServer server) async {
    await _attachReal(
      server.wssUrl,
      fingerprint: server.fingerprint,
      helloBody: _authHelloBody(server.bearer),
    );
    unawaited(_maybeRediscover(server));
  }

  final Map<String, bool> _rediscoveringByServer = {};

  Future<void> _maybeRediscover(PairedServer server) async {
    final fp = server.fingerprint;
    if (_rediscoveringByServer[fp] ?? false) return;
    _rediscoveringByServer[fp] = true;
    try {
      // Give the first attempt a brief window to succeed.
      await Future<void>.delayed(_rediscoverStall);
      if (state.wsState == WsState.connected) return;
      // The user may have switched servers while we slept. Checking `wsState`
      // alone is not enough — a switch that is still `connecting` would let
      // this task carry on with a now-stale server.
      if (state.activeServer?.id != server.id) return;

      appLog.info(
        'conn',
        'connect stalled; browsing mDNS for fp ${server.fingerprint.substring(0, 12)}…',
      );
      final found = await _browseLan(timeout: const Duration(seconds: 4));
      // Browsing takes seconds, so re-check: by now the live socket may belong
      // to another server, and re-attaching would drag it back to this one.
      if (state.activeServer?.id != server.id) return;
      final matches = found
          .where((d) => d.fingerprint == server.fingerprint)
          .toList();
      if (matches.isEmpty) {
        appLog.warn('conn', 'no mDNS match for stored fingerprint.');
        state = state.copyWith(
          lastError: 'Server unreachable at ${server.host}:${server.port}',
        );
        return;
      }
      final match = matches.first;
      if (match.host == server.host && match.port == server.port) return;

      appLog.info(
        'conn',
        'mDNS rediscovered: ${server.host}:${server.port} → ${match.host}:${match.port}',
      );
      // Base the update on the current entry (not the captured `server`) so a
      // concurrent rename during the browse window isn't overwritten.
      final current =
          state.servers.where((s) => s.id == server.id).firstOrNull ?? server;
      final updated = current.copyWith(host: match.host, port: match.port);
      // Rewrite just this entry; the other servers' records are untouched.
      final servers = [
        for (final s in state.servers)
          if (s.id == updated.id) updated else s,
      ];
      await _persistServers(servers, state.activeId);
      state = state.copyWith(servers: servers, clearError: true);
      await _attachReal(
        updated.wssUrl,
        fingerprint: updated.fingerprint,
        helloBody: _authHelloBody(updated.bearer),
      );
    } finally {
      _rediscoveringByServer[fp] = false;
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
    // Reset serverIsLocal on each new connection; it will be set from hello.ack if local.
    state = state.copyWith(serverIsLocal: false);
    _wsSub = ws.frames.listen((env) {
      // D8 rev 2: the server states whether we share its machine. Captured here,
      // before fan-out, so it is set by the time any screen reads it.
      if (env.t == MsgType.helloAck) {
        final isLocal = env.body['isLocal'];
        // Absent (an older server) is treated as remote: publishing works
        // everywhere, so the fallback must be the one that cannot be wrong.
        state = state.copyWith(serverIsLocal: isLocal == true);
      }
      _inFrames.add(env);
    });
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
    await ws.connect(
      // The pid is merged here, not by the callers, so no future attach path can
      // omit it. A caller may still override it explicitly.
      url,
      helloBody: {..._pidHelloBody(), ...helloBody},
      pinnedFingerprint: fingerprint,
    );
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
    // Still send the desktop pid so the server can measure the app surface (SPEC-37).
    final body = {'pair': info.token, 'label': label, ..._pidHelloBody()};
    await ws.connect(
      info.wssUrl,
      pinnedFingerprint: info.fingerprint,
      helloBody: body,
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
    // Re-pairing a server we already know (same fingerprint) replaces that
    // entry rather than adding a duplicate with a stale bearer.
    final servers = [
      for (final s in state.servers)
        if (s.id != result.id) s,
      result,
    ];
    await _persistServers(servers, result.id);
    state = state.copyWith(
      servers: servers,
      activeId: result.id,
      clearError: true,
    );
    await _attachReal(
      result.wssUrl,
      fingerprint: result.fingerprint,
      helloBody: _authHelloBody(result.bearer),
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

  /// Forget every server and drop the connection — the "start over" path.
  /// [forget] is the per-server version.
  Future<void> unpair() async {
    await _storage.delete(key: _kServersKey);
    await _storage.delete(key: _kPairedServerKey);
    await _ws?.close();
    _ws = null;
    _fake?.stop();
    _fake = null;
    // Leave unpaired. Fake data is opt-in from the pairing screen — do not
    // re-attach it here or "Exit demo" / Unpair can never leave fake mode.
    state = MakitConnState();
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

/// The secure store for tokens/bearers. Public so the desktop composition root
/// can override it with a per-profile file (see `runDesktopApp`).
final secureStorageProvider = Provider<SecureStore>(
  // macOS: the desktop app ships ad-hoc signed ("Sign to Run Locally",
  // CODE_SIGN_IDENTITY = "-"), so any keychain item's ACL is bound to an
  // unstable code signature and macOS re-prompts for the login password on
  // every rebuild. `defaultSecureStore()` swaps in a file-backed store on
  // macOS to avoid the prompt; other platforms keep the OS keychain/keystore.
  (_) => defaultSecureStore(),
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
        ref.watch(secureStorageProvider),
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
