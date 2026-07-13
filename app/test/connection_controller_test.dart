import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/pairing/mdns_browser.dart';
import 'package:makit/notifications/push_registration.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

const _kPairedServerKey = 'paired_server';

// A fingerprint long enough for the controller's `substring(0, 12)` debug log.
const _fingerprint =
    'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

// The stall window is injected as Duration.zero, so a brief pump lets the
// async rediscovery chain (browseLan → re-attach) settle.
const _pastStallWindow = Duration(milliseconds: 50);

/// Hand-written in-memory transport (mirrors the `fake_server.dart` pattern):
/// records what it was asked to connect to and never emits `connected`, so the
/// controller sees the connection "stall" — exactly the mDNS-rediscovery path.
class FakeTransport implements Transport {
  FakeTransport({this.emitConnected = false});

  final bool emitConnected;
  final List<String> connectedUrls = <String>[];
  final List<Map<String, dynamic>> helloBodies = <Map<String, dynamic>>[];
  bool closed = false;

  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  /// Push an arbitrary transport state, mirroring the real socket dropping
  /// and re-establishing (used to exercise reconnect re-registration).
  void emit(WsState s) => _state.add(s);

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async {
    connectedUrls.add(url);
    helloBodies.add(helloBody);
    if (emitConnected) _state.add(WsState.connected);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Stream<Envelope> get frames => _frames.stream;

  @override
  Stream<WsState> get state => _state.stream;

  @override
  void sendEnvelope(Envelope env) {
    sentEnvelopes.add(env);
  }

  final List<Envelope> sentEnvelopes = <Envelope>[];

  int forceReconnectCount = 0;
  @override
  void forceReconnect() {
    forceReconnectCount++;
    if (emitConnected) _state.add(WsState.connected);
  }
}

/// In-memory [FlutterSecureStorage] so the controller can persist without the
/// platform channel. Only the surface used by ConnectionController is backed.
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage([Map<String, String>? seed]) : data = {...?seed}, super();

  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.remove(key);
}

FakeSecureStorage _seededStorage({
  String host = '192.168.1.10',
  int port = 8443,
}) => FakeSecureStorage({
  _kPairedServerKey: jsonEncode({
    'host': host,
    'port': port,
    'fingerprint': _fingerprint,
    'bearer': 'bearer-token',
    'label': 'desktop',
    'mdnsName': 'makit._tcp.local',
  }),
});

PairedServer _storedServer(FakeSecureStorage storage) => PairedServer.fromJson(
  jsonDecode(storage.data[_kPairedServerKey]!) as Map<String, dynamic>,
);

BrowseLan _fixedBrowse(List<DiscoveredServer> results) =>
    ({Duration timeout = const Duration(seconds: 3)}) async => results;

/// Controllable [PushRegistrar] fake: lets a test seed a token before connect
/// and deliver one after connect (mirrors the native `didRegister` arrival).
class FakePushRegistrar implements PushRegistrar {
  FakePushRegistrar({this.token, this.platform = 'apns'});

  String? token;
  @override
  String platform;
  void Function(String token)? _onToken;

  @override
  Future<String?> getToken() async => token;

  @override
  set onToken(void Function(String token)? listener) => _onToken = listener;

  /// Simulate the native APNs token arriving.
  void deliver(String t) {
    token = t;
    _onToken?.call(t);
  }
}

void main() {
  group('ConnectionController mDNS rediscovery', () {
    test(
      'matching fingerprint on new host rewrites storage and re-attaches',
      () async {
        final storage = _seededStorage();
        final transports = <FakeTransport>[];

        final controller = ConnectionController(
          storage,
          // Always stalls: never emits WsState.connected.
          transportFactory: () {
            final t = FakeTransport();
            transports.add(t);
            return t;
          },
          browseLan: _fixedBrowse([
            DiscoveredServer(
              name: 'makit._tcp.local',
              host: '10.0.0.42',
              port: 9000,
              fingerprint: _fingerprint, // MATCHES stored fingerprint
            ),
          ]),
          rediscoverStall: Duration.zero,
        );

        // Latest state via the public listener API.
        var latest = MakitConnState();
        controller.addListener((s) => latest = s);

        // First (stalled) attach to the stored address.
        await Future<void>.delayed(Duration.zero);
        expect(transports, hasLength(1));
        expect(transports[0].connectedUrls, ['wss://192.168.1.10:8443']);
        expect(latest.wsState, WsState.connecting);

        // Let the 2s stall window elapse so rediscovery fires.
        await Future<void>.delayed(_pastStallWindow);

        // Stored host:port rewritten to the mDNS-discovered address.
        final updated = _storedServer(storage);
        expect(updated.host, '10.0.0.42');
        expect(updated.port, 9000);
        expect(updated.fingerprint, _fingerprint);
        expect(updated.bearer, 'bearer-token'); // creds preserved

        // Controller re-attached the transport to the new address.
        expect(transports, hasLength(2));
        expect(transports[1].connectedUrls, ['wss://10.0.0.42:9000']);
        expect(latest.server?.host, '10.0.0.42');
        expect(latest.lastError, isNull);

        controller.dispose();
      },
    );

    test(
      'non-matching fingerprint is ignored: no host change, sets lastError',
      () async {
        final storage = _seededStorage();
        final transports = <FakeTransport>[];

        final controller = ConnectionController(
          storage,
          transportFactory: () {
            final t = FakeTransport();
            transports.add(t);
            return t;
          },
          browseLan: _fixedBrowse([
            DiscoveredServer(
              name: 'makit._tcp.local',
              host: '10.0.0.99',
              port: 9000,
              fingerprint: 'deadbeef' * 8, // does NOT match
            ),
          ]),
          rediscoverStall: Duration.zero,
        );

        var latest = MakitConnState();
        controller.addListener((s) => latest = s);

        await Future<void>.delayed(_pastStallWindow);

        // Stored server untouched.
        final stored = _storedServer(storage);
        expect(stored.host, '192.168.1.10');
        expect(stored.port, 8443);

        // No re-attach happened; an error is surfaced.
        expect(transports, hasLength(1));
        expect(latest.lastError, isNotNull);
        expect(latest.lastError, contains('192.168.1.10'));

        controller.dispose();
      },
    );
  });

  group('ConnectionController app-lifecycle reconnect (B10)', () {
    test(
      'onAppResumed forces an immediate transport reconnect when not connected',
      () async {
        final storage = _seededStorage();
        final transports = <FakeTransport>[];
        final controller = ConnectionController(
          storage,
          // Never emits connected → controller stays in connecting/reconnecting.
          transportFactory: () {
            final t = FakeTransport();
            transports.add(t);
            return t;
          },
          browseLan: _fixedBrowse(const []),
          rediscoverStall: const Duration(seconds: 30),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transports, hasLength(1));
        expect(transports[0].forceReconnectCount, 0);

        controller.onAppResumed();

        expect(
          transports[0].forceReconnectCount,
          1,
          reason: 'foreground should nudge a stalled connection to retry now',
        );
        controller.dispose();
      },
    );

    test(
      'onAppResumed does NOT force a reconnect while already connected',
      () async {
        final storage = _seededStorage();
        final transports = <FakeTransport>[];
        final controller = ConnectionController(
          storage,
          transportFactory: () {
            final t = FakeTransport(emitConnected: true); // healthy connection
            transports.add(t);
            return t;
          },
          browseLan: _fixedBrowse(const []),
          rediscoverStall: const Duration(seconds: 30),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transports, hasLength(1));

        controller.onAppResumed();

        expect(
          transports[0].forceReconnectCount,
          0,
          reason: 'a healthy socket must not be dropped on every foreground',
        );
        controller.dispose();
      },
    );
  });

  group('ConnectionController push.register (SPEC-07 MAJOR 1)', () {
    List<Envelope> pushRegs(FakeTransport t) => t.sentEnvelopes
        .where((e) => e.t == MsgType.cmd && e.body['kind'] == 'push.register')
        .toList();

    test('registers on connect when a token is already present', () async {
      final storage = _seededStorage();
      final transports = <FakeTransport>[];
      final controller = ConnectionController(
        storage,
        transportFactory: () {
          final t = FakeTransport(emitConnected: true);
          transports.add(t);
          return t;
        },
        browseLan: _fixedBrowse(const []),
        rediscoverStall: const Duration(seconds: 30),
        pushRegistrar: FakePushRegistrar(token: 'tok-1'),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final regs = pushRegs(transports.single);
      expect(regs, hasLength(1));
      expect(regs.single.body['token'], 'tok-1');
      expect(regs.single.body['platform'], 'apns');
      expect(controller.state.pushRegistered, isTrue);

      controller.dispose();
    });

    test('registers when the token arrives AFTER connect', () async {
      final storage = _seededStorage();
      final transports = <FakeTransport>[];
      final registrar = FakePushRegistrar(); // no token yet
      final controller = ConnectionController(
        storage,
        transportFactory: () {
          final t = FakeTransport(emitConnected: true);
          transports.add(t);
          return t;
        },
        browseLan: _fixedBrowse(const []),
        rediscoverStall: const Duration(seconds: 30),
        pushRegistrar: registrar,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        pushRegs(transports.single),
        isEmpty,
        reason: 'no token at connect',
      );

      registrar.deliver('tok-late');
      await Future<void>.delayed(Duration.zero);

      final regs = pushRegs(transports.single);
      expect(regs, hasLength(1));
      expect(regs.single.body['token'], 'tok-late');

      controller.dispose();
    });

    test('the same token is not re-sent within one connection', () async {
      final storage = _seededStorage();
      final transports = <FakeTransport>[];
      final registrar = FakePushRegistrar(token: 'tok-dup');
      final controller = ConnectionController(
        storage,
        transportFactory: () {
          final t = FakeTransport(emitConnected: true);
          transports.add(t);
          return t;
        },
        browseLan: _fixedBrowse(const []),
        rediscoverStall: const Duration(seconds: 30),
        pushRegistrar: registrar,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(pushRegs(transports.single), hasLength(1));

      // Native re-delivers the identical token → must not double-register.
      registrar.deliver('tok-dup');
      await Future<void>.delayed(Duration.zero);

      expect(pushRegs(transports.single), hasLength(1));

      controller.dispose();
    });

    test('re-registers the same token on every reconnect', () async {
      final storage = _seededStorage();
      final transports = <FakeTransport>[];
      final controller = ConnectionController(
        storage,
        transportFactory: () {
          final t = FakeTransport(emitConnected: true);
          transports.add(t);
          return t;
        },
        browseLan: _fixedBrowse(const []),
        rediscoverStall: const Duration(seconds: 30),
        pushRegistrar: FakePushRegistrar(token: 'tok-1'),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final t = transports.single;
      expect(pushRegs(t), hasLength(1), reason: 'registers on first connect');

      // The socket drops and the same transport reconnects. Per spec §B the
      // token must be re-sent on every successful reconnect, even unchanged.
      t.emit(WsState.reconnecting);
      t.emit(WsState.connected);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        pushRegs(t),
        hasLength(2),
        reason: 'each successful reconnect must re-send push.register',
      );
      expect(pushRegs(t).last.body['token'], 'tok-1');

      controller.dispose();
    });
  });

  group('ConnectionController respondTo idempotency (SPEC-08 step 4)', () {
    test('a second respondTo for the same requestId is a no-op', () async {
      final storage = _seededStorage();
      final transports = <FakeTransport>[];
      final controller = ConnectionController(
        storage,
        transportFactory: () {
          final t = FakeTransport(emitConnected: true);
          transports.add(t);
          return t;
        },
        browseLan: _fixedBrowse(const []),
        rediscoverStall: const Duration(seconds: 30),
      );
      await Future<void>.delayed(Duration.zero);
      final t = transports.single;

      controller.respondTo('r1', {'approved': true});
      controller.respondTo('r1', {'approved': false});

      final r1 = t.sentEnvelopes
          .where((e) => e.t == MsgType.srvResponse && e.id == 'r1')
          .toList();
      expect(r1, hasLength(1));
      expect(r1.single.body['approved'], true);

      // A different requestId still sends.
      controller.respondTo('r2', {'approved': true});
      expect(
        t.sentEnvelopes
            .where((e) => e.t == MsgType.srvResponse && e.id == 'r2')
            .length,
        1,
      );

      controller.dispose();
    });
  });
}
