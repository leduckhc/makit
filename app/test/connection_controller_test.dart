import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/pairing/mdns_browser.dart';
import 'package:pino/store/connection.dart';
import 'package:pino/transport/protocol.dart';
import 'package:pino/transport/transport.dart';
import 'package:pino/transport/ws_client.dart';

const _kPairedServerKey = 'paired_server';

// A fingerprint long enough for the controller's `substring(0, 12)` debug log.
const _fingerprint =
    'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

// The controller gives the first connect a 2s stall window before browsing
// mDNS. Wait a touch longer than that so rediscovery has run.
const _pastStallWindow = Duration(seconds: 3);

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
  void sendEnvelope(Envelope env) {}
}

/// In-memory [FlutterSecureStorage] so the controller can persist without the
/// platform channel. Only the surface used by ConnectionController is backed.
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage([Map<String, String>? seed])
    : data = {...?seed},
      super();

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
    'mdnsName': 'pino._tcp.local',
  }),
});

PairedServer _storedServer(FakeSecureStorage storage) => PairedServer.fromJson(
  jsonDecode(storage.data[_kPairedServerKey]!) as Map<String, dynamic>,
);

BrowseLan _fixedBrowse(List<DiscoveredServer> results) =>
    ({Duration timeout = const Duration(seconds: 3)}) async => results;

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
              name: 'pino._tcp.local',
              host: '10.0.0.42',
              port: 9000,
              fingerprint: _fingerprint, // MATCHES stored fingerprint
            ),
          ]),
        );

        // Latest state via the public listener API.
        var latest = PinoConnState();
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
              name: 'pino._tcp.local',
              host: '10.0.0.99',
              port: 9000,
              fingerprint: 'deadbeef' * 8, // does NOT match
            ),
          ]),
        );

        var latest = PinoConnState();
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
}
