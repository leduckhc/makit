// Test file colocated under lib/ per SPEC-03 Stream A layout; flutter_test is a
// dev dependency, which is expected here.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pino/control/control_client.dart';
import 'package:pino/control/control_types.dart';
import 'package:pino/store/models.dart';

/// A scripted in-memory [ControlConnection] for tests. Captures every line the
/// client writes and lets the test push server frames back on demand.
class FakeControlConnection implements ControlConnection {
  final _incoming = StreamController<List<int>>();
  final List<String> written = [];

  @override
  Stream<List<int>> get stream => _incoming.stream;

  @override
  void write(String data) => written.add(data);

  /// Push a raw wire line (a trailing newline is added if absent).
  void push(String line) {
    _incoming.add(utf8.encode(line.endsWith('\n') ? line : '$line\n'));
  }

  /// Push a raw chunk exactly as given (no newline added) — for split frames.
  void pushRaw(String chunk) {
    _incoming.add(utf8.encode(chunk));
  }
  /// Simulate the server closing the socket.
  void closeFromServer() {
    unawaited(_incoming.close());
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// The id of the Nth request the client wrote (0-based).
  String requestId(int n) =>
      (jsonDecode(written[n]) as Map<String, dynamic>)['id'] as String;
}

void main() {
  late FakeControlConnection conn;
  late PinoControlClient client;
  var idCounter = 0;

  PinoControlClient makeClient({Duration? timeout}) {
    idCounter = 0;
    conn = FakeControlConnection();
    return PinoControlClient(
      socketPath: '/tmp/pino.sock',
      requestTimeout: timeout ?? const Duration(seconds: 30),
      idGenerator: () => 'c${++idCounter}',
      connector: (_) async => conn,
    );
  }

  tearDown(() async {
    await client.dispose();
  });

  test('connect opens the injected connection', () async {
    client = makeClient();
    await client.connect();
    // A request should now be writable.
    final future = client.request(ControlVerb.status);
    conn.push('{"id":"c1","ok":true,"data":{"pid":1,"uptimeMs":0,"host":"h",'
        '"port":1,"fingerprint":"f","advertiseHost":"a","pairedDevices":0,'
        '"runningSessions":0,"version":"v"}}');
    final res = await future;
    expect(res, isA<ControlOk<Object?>>());
  });

  test('request correlates responses by id', () async {
    client = makeClient();
    await client.connect();

    final first = client.request(ControlVerb.status);
    final second = client.request(ControlVerb.devicesRevoke, args: {'id': 'x'});

    // Respond out of order to prove correlation.
    conn.push('{"id":"c2","ok":true,"data":{"removed":true}}');
    conn.push('{"id":"c1","ok":true,"data":{"pid":9,"uptimeMs":0,"host":"h",'
        '"port":1,"fingerprint":"f","advertiseHost":"a","pairedDevices":0,'
        '"runningSessions":0,"version":"v"}}');

    final secondRes = await second as ControlOk<Object?>;
    final firstRes = await first as ControlOk<Object?>;
    expect((secondRes.data! as DevicesRevokeData).removed, isTrue);
    expect((firstRes.data! as StatusData).pid, 9);
  });

  test('reassembles a frame split across chunks', () async {
    client = makeClient();
    await client.connect();
    final future = client.request(ControlVerb.serverStop);
    conn.pushRaw('{"id":"c1","ok":true,');
    conn.pushRaw('"data":{"stopping":true}}\n');
    final res = await future as ControlOk<Object?>;
    expect((res.data! as ServerStopData).stopping, isTrue);
  });

  test('error responses surface as a ControlErr', () async {
    client = makeClient();
    await client.connect();
    final future = client.request(ControlVerb.status);
    conn.push('{"id":"c1","ok":false,"error":"nope"}');
    final res = await future;
    expect(res, isA<ControlErr<Object?>>());
    expect((res as ControlErr<Object?>).error, 'nope');
  });

  test('request times out when no response arrives', () async {
    client = makeClient(timeout: const Duration(milliseconds: 50));
    await client.connect();
    await expectLater(
      client.request(ControlVerb.status),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('pending requests fail when the socket closes', () async {
    client = makeClient();
    await client.connect();
    final future = client.request(ControlVerb.status);
    conn.closeFromServer();
    await expectLater(future, throwsA(isA<ControlException>()));
  });

  test('connect throws when the socket is missing', () async {
    client = PinoControlClient(
      socketPath: '/tmp/missing.sock',
      connector: (_) async =>
          throw const SocketException('connection refused'),
    );
    await expectLater(client.connect(), throwsA(isA<SocketException>()));
  });

  group('convenience methods', () {
    test('status returns typed StatusData', () async {
      client = makeClient();
      await client.connect();
      final future = client.status();
      conn.push('{"id":"c1","ok":true,"data":{"pid":7,"uptimeMs":5,"host":"h",'
          '"port":2,"fingerprint":"f","advertiseHost":"a","pairedDevices":3,'
          '"runningSessions":1,"version":"1.0"}}');
      final status = await future;
      expect(status.pid, 7);
      expect(status.pairedDevices, 3);
    });

    test('pairMint returns typed PairMintData', () async {
      client = makeClient();
      await client.connect();
      final future = client.pairMint();
      conn.push('{"id":"c1","ok":true,"data":{"url":"pino://x","token":"t",'
          '"expiresAt":9,"fingerprint":"f"}}');
      expect((await future).token, 't');
    });

    test('pairCurrent returns null when there is no active token', () async {
      client = makeClient();
      await client.connect();
      final future = client.pairCurrent();
      conn.push('{"id":"c1","ok":true,"data":null}');
      expect(await future, isNull);
    });

    test('pairCurrent returns typed data when a token exists', () async {
      client = makeClient();
      await client.connect();
      final future = client.pairCurrent();
      conn.push('{"id":"c1","ok":true,"data":{"url":"pino://x","token":"t",'
          '"expiresAt":9}}');
      expect((await future)!.token, 't');
    });

    test('devicesList returns the device list', () async {
      client = makeClient();
      await client.connect();
      final future = client.devicesList();
      conn.push('{"id":"c1","ok":true,"data":{"devices":[{"id":"d1",'
          '"label":"iPhone","pairedAt":1,"lastSeenAt":2,"connected":true}]}}');
      final devices = await future;
      expect(devices.single.id, 'd1');
    });

    test('devicesRevoke returns the removed flag', () async {
      client = makeClient();
      await client.connect();
      final future = client.devicesRevoke('d1');
      expect(conn.written.first.contains('"args":{"id":"d1"}'), isTrue);
      conn.push('{"id":"c1","ok":true,"data":{"removed":true}}');
      expect(await future, isTrue);
    });

    test('sessionsList returns typed sessions', () async {
      client = makeClient();
      await client.connect();
      final future = client.sessionsList();
      conn.push('{"id":"c1","ok":true,"data":{"sessions":[{"id":"s1",'
          '"projectId":"p1","agent":"pi","title":"t","status":"running",'
          '"policy":"yolo","lastActivityAt":0,"lastPreview":""}]}}');
      final sessions = await future;
      expect(sessions.single.id, 's1');
      expect(sessions.single.status, SessionStatus.running);
    });

    test('serverStop completes on a stopping ack', () async {
      client = makeClient();
      await client.connect();
      final future = client.serverStop();
      conn.push('{"id":"c1","ok":true,"data":{"stopping":true}}');
      await future; // must not throw
    });

    test('a convenience method throws on an error response', () async {
      client = makeClient();
      await client.connect();
      final future = client.status();
      conn.push('{"id":"c1","ok":false,"error":"boom"}');
      await expectLater(future, throwsA(isA<ControlException>()));
    });
  });

  group('tailLogs', () {
    test('streams log lines and closes on done', () async {
      client = makeClient();
      await client.connect();
      final lines = <String>[];
      final sub = client.tailLogs(lines: 2).listen((chunk) => lines.add(chunk.line));
      final id = conn.requestId(0);
      conn.push('{"id":"$id","ok":true,"data":{"line":"a"}}');
      conn.push('{"id":"$id","ok":true,"data":{"line":"b"}}');
      conn.push('{"id":"$id","ok":true,"data":{"done":true}}');
      await sub.asFuture<void>();
      expect(lines, ['a', 'b']);
    });

    test('sends follow and lines args', () async {
      client = makeClient();
      await client.connect();
      client.tailLogs(lines: 5, follow: true).listen((_) {});
      final req = jsonDecode(conn.written.first) as Map<String, dynamic>;
      expect(req['verb'], 'logs.tail');
      expect(req['args'], {'lines': 5, 'follow': true});
    });

    test('errors the stream on an error frame', () async {
      client = makeClient();
      await client.connect();
      final done = Completer<void>();
      Object? error;
      client.tailLogs().listen(
        (_) {},
        onError: (Object e) {
          error = e;
          done.complete();
        },
      );
      final id = conn.requestId(0);
      conn.push('{"id":"$id","ok":false,"error":"log fail"}');
      await done.future;
      expect(error, isA<ControlException>());
    });
  });
}
