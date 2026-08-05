import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/pairing/mdns_browser.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

/// Legacy single-server key (pre multi-server). Kept here so the migration
/// test pins the exact on-disk shape older builds wrote.
const _kLegacyKey = 'paired_server';
const _kServersKey = 'paired_servers';

const _fpA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fpB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class FakeTransport implements Transport {
  FakeTransport({this.emitConnected = true});

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
  Future<void> close() async => closed = true;

  @override
  Stream<Envelope> get frames => _frames.stream;

  @override
  Stream<WsState> get state => _state.stream;

  @override
  void sendEnvelope(Envelope env) {}

  @override
  void forceReconnect() {}
}

class FakeSecureStorage implements SecureStore {
  FakeSecureStorage([Map<String, String>? seed]) : data = {...?seed};

  final Map<String, String> data;

  @override
  Future<String?> read({required String key}) async => data[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

BrowseLan _noBrowse() =>
    ({Duration timeout = const Duration(seconds: 3)}) async =>
        const <DiscoveredServer>[];

Map<String, dynamic> _serverJson({
  required String host,
  required String fingerprint,
  String label = 'desktop',
  int port = 8443,
}) => {
  'host': host,
  'port': port,
  'fingerprint': fingerprint,
  'bearer': 'bearer-$fingerprint',
  'label': label,
};

/// Storage already holding two paired servers, with A active.
FakeSecureStorage _twoServers({String activeFingerprint = _fpA}) =>
    FakeSecureStorage({
      _kServersKey: jsonEncode({
        'servers': [
          _serverJson(host: '10.0.0.1', fingerprint: _fpA, label: 'work mac'),
          _serverJson(host: '10.0.0.2', fingerprint: _fpB, label: 'home mac'),
        ],
        'activeId': activeFingerprint,
      }),
    });

ConnectionController _controller(
  FakeSecureStorage storage, {
  List<FakeTransport>? transports,
}) => ConnectionController(
  storage,
  transportFactory: () {
    final t = FakeTransport();
    transports?.add(t);
    return t;
  },
  browseLan: _noBrowse(),
  rediscoverStall: const Duration(seconds: 30),
);

Map<String, dynamic> _storedRecord(FakeSecureStorage s) =>
    jsonDecode(s.data[_kServersKey]!) as Map<String, dynamic>;

List<Map<String, dynamic>> _storedServers(FakeSecureStorage s) =>
    (_storedRecord(s)['servers'] as List).cast<Map<String, dynamic>>();

void main() {
  group('legacy migration', () {
    test(
      'a single legacy paired_server becomes a one-entry server list',
      () async {
        final storage = FakeSecureStorage({
          _kLegacyKey: jsonEncode(
            _serverJson(host: '192.168.1.10', fingerprint: _fpA, label: 'imac'),
          ),
        });
        final controller = _controller(storage);
        await Future<void>.delayed(Duration.zero);

        // Migrated into the new list, still active, creds preserved — nobody
        // has to re-pair after upgrading.
        expect(controller.state.servers, hasLength(1));
        expect(controller.state.servers.single.fingerprint, _fpA);
        expect(controller.state.activeServer?.host, '192.168.1.10');
        expect(controller.state.activeServer?.bearer, 'bearer-$_fpA');
        expect(controller.state.paired, isTrue);

        // Persisted in the new shape, and the legacy key is gone so there is
        // only ever one source of truth.
        expect(_storedServers(storage), hasLength(1));
        expect(_storedRecord(storage)['activeId'], _fpA);
        expect(storage.data.containsKey(_kLegacyKey), isFalse);

        controller.dispose();
      },
    );

    test('no stored server at all leaves the app unpaired', () async {
      final controller = _controller(FakeSecureStorage());
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.servers, isEmpty);
      expect(controller.state.paired, isFalse);
      controller.dispose();
    });
  });

  group('boot with several servers', () {
    test('connects to the active server, not merely the first', () async {
      final transports = <FakeTransport>[];
      final storage = _twoServers(activeFingerprint: _fpB);
      final controller = _controller(storage, transports: transports);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.servers, hasLength(2));
      expect(controller.state.activeServer?.fingerprint, _fpB);
      expect(transports.single.connectedUrls, ['wss://10.0.0.2:8443']);
      expect(transports.single.helloBodies.single['bearer'], 'bearer-$_fpB');

      controller.dispose();
    });

    test('an unknown activeId falls back to the first server', () async {
      final storage = _twoServers(activeFingerprint: 'gone');
      final controller = _controller(storage);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.activeServer?.fingerprint, _fpA);
      controller.dispose();
    });
  });

  group('switchTo', () {
    test(
      'tears down the old socket and connects to the chosen server',
      () async {
        final transports = <FakeTransport>[];
        final storage = _twoServers();
        final controller = _controller(storage, transports: transports);
        await Future<void>.delayed(Duration.zero);
        expect(transports.single.connectedUrls, ['wss://10.0.0.1:8443']);

        await controller.switchTo(_fpB);

        // Old transport closed, new one pointed at B with B's bearer.
        expect(transports[0].closed, isTrue);
        expect(transports, hasLength(2));
        expect(transports[1].connectedUrls, ['wss://10.0.0.2:8443']);
        expect(transports[1].helloBodies.single['bearer'], 'bearer-$_fpB');
        expect(controller.state.activeServer?.fingerprint, _fpB);

        // The choice survives a restart.
        expect(_storedRecord(storage)['activeId'], _fpB);

        controller.dispose();
      },
    );

    test('switching to the already-active server does not reconnect', () async {
      final transports = <FakeTransport>[];
      final controller = _controller(_twoServers(), transports: transports);
      await Future<void>.delayed(Duration.zero);

      await controller.switchTo(_fpA);

      expect(transports, hasLength(1), reason: 'no needless socket churn');
      controller.dispose();
    });

    test('switching to an unknown id is a no-op', () async {
      final transports = <FakeTransport>[];
      final controller = _controller(_twoServers(), transports: transports);
      await Future<void>.delayed(Duration.zero);

      await controller.switchTo('nope');

      expect(transports, hasLength(1));
      expect(controller.state.activeServer?.fingerprint, _fpA);
      controller.dispose();
    });
  });

  group('forget', () {
    test(
      'forgetting an inactive server keeps the connection untouched',
      () async {
        final transports = <FakeTransport>[];
        final storage = _twoServers();
        final controller = _controller(storage, transports: transports);
        await Future<void>.delayed(Duration.zero);

        await controller.forget(_fpB);

        expect(controller.state.servers, hasLength(1));
        expect(controller.state.activeServer?.fingerprint, _fpA);
        expect(transports, hasLength(1), reason: 'active socket untouched');
        expect(_storedServers(storage), hasLength(1));
        controller.dispose();
      },
    );

    test(
      'forgetting the active server falls over to a remaining one',
      () async {
        final transports = <FakeTransport>[];
        final storage = _twoServers();
        final controller = _controller(storage, transports: transports);
        await Future<void>.delayed(Duration.zero);

        await controller.forget(_fpA);

        expect(controller.state.servers, hasLength(1));
        expect(controller.state.activeServer?.fingerprint, _fpB);
        expect(transports, hasLength(2));
        expect(transports[1].connectedUrls, ['wss://10.0.0.2:8443']);
        expect(controller.state.paired, isTrue);
        controller.dispose();
      },
    );

    test('forgetting the last server leaves the app unpaired', () async {
      final storage = _twoServers();
      final controller = _controller(storage);
      await Future<void>.delayed(Duration.zero);

      await controller.forget(_fpA);
      await controller.forget(_fpB);

      expect(controller.state.servers, isEmpty);
      expect(controller.state.paired, isFalse);
      expect(storage.data.containsKey(_kServersKey), isFalse);
      controller.dispose();
    });
  });

  group('rename', () {
    test('renaming persists a new label without reconnecting', () async {
      final transports = <FakeTransport>[];
      final storage = _twoServers();
      final controller = _controller(storage, transports: transports);
      await Future<void>.delayed(Duration.zero);

      await controller.renameServer(_fpB, 'studio');

      expect(
        controller.state.servers.firstWhere((s) => s.fingerprint == _fpB).label,
        'studio',
      );
      expect(transports, hasLength(1));
      final stored = _storedServers(
        storage,
      ).firstWhere((s) => s['fingerprint'] == _fpB);
      expect(stored['label'], 'studio');
      controller.dispose();
    });
  });

  group('unpair', () {
    test('clears every server, not just the active one', () async {
      final storage = _twoServers();
      final controller = _controller(storage);
      await Future<void>.delayed(Duration.zero);

      await controller.unpair();

      expect(controller.state.servers, isEmpty);
      expect(controller.state.paired, isFalse);
      expect(storage.data.containsKey(_kServersKey), isFalse);
      controller.dispose();
    });
  });
}
