import 'package:flutter_test/flutter_test.dart';
import 'package:pino/notifications/notification_policy.dart';
import 'package:pino/store/models.dart';

void main() {
  group('notificationFor', () {
    const label = 'my-project';

    test('running → idle notifies "finished"', () {
      final n = notificationFor(
        from: SessionStatus.running,
        to: SessionStatus.idle,
        sessionLabel: label,
      );
      expect(n, isNotNull);
      expect(n!.title, label);
      expect(n.body, contains('finished'));
    });

    test('running → exited notifies "finished"', () {
      final n = notificationFor(
        from: SessionStatus.running,
        to: SessionStatus.exited,
        sessionLabel: label,
      );
      expect(n?.body, contains('finished'));
    });

    test('idle → idle is silent (no change)', () {
      expect(
        notificationFor(
          from: SessionStatus.idle,
          to: SessionStatus.idle,
          sessionLabel: label,
        ),
        isNull,
      );
    });

    test('null → idle is silent (never worked)', () {
      expect(
        notificationFor(from: null, to: SessionStatus.idle, sessionLabel: label),
        isNull,
      );
    });

    test('idle → idle repeat silent even when never ran', () {
      // idle → exited without a prior running is NOT a "finish".
      expect(
        notificationFor(
          from: SessionStatus.idle,
          to: SessionStatus.exited,
          sessionLabel: label,
        ),
        isNull,
      );
    });

    test('* → awaitingInput notifies "needs your input"', () {
      final n = notificationFor(
        from: SessionStatus.running,
        to: SessionStatus.awaitingInput,
        sessionLabel: label,
      );
      expect(n?.body, contains('input'));
    });

    test('null → awaitingApproval notifies "needs your approval"', () {
      final n = notificationFor(
        from: null,
        to: SessionStatus.awaitingApproval,
        sessionLabel: label,
      );
      expect(n?.body, contains('approval'));
    });

    test('* → error notifies "hit an error"', () {
      final n = notificationFor(
        from: SessionStatus.running,
        to: SessionStatus.error,
        sessionLabel: label,
      );
      expect(n?.body, contains('error'));
    });

    test('anything → running is silent', () {
      expect(
        notificationFor(
          from: SessionStatus.idle,
          to: SessionStatus.running,
          sessionLabel: label,
        ),
        isNull,
      );
    });
  });

  group('diffStatusNotifications', () {
    test('fires only for sessions whose status changed meaningfully', () {
      final result = diffStatusNotifications(
        previous: {'a': SessionStatus.running, 'b': SessionStatus.idle},
        current: [
          // a: running → idle  => finished
          const SessionStatusSnapshot(
            sessionId: 'a',
            status: SessionStatus.idle,
            label: 'proj-a',
          ),
          // b: idle → idle      => silent
          const SessionStatusSnapshot(
            sessionId: 'b',
            status: SessionStatus.idle,
            label: 'proj-b',
          ),
          // c: null → awaitingInput => needs input
          const SessionStatusSnapshot(
            sessionId: 'c',
            status: SessionStatus.awaitingInput,
            label: 'proj-c',
          ),
        ],
      );
      expect(result.map((p) => p.sessionId), ['a', 'c']);
      expect(result.first.content.body, contains('finished'));
      expect(result.last.content.body, contains('input'));
    });

    test('empty when nothing changed', () {
      final result = diffStatusNotifications(
        previous: {'a': SessionStatus.running},
        current: [
          const SessionStatusSnapshot(
            sessionId: 'a',
            status: SessionStatus.running,
            label: 'proj-a',
          ),
        ],
      );
      expect(result, isEmpty);
    });
  });
}
