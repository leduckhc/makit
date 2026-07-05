// Unit tests for the reconnecting control-client decorator.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pino/control/control_contract.dart';
import 'package:pino/control/reconnecting_control_client.dart';

/// A fake underlying client. Fails all verbs once [alive] is false, mimicking a
/// disposed [PinoControlClient] after its socket closed.
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
    return _guard(StatusData(
      pid: id,
      uptimeMs: 0,
      host: 'h',
      port: 1,
      fingerprint: 'f',
      advertiseHost: 'h',
      pairedDevices: 0,
      runningSessions: 0,
      version: 'v',
    ));
  }

  @override
  Future<List<DeviceInfo>> devicesList() => _guard(const []);
  @override
  Future<bool> devicesRevoke(String id) => _guard(true);
  @override
  Future<PairCurrentData?> pairCurrent() => _guard(null);
  @override
  Future<PairMintData> pairMint({int? ttlMs}) =>
      _guard(const PairMintData(url: 'u', token: 't', expiresAt: 0, fingerprint: 'f'));
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
  });
}
