import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:makit/notifications/notification_request.dart';
import 'package:makit/notifications/notification_service.dart';
import 'package:makit/notifications/pending_action_drain.dart';

/// Build a raw queue entry exactly as `notificationBackgroundHandler` writes.
String queued({
  required String requestId,
  required String kind,
  required String actionId,
  String sessionId = 's1',
  String? input,
}) => jsonEncode({
  'payload': encodeRequestPayload(
    sessionId: sessionId,
    requestId: requestId,
    kind: kind,
  ),
  'actionId': actionId,
  'input': input,
});

void main() {
  group('planDrain (B1)', () {
    test('maps queued approve/deny/reply taps to responses in FIFO order', () {
      final plan = planDrain([
        queued(
          requestId: 'r1',
          kind: 'confirmAction',
          actionId: kApproveActionId,
        ),
        queued(
          requestId: 'r2',
          kind: 'askUserQuestion',
          actionId: kReplyActionId,
          input: 'yes',
        ),
      ]);

      expect(plan.length, 2);
      expect(plan[0].requestId, 'r1');
      expect(plan[0].body, {'kind': 'confirmAction', 'approved': true});
      expect(plan[1].requestId, 'r2');
      expect(plan[1].body, {
        'kind': 'askUserQuestion',
        'answers': ['yes'],
        'answer': 'yes',
        'indices': [-1],
      });
    });

    test('skips entries with unknown action, missing rid, or garbage JSON', () {
      final plan = planDrain([
        // unknown action
        queued(requestId: 'r1', kind: 'confirmAction', actionId: 'bogus'),
        // missing rid (bare sessionId payload → no requestId)
        jsonEncode({'payload': 'session-only', 'actionId': kApproveActionId}),
        // garbage
        'not json at all',
        // action/kind mismatch (reply on a confirmAction)
        queued(
          requestId: 'r4',
          kind: 'confirmAction',
          actionId: kReplyActionId,
        ),
        // valid — survives
        queued(requestId: 'r5', kind: 'confirmAction', actionId: kDenyActionId),
      ]);

      expect(plan.length, 1);
      expect(plan[0].requestId, 'r5');
      expect(plan[0].body, {'kind': 'confirmAction', 'approved': false});
    });
  });

  group('PendingActionDrainer (B2)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('drainer replays each queued action then clears the key', () async {
      SharedPreferences.setMockInitialValues({
        kPendingActionsKey: [
          queued(
            requestId: 'r1',
            kind: 'confirmAction',
            actionId: kApproveActionId,
          ),
          queued(
            requestId: 'r2',
            kind: 'askUserQuestion',
            actionId: kReplyActionId,
            input: 'ship it',
          ),
        ],
      });
      final prefs = await SharedPreferences.getInstance();

      final calls = <(String, Map<String, dynamic>)>[];
      final drainer = PendingActionDrainer(
        prefs,
        (rid, body) => calls.add((rid, body)),
      );
      await drainer.drain();

      expect(calls.length, 2);
      expect(calls[0].$1, 'r1');
      expect(calls[0].$2, {'kind': 'confirmAction', 'approved': true});
      expect(calls[1].$1, 'r2');
      expect(calls[1].$2['answers'], ['ship it']);
      expect(
        prefs.getStringList(kPendingActionsKey) ?? const <String>[],
        isEmpty,
      );

      // Idempotent: a re-run is a no-op because the queue was cleared. (The
      // real respondTo also guards via `_respondedRequests` — SPEC-actionable-notifications step 4.)
      final callsBefore = calls.length;
      await drainer.drain();
      expect(calls.length, callsBefore);
    });

    test('empty queue is a no-op', () async {
      final prefs = await SharedPreferences.getInstance();
      var called = false;
      final drainer = PendingActionDrainer(prefs, (_, _) => called = true);
      await drainer.drain();
      expect(called, isFalse);
    });
  });
}
