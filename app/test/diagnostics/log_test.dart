import 'package:flutter_test/flutter_test.dart';
import 'package:makit/diagnostics/log.dart';

class _CapturingSink implements LogSink {
  final List<LogRecord> records = [];
  @override
  void add(LogRecord record) => records.add(record);
}

class _ThrowingSink implements LogSink {
  @override
  void add(LogRecord record) => throw StateError('sink boom');
}

void main() {
  group('MakitLog level gating', () {
    test('drops records below minLevel', () {
      final log = MakitLog(minLevel: LogLevel.warn);
      log.debug('t', 'd');
      log.info('t', 'i');
      log.warn('t', 'w');
      log.error('t', 'e');
      expect(log.records.map((r) => r.level), [LogLevel.warn, LogLevel.error]);
    });

    test('info is the default level', () {
      final log = MakitLog();
      log.debug('t', 'nope');
      log.info('t', 'yes');
      expect(log.records.single.message, 'yes');
    });
  });

  test('the ring buffer evicts oldest beyond capacity', () {
    final log = MakitLog(capacity: 3, minLevel: LogLevel.debug);
    for (var i = 0; i < 5; i++) {
      log.info('t', '$i');
    }
    expect(log.records.map((r) => r.message), ['2', '3', '4']);
  });

  test('the stream emits every accepted record', () async {
    final log = MakitLog(minLevel: LogLevel.debug);
    final seen = <String>[];
    final sub = log.stream.listen((r) => seen.add(r.message));
    log.info('t', 'a');
    log.warn('t', 'b');
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['a', 'b']);
    await sub.cancel();
    await log.dispose();
  });

  test('sinks receive accepted records; a gated record reaches nothing', () {
    final log = MakitLog(minLevel: LogLevel.info);
    final sink = _CapturingSink();
    log.addSink(sink);
    log.debug('t', 'gated');
    log.warn('t', 'kept');
    expect(sink.records.map((r) => r.message), ['kept']);
  });

  test('addSink returns a disposer that unregisters', () {
    final log = MakitLog(minLevel: LogLevel.debug);
    final sink = _CapturingSink();
    final remove = log.addSink(sink);
    log.info('t', 'first');
    remove();
    log.info('t', 'second');
    expect(sink.records.map((r) => r.message), ['first']);
  });

  test('a throwing sink never breaks logging or other sinks', () {
    final log = MakitLog(minLevel: LogLevel.debug);
    final good = _CapturingSink();
    log.addSink(_ThrowingSink());
    log.addSink(good);
    expect(() => log.info('t', 'ok'), returnsNormally);
    expect(good.records.single.message, 'ok');
    expect(log.records.single.message, 'ok');
  });

  test('toJson uses epoch millis and wire tokens', () {
    final rec = LogRecord(
      ts: DateTime.fromMillisecondsSinceEpoch(1710000000000),
      level: LogLevel.warn,
      tag: 'ws',
      message: 'hi',
    );
    expect(rec.toJson(), {
      'ts': 1710000000000,
      'level': 'warn',
      'tag': 'ws',
      'message': 'hi',
    });
  });

  test('toLine is a compact, greppable human line', () {
    final rec = LogRecord(
      ts: DateTime.utc(2024, 1, 1, 12, 34, 56, 789),
      level: LogLevel.error,
      tag: 'flutter',
      message: 'boom',
    );
    expect(rec.toLine(), '12:34:56.789Z ERROR [flutter] boom');
  });

  test('LogLevel round-trips through its wire token', () {
    for (final l in LogLevel.values) {
      expect(LogLevel.fromWire(l.wire), l);
    }
    expect(LogLevel.fromWire('nonsense'), LogLevel.info);
  });
}
