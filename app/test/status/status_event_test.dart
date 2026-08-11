import 'package:flutter_test/flutter_test.dart';
import 'package:makit/status/status_event.dart';

void main() {
  group('severity ordering', () {
    test('ascends by how much it deserves your attention later', () {
      // The Activity filter is a threshold ("warnings and worse"), exactly like
      // the Diagnostics level filter, so the declaration order is load-bearing.
      expect(StatusSeverity.values, [
        StatusSeverity.progress,
        StatusSeverity.info,
        StatusSeverity.success,
        StatusSeverity.warning,
        StatusSeverity.failure,
      ]);
    });

    test('atLeast compares by declaration order', () {
      expect(StatusSeverity.failure.atLeast(StatusSeverity.warning), isTrue);
      expect(StatusSeverity.info.atLeast(StatusSeverity.warning), isFalse);
      expect(StatusSeverity.warning.atLeast(StatusSeverity.warning), isTrue);
    });
  });

  group('detail', () {
    test('hasDetail is false for null and for whitespace', () {
      expect(_event(detail: null).hasDetail, isFalse);
      expect(_event(detail: '').hasDetail, isFalse);
      expect(_event(detail: '   \n ').hasDetail, isFalse);
      expect(_event(detail: 'boom').hasDetail, isTrue);
    });
  });

  group('displayTitle', () {
    test('is the bare title when nothing coalesced', () {
      expect(_event().displayTitle, 'Could not create worktree');
    });

    test('carries the repeat count once coalesced', () {
      expect(_event(count: 3).displayTitle, 'Could not create worktree ×3');
    });
  });

  group('toClipboardText', () {
    test('reads as a sibling of LogRecord.toLine()', () {
      final e = _event(ts: DateTime(2026, 8, 9, 12, 34, 56, 789), detail: null);
      expect(
        e.toClipboardText(),
        '12:34:56.789 FAILURE  [worktree] Could not create worktree',
      );
    });

    test('indents every detail line under the title', () {
      final e = _event(
        ts: DateTime(2026, 8, 9, 12, 34, 56, 789),
        detail: 'FileSystemException: Creation failed\nerrno = 17',
      );
      expect(e.toClipboardText(), '''
12:34:56.789 FAILURE  [worktree] Could not create worktree
    FileSystemException: Creation failed
    errno = 17''');
    });

    test('shows the repeat count so a copied burst is not silently one', () {
      final e = _event(ts: DateTime(2026, 8, 9, 12, 34, 56, 789), count: 3);
      expect(
        e.toClipboardText(),
        '12:34:56.789 FAILURE  [worktree] Could not create worktree ×3',
      );
    });

    test('pads the severity column so titles line up', () {
      final e = _event(
        ts: DateTime(2026, 8, 9, 1, 2, 3, 4),
        severity: StatusSeverity.info,
        title: 'URL copied',
      );
      expect(
        e.toClipboardText(),
        '01:02:03.004 INFO     [worktree] URL copied',
      );
    });
  });

  group('coalescesWith', () {
    test('matches on severity, title and source', () {
      expect(_event().coalescesWith(_event()), isTrue);
      expect(_event().coalescesWith(_event(title: 'Other')), isFalse);
      expect(_event().coalescesWith(_event(source: 'ports')), isFalse);
      expect(
        _event().coalescesWith(_event(severity: StatusSeverity.warning)),
        isFalse,
      );
    });

    test('ignores detail — two different exceptions are still one burst', () {
      // Deliberate: three failed deletes each carry a different path in $e, but
      // the user wants one line saying it happened three times, and the detail
      // of the newest is the one worth keeping.
      expect(_event(detail: 'a').coalescesWith(_event(detail: 'b')), isTrue);
    });

    test('never coalesces across sessions', () {
      expect(
        _event(sessionId: 's1').coalescesWith(_event(sessionId: 's2')),
        isFalse,
      );
    });
  });
}

StatusEvent _event({
  String id = 'e1',
  DateTime? ts,
  StatusSeverity severity = StatusSeverity.failure,
  String title = 'Could not create worktree',
  String? detail,
  String source = 'worktree',
  String? sessionId,
  int count = 1,
  bool read = false,
}) => StatusEvent(
  id: id,
  ts: ts ?? DateTime(2026, 8, 9, 12, 0),
  severity: severity,
  title: title,
  detail: detail,
  source: source,
  sessionId: sessionId,
  count: count,
  read: read,
);
