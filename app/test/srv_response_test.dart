import 'package:flutter_test/flutter_test.dart';
import 'package:makit/notifications/notification_request.dart';

/// SPEC-boundary-hardening T4: lock the canonical `srv.response` body shapes emitted by the
/// shared [SrvResponse] builder, and prove the notification-action path
/// ([responseForAction]) builds byte-identical shapes — so the dialog and
/// notification answer paths can never drift.
void main() {
  group('SrvResponse builder shapes', () {
    test('confirmAction(approved: true/false)', () {
      expect(SrvResponse.confirmAction(approved: true), {
        'kind': 'confirmAction',
        'approved': true,
      });
      expect(SrvResponse.confirmAction(approved: false), {
        'kind': 'confirmAction',
        'approved': false,
      });
    });

    test('askUserQuestion(indices, answers) omits answer when null', () {
      expect(
        SrvResponse.askUserQuestion(indices: [0, 2], answers: ['a', 'b']),
        {
          'kind': 'askUserQuestion',
          'indices': [0, 2],
          'answers': ['a', 'b'],
        },
      );
    });

    test('askUserQuestion includes answer when provided', () {
      expect(
        SrvResponse.askUserQuestion(
          indices: [1],
          answers: ['yes'],
          answer: 'yes',
        ),
        {
          'kind': 'askUserQuestion',
          'indices': [1],
          'answers': ['yes'],
          'answer': 'yes',
        },
      );
    });

    test('input(value)', () {
      expect(SrvResponse.input('hello'), {'kind': 'input', 'value': 'hello'});
    });

    test('cancelled(askUserQuestion) carries empty indices/answers', () {
      expect(SrvResponse.cancelled('askUserQuestion'), {
        'kind': 'askUserQuestion',
        'indices': <int>[],
        'answers': <String>[],
        'cancelled': true,
      });
    });

    test('cancelled(input) carries just the flag', () {
      expect(SrvResponse.cancelled('input'), {
        'kind': 'input',
        'cancelled': true,
      });
    });
  });

  group('notification path uses the same shapes as the builder', () {
    test('approve == SrvResponse.confirmAction(true)', () {
      expect(
        responseForAction(kind: 'confirmAction', actionId: kApproveActionId),
        SrvResponse.confirmAction(approved: true),
      );
    });

    test('deny == SrvResponse.confirmAction(false)', () {
      expect(
        responseForAction(kind: 'confirmAction', actionId: kDenyActionId),
        SrvResponse.confirmAction(approved: false),
      );
    });

    test(
      'reply == SrvResponse.askUserQuestion(indices:[-1], answers:[text])',
      () {
        expect(
          responseForAction(
            kind: 'askUserQuestion',
            actionId: kReplyActionId,
            input: 'ship it',
          ),
          SrvResponse.askUserQuestion(
            indices: [-1],
            answers: ['ship it'],
            answer: 'ship it',
          ),
        );
      },
    );
  });
}
