import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/diagnostics/log.dart';
import 'package:makit/diagnostics/log_uploader.dart';

void main() {
  test(
    'clientLogBody carries kind, platform, optional version and records',
    () {
      final body = clientLogBody(
        platform: 'ios',
        appVersion: '0.1.0',
        records: [
          LogRecord(
            ts: DateTime.fromMillisecondsSinceEpoch(1000),
            level: LogLevel.warn,
            tag: 'ws',
            message: 'hi',
          ),
        ],
      );
      expect(body['kind'], 'client.log');
      expect(body['platform'], 'ios');
      expect(body['appVersion'], '0.1.0');
      expect(body['records'], [
        {'ts': 1000, 'level': 'warn', 'tag': 'ws', 'message': 'hi'},
      ]);
    },
  );

  test('clientLogBody omits appVersion when null', () {
    final body = clientLogBody(platform: 'macos', records: const []);
    expect(body.containsKey('appVersion'), isFalse);
  });

  test('flush sends the buffered records and returns true', () async {
    final log = MakitLog(minLevel: LogLevel.debug);
    final sent = <Map<String, dynamic>>[];
    final up = LogUploader(
      log: log,
      send: (body) async => sent.add(body),
      platform: 'ios',
    );
    addTearDown(up.dispose);
    log.info('t', 'a');
    log.info('t', 'b');
    expect(await up.flush(), isTrue);
    expect(sent.single['records'], hasLength(2));
  });

  test('flush on an empty buffer is a no-op', () async {
    final log = MakitLog(minLevel: LogLevel.debug);
    var calls = 0;
    final up = LogUploader(
      log: log,
      send: (_) async => calls++,
      platform: 'ios',
    );
    addTearDown(up.dispose);
    expect(await up.flush(), isFalse);
    expect(calls, 0);
  });

  test('flush caps the payload to maxRecordsPerUpload (newest kept)', () async {
    final log = MakitLog(minLevel: LogLevel.debug);
    Map<String, dynamic>? body;
    final up = LogUploader(
      log: log,
      send: (b) async => body = b,
      platform: 'ios',
      maxRecordsPerUpload: 2,
    );
    addTearDown(up.dispose);
    for (var i = 0; i < 5; i++) {
      log.info('t', '$i');
    }
    await up.flush();
    final recs = body!['records'] as List;
    expect(recs.map((r) => (r as Map)['message']), ['3', '4']);
  });

  test('a concurrent flush collapses to one in-flight send', () async {
    final log = MakitLog(minLevel: LogLevel.debug);
    var calls = 0;
    final gate = Completer<void>();
    final up = LogUploader(
      log: log,
      send: (_) async {
        calls++;
        await gate.future;
      },
      platform: 'ios',
    );
    addTearDown(up.dispose);
    log.info('t', 'x');
    final first = up.flush();
    final second = up.flush(); // in-flight → no-op
    expect(await second, isFalse);
    gate.complete();
    expect(await first, isTrue);
    expect(calls, 1);
  });

  test('an error record schedules a debounced auto-flush', () {
    fakeAsync((async) {
      final log = MakitLog(minLevel: LogLevel.debug);
      var calls = 0;
      final up = LogUploader(
        log: log,
        send: (_) async => calls++,
        platform: 'ios',
        autoFlushDelay: const Duration(seconds: 3),
      );
      log.error('flutter', 'boom');
      expect(calls, 0, reason: 'debounced, not immediate');
      async.elapse(const Duration(seconds: 3));
      expect(calls, 1);
      up.dispose();
    });
  });

  test('non-error records never auto-flush', () {
    fakeAsync((async) {
      final log = MakitLog(minLevel: LogLevel.debug);
      var calls = 0;
      final up = LogUploader(
        log: log,
        send: (_) async => calls++,
        platform: 'ios',
      );
      log.info('t', 'noise');
      log.warn('t', 'still noise');
      async.elapse(const Duration(minutes: 1));
      expect(calls, 0);
      up.dispose();
    });
  });
}
