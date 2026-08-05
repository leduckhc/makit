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

  group('corrupt storage', () {
    test(
      'a corrupt server record is dropped and the app boots unpaired',
      () async {
        final storage = FakeSecureStorage({_kServersKey: 'not json at all'});
        final controller = _controller(storage);
        await Future<void>.delayed(Duration.zero);

        // A record we cannot parse must not wedge boot; it is discarded so the
        // user lands on the connect screen and can re-pair.
        expect(controller.state.servers, isEmpty);
        expect(controller.state.paired, isFalse);
        expect(storage.data.containsKey(_kServersKey), isFalse);
        controller.dispose();
      },
    );
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

  group('rediscovery is per server', () {
    // The in-flight guard used to be one controller-wide bool: with A's
    // rediscovery parked in its browse, switching to B returned immediately and
    // B never rediscovered at all until a manual retry.
    test(
      "a server in flight does not block the next server's rediscovery",
      () async {
        final browsedFor = <String>[];
        final gate = Completer<List<DiscoveredServer>>();
        final firstBrowse = Completer<void>();

        final controller = ConnectionController(
          _twoServers(),
          transportFactory: () => FakeTransport(emitConnected: false),
          browseLan: ({Duration timeout = const Duration(seconds: 3)}) {
            // Which server is being rediscovered is inferrable from the active one.
            browsedFor.add('browse');
            if (!firstBrowse.isCompleted) firstBrowse.complete();
            return gate.future;
          },
          rediscoverStall: Duration.zero,
        );
        await Future<void>.delayed(Duration.zero);
        await firstBrowse.future;
        expect(browsedFor, hasLength(1), reason: "A's browse is in flight");

        // Switch while A is still parked. B must run its own discovery.
        await controller.switchTo(_fpB);
        await pumpEventQueue();

        expect(
          browsedFor.length,
          greaterThanOrEqualTo(2),
          reason:
              "B's rediscovery must not be swallowed by A's in-flight guard",
        );
        controller.dispose();
      },
    );
  });

  group('rediscovery races a rename', () {
    // A rename keeps the same fingerprint, so the activeId guard cannot catch it:
    // rediscovery captures `server` at entry and, seconds later, splices
    // `copyWith(host, port)` back into the list. Built from the captured copy,
    // that silently reverts a label the user changed while the browse ran.
    test('a rename during the browse survives the host rewrite', () async {
      final browseGate = Completer<List<DiscoveredServer>>();
      final browseCalled = Completer<void>();
      final storage = _twoServers();

      final controller = ConnectionController(
        storage,
        transportFactory: () => FakeTransport(emitConnected: false),
        browseLan: ({Duration timeout = const Duration(seconds: 3)}) {
          if (!browseCalled.isCompleted) browseCalled.complete();
          return browseGate.future;
        },
        rediscoverStall: Duration.zero,
      );
      await Future<void>.delayed(Duration.zero);
      await browseCalled.future;

      // Rename the *same* server rediscovery is working on, mid-browse.
      await controller.renameServer(_fpA, 'renamed mid-browse');

      // Release the browse at a new address for that same fingerprint.
      browseGate.complete([
        DiscoveredServer(
          name: 'makit._tcp.local',
          host: '10.7.7.7',
          port: 7777,
          fingerprint: _fpA,
        ),
      ]);
      await pumpEventQueue();

      final entry = controller.state.servers.firstWhere(
        (s) => s.fingerprint == _fpA,
      );
      // The address moved, and the rename was NOT clobbered.
      expect(entry.host, '10.7.7.7');
      expect(entry.label, 'renamed mid-browse');
      expect(
        _storedServers(
          storage,
        ).firstWhere((e) => e['fingerprint'] == _fpA)['label'],
        'renamed mid-browse',
      );
      controller.dispose();
    });
  });

  group('rediscovery races a server switch', () {
    // Rediscovery runs unawaited: it sleeps for the stall window, then browses
    // mDNS for up to 4s. A `switchTo` inside that window must not be undone by
    // the in-flight task re-attaching to the server it started from.
    //
    // The browse is gated on a Completer rather than timed, so the stale path is
    // guaranteed to run *after* the switch — a fixed delay could let a loaded
    // runner finish rediscovery first and pass without exercising anything.
    test('a switch during the stall window wins', () async {
      final transports = <FakeTransport>[];
      final browseGate = Completer<List<DiscoveredServer>>();
      final browseCalled = Completer<void>();
      final storage = _twoServers();

      final controller = ConnectionController(
        storage,
        // Never connects, so rediscovery always proceeds past its stall check.
        transportFactory: () {
          final t = FakeTransport(emitConnected: false);
          transports.add(t);
          return t;
        },
        browseLan: ({Duration timeout = const Duration(seconds: 3)}) {
          if (!browseCalled.isCompleted) browseCalled.complete();
          return browseGate.future;
        },
        rediscoverStall: Duration.zero,
      );
      await Future<void>.delayed(Duration.zero);

      // Rediscovery for A has begun and is parked inside the browse.
      await browseCalled.future;

      // Switch to B while A's rediscovery is still awaiting its browse result.
      await controller.switchTo(_fpB);
      expect(controller.state.activeServer?.fingerprint, _fpB);

      // Now release the browse with A's fingerprint at a NEW address — exactly
      // what would tempt the stale task to re-attach to A.
      browseGate.complete([
        DiscoveredServer(
          name: 'makit._tcp.local',
          host: '10.9.9.9',
          port: 9999,
          fingerprint: _fpA,
        ),
      ]);
      // Drain the continuation that runs after the browse completes.
      await pumpEventQueue();

      // B is still active, and the last socket opened is B's — not A's new
      // address. A's record must also be left alone.
      expect(controller.state.activeServer?.fingerprint, _fpB);
      expect(
        transports.last.connectedUrls.last,
        'wss://10.0.0.2:8443',
        reason: 'a stale rediscovery must not re-point the live socket at A',
      );
      expect(
        _storedServers(
          storage,
        ).firstWhere((e) => e['fingerprint'] == _fpA)['host'],
        '10.0.0.1',
        reason: 'the stale task must not rewrite the server it abandoned',
      );
      controller.dispose();
    });
  });
}
