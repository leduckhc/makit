// Unit tests for the reconnecting control-client decorator.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/control/control_contract.dart';
import 'package:makit/control/reconnecting_control_client.dart';

/// A fake underlying client. Fails all verbs once [alive] is false, mimicking a
/// disposed [MakitControlClient] after its socket closed.
class _FakeClient implements ControlClient {
  _FakeClient(this.id);
  final int id;
  bool alive = true;
  int statusCalls = 0;

  Future<T> _guard<T>(T value) async {
    if (!alive) throw const ControlException('not connected');
    return value;
  }

  @override
  Future<StatusData> status() {
    statusCalls++;
    return _guard(
      StatusData(
        pid: id,
        uptimeMs: 0,
        host: 'h',
        port: 1,
        fingerprint: 'f',
        advertiseHost: 'h',
        pairedDevices: 0,
        runningSessions: 0,
        version: 'v',
      ),
    );
  }

  @override
  Future<List<DeviceInfo>> devicesList() => _guard(const []);
  @override
  Future<bool> devicesRevoke(String id) => _guard(true);
  @override
  Future<PairCurrentData?> pairCurrent() => _guard(null);
  @override
  Future<PairMintData> pairMint({int? ttlMs}) => _guard(
    const PairMintData(url: 'u', token: 't', expiresAt: 0, fingerprint: 'f'),
  );
  @override
  Future<List<ControlSession>> sessionsList() => _guard(const []);
  @override
  Future<void> serverStop() => _guard(null);
  @override
  Stream<LogLine> tailLogs({int? lines, bool follow = false}) async* {
    if (!alive) throw const ControlException('not connected');
    yield const LogLine('line');
  }
}

void main() {
  group('ReconnectingControlClient', () {
    late List<_FakeClient> created;
    late List<int> connected;
    late List<int> disposed;
    late bool connectShouldFail;

    ReconnectingControlClient build() {
      var seq = 0;
      return ReconnectingControlClient(
        create: () {
          final c = _FakeClient(seq++);
          created.add(c);
          return c;
        },
        connect: (c) async {
          if (connectShouldFail) throw const ControlException('daemon down');
          connected.add((c as _FakeClient).id);
        },
        dispose: (c) async => disposed.add((c as _FakeClient).id),
      );
    }

    setUp(() {
      created = [];
      connected = [];
      disposed = [];
      connectShouldFail = false;
    });

    test('creates and connects a client lazily on first use', () async {
      final client = build();
      expect(created, isEmpty);
      await client.status();
      expect(created, hasLength(1));
      expect(connected, [0]);
    });

    test('reuses the same connection across calls', () async {
      final client = build();
      await client.status();
      await client.devicesList();
      expect(created, hasLength(1));
      expect(connected, [0]);
    });

    test('drops a dead connection and reconnects on the next call', () async {
      final client = build();
      await client.status();
      created.single.alive = false; // socket died (e.g. daemon stopped)
      await expectLater(client.status(), throwsA(isA<ControlException>()));
      // Next call should create + connect a fresh underlying client.
      await client.status();
      expect(created, hasLength(2));
      expect(connected, [0, 1]);
      expect(disposed, contains(0));
    });

    test('propagates connect failure when the daemon is down', () async {
      final client = build();
      connectShouldFail = true;
      await expectLater(client.status(), throwsA(isA<ControlException>()));
      expect(connected, isEmpty);
    });

    test('recovers once the daemon comes back', () async {
      final client = build();
      connectShouldFail = true;
      await expectLater(client.status(), throwsA(isA<ControlException>()));
      connectShouldFail = false;
      final status = await client.status();
      expect(status.pid, greaterThanOrEqualTo(0));
    });

    test('tailLogs streams through the ensured connection', () async {
      final client = build();
      final lines = await client.tailLogs().toList();
      expect(lines.map((l) => l.line), ['line']);
      expect(connected, [0]);
    });

    test(
      'tailLogs drops the dead client on a stream error, then reconnects',
      () async {
        final client = build();
        // Establish a connection, then kill the underlying socket.
        await client.status();
        created.single.alive = false;
        // The active log stream should error out...
        await expectLater(
          client.tailLogs().toList(),
          throwsA(isA<ControlException>()),
        );
        expect(disposed, contains(0));
        // ...and the next call must connect a fresh underlying client.
        await client.status();
        expect(created, hasLength(2));
        expect(connected, [0, 1]);
      },
    );

    test(
      'close() disposes a client whose connect was still in flight',
      () async {
        // Regression: close() used to only null `_current`, so a connect still
        // in flight would complete afterwards, install a live socket into
        // `_current`, and leak it — the old profile's runtime kept polling after
        // teardown.
        final localCreated = <_FakeClient>[];
        final localDisposed = <int>[];
        final gate = Completer<void>();
        var seq = 0;
        final client = ReconnectingControlClient(
          create: () {
            final c = _FakeClient(seq++);
            localCreated.add(c);
            return c;
          },
          connect: (_) async => gate.future, // stays in flight until released
          dispose: (c) async => localDisposed.add((c as _FakeClient).id),
        );

        // Trigger connect but do not await the call yet.
        final pending = client.status();
        await Future<void>.delayed(Duration.zero);
        expect(localCreated, hasLength(1));

        // Close while the connect is in flight, then let the connect complete.
        final closing = client.close();
        gate.complete();
        await closing;
        await pending.then((_) {}, onError: (_) {});

        // The in-flight client must have been disposed, not retained.
        expect(localDisposed, contains(0));
        // And it is not reused: the next call connects a fresh client.
        await client.status();
        expect(localCreated, hasLength(2));
      },
    );
  });
}
