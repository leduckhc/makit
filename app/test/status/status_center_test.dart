import 'package:flutter_test/flutter_test.dart';
import 'package:makit/diagnostics/log.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';

void main() {
  group('posting', () {
    test('the newest event is first', () {
      final c = StatusCenter();
      c.info('one', source: 'test');
      c.info('two', source: 'test');
      expect(c.events.map((e) => e.title), ['two', 'one']);
    });

    test('each severity has a named entry point', () {
      final c = StatusCenter();
      c.progress('p', source: 't');
      c.info('i', source: 't');
      c.success('s', source: 't');
      c.warning('w', source: 't');
      c.failure('f', source: 't');
      expect(c.events.map((e) => e.severity).toList().reversed, [
        StatusSeverity.progress,
        StatusSeverity.info,
        StatusSeverity.success,
        StatusSeverity.warning,
        StatusSeverity.failure,
      ]);
    });

    test('ids are unique so list keys and dedupe never collide', () {
      final c = StatusCenter();
      for (var i = 0; i < 50; i++) {
        c.info('n$i', source: 't');
      }
      expect(c.events.map((e) => e.id).toSet().length, 50);
    });

    test('failure keeps the exception verbatim in detail, not in the title',
        () {
      final c = StatusCenter();
      c.failure(
        'Could not create worktree',
        error: StateError('File exists, errno = 17'),
        source: 'worktree',
      );
      final e = c.events.single;
      expect(e.title, 'Could not create worktree');
      expect(e.detail, contains('File exists, errno = 17'));
    });

    test('an explicit detail wins over the error object', () {
      final c = StatusCenter();
      c.failure('Nope', error: StateError('raw'), detail: 'curated',
          source: 't');
      expect(c.events.single.detail, 'curated');
    });
  });

  group('ring buffer', () {
    test('evicts the oldest beyond capacity', () {
      final c = StatusCenter(capacity: 3);
      for (var i = 0; i < 5; i++) {
        c.info('$i', source: 't');
      }
      expect(c.events.map((e) => e.title), ['4', '3', '2']);
    });

    test('events is unmodifiable', () {
      final c = StatusCenter();
      c.info('one', source: 't');
      expect(() => c.events.clear(), throwsUnsupportedError);
    });
  });

  group('coalescing', () {
    test('a repeat inside the window bumps count instead of appending', () {
      var now = DateTime(2026, 8, 9, 12, 0, 0);
      final c = StatusCenter(now: () => now);
      c.failure('Could not delete worktree', source: 'worktree');
      now = now.add(const Duration(seconds: 3));
      c.failure('Could not delete worktree', source: 'worktree');
      now = now.add(const Duration(seconds: 3));
      c.failure('Could not delete worktree', source: 'worktree');
      expect(c.events, hasLength(1));
      expect(c.events.single.count, 3);
      expect(c.events.single.displayTitle, 'Could not delete worktree ×3');
    });

    test('the coalesced event slides forward in time and keeps the newest '
        'detail', () {
      var now = DateTime(2026, 8, 9, 12, 0, 0);
      final c = StatusCenter(now: () => now);
      c.failure('Boom', detail: 'first', source: 't');
      now = now.add(const Duration(seconds: 5));
      c.failure('Boom', detail: 'second', source: 't');
      expect(c.events.single.ts, DateTime(2026, 8, 9, 12, 0, 5));
      expect(c.events.single.detail, 'second');
    });

    test('a repeat past the window is its own event', () {
      var now = DateTime(2026, 8, 9, 12, 0, 0);
      final c = StatusCenter(now: () => now);
      c.failure('Boom', source: 't');
      now = now.add(const Duration(seconds: 9));
      c.failure('Boom', source: 't');
      expect(c.events, hasLength(2));
      expect(c.events.every((e) => e.count == 1), isTrue);
    });

    test('only the newest event coalesces — a different event breaks the run',
        () {
      final c = StatusCenter(now: () => DateTime(2026, 8, 9, 12, 0));
      c.failure('Boom', source: 't');
      c.info('Something else', source: 't');
      c.failure('Boom', source: 't');
      expect(c.events, hasLength(3));
    });

    test('a coalesced repeat un-reads the event', () {
      final c = StatusCenter(now: () => DateTime(2026, 8, 9, 12, 0));
      c.failure('Boom', source: 't');
      c.markAllRead();
      expect(c.unreadCount, 0);
      c.failure('Boom', source: 't');
      expect(c.unreadCount, 1);
    });
  });

  group('changes stream', () {
    test('emits a post, flagging whether it coalesced', () async {
      final c = StatusCenter(now: () => DateTime(2026, 8, 9, 12, 0));
      final seen = <StatusChange>[];
      final sub = c.changes.listen(seen.add);
      c.failure('Boom', source: 't');
      c.failure('Boom', source: 't');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, hasLength(2));
      expect((seen[0] as StatusPosted).coalesced, isFalse);
      expect((seen[1] as StatusPosted).coalesced, isTrue);
      expect((seen[1] as StatusPosted).event.count, 2);
    });

    test('emits for markAllRead and clear so badges can follow', () async {
      final c = StatusCenter();
      c.info('one', source: 't');
      final seen = <StatusChange>[];
      final sub = c.changes.listen(seen.add);
      c.markAllRead();
      c.clear();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen.map((e) => e.runtimeType), [StatusReadAll, StatusCleared]);
    });
  });

  group('unread', () {
    test('counts posts and resets on markAllRead', () {
      final c = StatusCenter();
      c.info('one', source: 't');
      c.failure('two', source: 't');
      expect(c.unreadCount, 2);
      c.markAllRead();
      expect(c.unreadCount, 0);
      expect(c.events.every((e) => e.read), isTrue);
    });

    test('a coalesced burst counts once — three failures are one thing to '
        'read', () {
      final c = StatusCenter(now: () => DateTime(2026, 8, 9, 12, 0));
      c.failure('Boom', source: 't');
      c.failure('Boom', source: 't');
      c.failure('Boom', source: 't');
      expect(c.unreadCount, 1);
    });

    test('worstUnread reports the loudest thing you have not seen', () {
      final c = StatusCenter();
      expect(c.worstUnread, isNull);
      c.info('one', source: 't');
      c.failure('two', source: 't');
      expect(c.worstUnread, StatusSeverity.failure);
      c.markAllRead();
      expect(c.worstUnread, isNull);
    });
  });

  group('silent posts (D7)', () {
    test('land on the record but do not count as unread', () {
      final c = StatusCenter();
      c.success('Agent finished its turn',
          source: 'agent', sessionId: 's1', silent: true);
      expect(c.events, hasLength(1));
      expect(c.unreadCount, 0);
      expect(c.worstUnread, isNull);
      expect(c.events.single.read, isTrue);
    });

    test('a loud repeat of a silent event makes it unread', () {
      final c = StatusCenter(now: () => DateTime(2026, 8, 9, 12, 0));
      c.warning('Agent needs your input',
          source: 'agent', sessionId: 's1', silent: true);
      c.warning('Agent needs your input', source: 'agent', sessionId: 's1');
      expect(c.unreadCount, 1);
      expect(c.events.single.count, 2);
    });

    test('the change carries the silent flag so the toast can skip it',
        () async {
      final c = StatusCenter();
      final seen = <StatusChange>[];
      final sub = c.changes.listen(seen.add);
      c.success('quietly', source: 'agent', silent: true);
      c.success('loudly', source: 'agent');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect((seen[0] as StatusPosted).silent, isTrue);
      expect((seen[1] as StatusPosted).silent, isFalse);
    });
  });

  group('clear', () {
    test('drops every event and the unread count', () {
      final c = StatusCenter();
      c.info('one', source: 't');
      c.clear();
      expect(c.events, isEmpty);
      expect(c.unreadCount, 0);
    });
  });

  group('copyAllText', () {
    test('is chronological — a pasted report reads forwards', () {
      var now = DateTime(2026, 8, 9, 12, 0, 0);
      final c = StatusCenter(now: () => now);
      c.info('first', source: 't');
      now = now.add(const Duration(minutes: 1));
      c.failure('second', detail: 'boom', source: 't');
      expect(c.copyAllText(), '''
12:00:00.000 INFO     [t] first
12:01:00.000 FAILURE  [t] second
    boom''');
    });

    test('is empty for an empty center', () {
      expect(StatusCenter().copyAllText(), '');
    });
  });

  group('appLog mirroring (D2)', () {
    test('every event lands in the log with a severity-mapped level', () {
      final log = MakitLog(minLevel: LogLevel.debug);
      final c = StatusCenter(log: log);
      c.info('an info', source: 'pairing');
      c.success('a success', source: 'pairing');
      c.warning('a warning', source: 'pairing');
      c.failure('a failure', detail: 'boom', source: 'pairing');
      expect(log.records.map((r) => r.level), [
        LogLevel.info,
        LogLevel.info,
        LogLevel.warn,
        LogLevel.error,
      ]);
      expect(log.records.every((r) => r.tag == 'status'), isTrue);
      expect(log.records.first.message, '[pairing] an info');
      expect(log.records.last.message, '[pairing] a failure — boom');
    });

    test('a multi-line detail is folded onto one log line', () {
      final log = MakitLog(minLevel: LogLevel.debug);
      StatusCenter(log: log).failure('Boom', detail: 'a\nb', source: 't');
      expect(log.records.single.message, '[t] Boom — a ⏎ b');
    });

    test('works without a log — the core does not require one', () {
      expect(() => StatusCenter().info('fine', source: 't'), returnsNormally);
    });
  });

  test('dispose closes the stream', () async {
    final c = StatusCenter();
    await c.dispose();
    expect(() => c.info('after', source: 't'), returnsNormally);
  });
}
