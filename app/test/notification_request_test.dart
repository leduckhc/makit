import 'package:flutter_test/flutter_test.dart';
import 'package:pino/notifications/notification_request.dart';

void main() {
  group('notificationForRequest (step 1)', () {
    const label = 'my-project';

    test('confirmAction → confirm category with action in body', () {
      final n = notificationForRequest(
        kind: 'confirmAction',
        body: {'kind': 'confirmAction', 'action': 'rm -rf build/'},
        label: label,
      );
      expect(n, isNotNull);
      expect(n!.category, kConfirmCategoryId);
      expect(n.title, label);
      expect(n.body, contains('rm -rf build/'));
    });

    test('askUserQuestion (single form) → question category + first question',
        () {
      final n = notificationForRequest(
        kind: 'askUserQuestion',
        body: {'kind': 'askUserQuestion', 'question': 'Deploy to prod?'},
        label: label,
      );
      expect(n, isNotNull);
      expect(n!.category, kQuestionCategoryId);
      expect(n.body, contains('Deploy to prod?'));
    });

    test('askUserQuestion (wizard form) → question category + first question',
        () {
      final n = notificationForRequest(
        kind: 'askUserQuestion',
        body: {
          'kind': 'askUserQuestion',
          'questions': [
            {'question': 'Pick a branch'},
            {'question': 'ignored second'},
          ],
        },
        label: label,
      );
      expect(n, isNotNull);
      expect(n!.category, kQuestionCategoryId);
      expect(n.body, contains('Pick a branch'));
    });

    test('input kind → null', () {
      final n = notificationForRequest(
        kind: 'input',
        body: {'kind': 'input'},
        label: label,
      );
      expect(n, isNull);
    });

    test('unknown kind → null', () {
      final n = notificationForRequest(
        kind: 'somethingElse',
        body: {'kind': 'somethingElse'},
        label: label,
      );
      expect(n, isNull);
    });
  });

  group('responseForAction (step 2)', () {
    test('approve → {approved:true}', () {
      final r = responseForAction(
        kind: 'confirmAction',
        actionId: kApproveActionId,
      );
      expect(r, {'approved': true});
    });

    test('deny → {approved:false}', () {
      final r = responseForAction(
        kind: 'confirmAction',
        actionId: kDenyActionId,
      );
      expect(r, {'approved': false});
    });

    test('reply + input → answers/answer/indices', () {
      final r = responseForAction(
        kind: 'askUserQuestion',
        actionId: kReplyActionId,
        input: 'ship it',
      );
      expect(r, {
        'answers': ['ship it'],
        'answer': 'ship it',
        'indices': [-1],
      });
    });

    test('reply + null input → empty-string answer', () {
      final r = responseForAction(
        kind: 'askUserQuestion',
        actionId: kReplyActionId,
      );
      expect(r, {
        'answers': [''],
        'answer': '',
        'indices': [-1],
      });
    });

    test('unknown action → null', () {
      final r = responseForAction(kind: 'confirmAction', actionId: 'nope');
      expect(r, isNull);
    });
  });

  group('payload codec (step 3)', () {
    test('round-trips sessionId/requestId/kind', () {
      final raw = encodeRequestPayload(
        sessionId: 's1',
        requestId: 'r1',
        kind: 'confirmAction',
      );
      final p = parseNotificationPayload(raw);
      expect(p.sessionId, 's1');
      expect(p.requestId, 'r1');
      expect(p.kind, 'confirmAction');
    });

    test('legacy bare sessionId parses as sessionId-only', () {
      final p = parseNotificationPayload('session-abc');
      expect(p.sessionId, 'session-abc');
      expect(p.requestId, isNull);
      expect(p.kind, isNull);
    });

    test('garbage → all null', () {
      final p = parseNotificationPayload(null);
      expect(p.sessionId, isNull);
      expect(p.requestId, isNull);
      expect(p.kind, isNull);

      final empty = parseNotificationPayload('');
      expect(empty.sessionId, isNull);
      expect(empty.requestId, isNull);
      expect(empty.kind, isNull);
    });
  });
}
