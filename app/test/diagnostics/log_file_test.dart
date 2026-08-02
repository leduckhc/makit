import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/diagnostics/log.dart';
import 'package:makit/diagnostics/log_file.dart';

LogRecord _rec(String message, {LogLevel level = LogLevel.info}) => LogRecord(
  ts: DateTime.utc(2024, 1, 1, 0, 0, 0),
  level: level,
  tag: 't',
  message: message,
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('makit_log_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('write policy (keeps logging off the hot path)', () {
    test('info/debug lines are buffered, not written immediately', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file);
      sink.add(_rec('routine', level: LogLevel.info));
      sink.add(_rec('chatter', level: LogLevel.debug));
      expect(
        file.existsSync(),
        isFalse,
        reason: 'no synchronous disk write on the routine path',
      );
      expect(sink.pendingCount, 2);
    });

    test('a warn flushes immediately and synchronously', () {
      final file = File('${dir.path}/makit.log');
      RollingFileLogSink(file).add(_rec('careful', level: LogLevel.warn));
      expect(file.readAsStringSync(), contains('careful'));
    });

    test('an error flushes immediately — the crash line reaches disk', () {
      final file = File('${dir.path}/makit.log');
      RollingFileLogSink(
        file,
      ).add(_rec('_dependents.isEmpty', level: LogLevel.error));
      expect(file.readAsStringSync(), contains('_dependents.isEmpty'));
    });

    test('an error flush also lands the buffered breadcrumbs, in order', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file);
      sink.add(_rec('breadcrumb-1'));
      sink.add(_rec('breadcrumb-2'));
      sink.add(_rec('fatal', level: LogLevel.error));
      final text = file.readAsStringSync();
      expect(
        text.indexOf('breadcrumb-1'),
        lessThan(text.indexOf('breadcrumb-2')),
      );
      expect(text.indexOf('breadcrumb-2'), lessThan(text.indexOf('fatal')));
      expect(sink.pendingCount, 0);
    });

    test('buffered lines flush on the timer', () {
      fakeAsync((async) {
        final file = File('${dir.path}/makit.log');
        final sink = RollingFileLogSink(
          file,
          flushEvery: const Duration(seconds: 1),
        );
        sink.add(_rec('later'));
        expect(file.existsSync(), isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(file.readAsStringSync(), contains('later'));
        expect(sink.pendingCount, 0);
      });
    });

    test('a burst flushes early at maxPendingLines (bounded buffer)', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file, maxPendingLines: 3);
      sink.add(_rec('a'));
      sink.add(_rec('b'));
      expect(file.existsSync(), isFalse);
      sink.add(_rec('c')); // hits the cap → flush
      expect(sink.pendingCount, 0);
      expect(file.readAsLinesSync().length, 3);
    });

    test('dispose flushes what is still pending', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file)..add(_rec('unwritten'));
      expect(file.existsSync(), isFalse);
      sink.dispose();
      expect(file.readAsStringSync(), contains('unwritten'));
    });

    test('readAll flushes first, so an export never misses recent lines', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file)..add(_rec('just happened'));
      expect(sink.readAll(), contains('just happened'));
    });

    test('flush on an empty buffer touches nothing', () {
      final file = File('${dir.path}/makit.log');
      RollingFileLogSink(file).flush();
      expect(file.existsSync(), isFalse);
    });
  });

  group('rotation and retention', () {
    test('appends each record as a line and creates the parent dir', () {
      final file = File('${dir.path}/nested/makit.log');
      final sink = RollingFileLogSink(file);
      sink.add(_rec('one'));
      sink.add(_rec('two'));
      sink.flush();
      final lines = file.readAsLinesSync();
      expect(lines.length, 2);
      expect(lines[0], endsWith('[t] one'));
      expect(lines[1], endsWith('[t] two'));
    });

    test('rotates to a .1 backup once past maxBytes and keeps writing', () {
      final file = File('${dir.path}/makit.log');
      // Each line is well over 10 bytes, so the second flush forces a rotation.
      final sink = RollingFileLogSink(file, maxBytes: 10);
      sink.add(_rec('first'));
      sink.flush();
      sink.add(_rec('second'));
      sink.flush();
      expect(File('${file.path}.1').existsSync(), isTrue);
      expect(File('${file.path}.1').readAsStringSync(), contains('first'));
      expect(file.readAsStringSync(), contains('second'));
    });

    test('readAll returns backup then active, oldest to newest', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file, maxBytes: 10);
      sink.add(_rec('old'));
      sink.flush();
      sink.add(_rec('new'));
      final all = sink.readAll();
      expect(all.indexOf('old'), lessThan(all.indexOf('new')));
    });

    test('a fresh sink appends to (does not truncate) an existing file', () {
      final file = File('${dir.path}/makit.log')
        ..writeAsStringSync('prior line\n');
      RollingFileLogSink(file)
        ..add(_rec('after restart'))
        ..flush();
      final lines = file.readAsLinesSync();
      expect(lines.first, 'prior line');
      expect(lines.last, endsWith('after restart'));
    });

    test('rotation never keeps more than two files', () {
      final file = File('${dir.path}/makit.log');
      final sink = RollingFileLogSink(file, maxBytes: 10);
      for (var i = 0; i < 6; i++) {
        sink.add(_rec('line$i'));
        sink.flush();
      }
      final files = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(files.toSet(), {'makit.log', 'makit.log.1'});
    });
  });
}
