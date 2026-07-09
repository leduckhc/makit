import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pending-action queue (SPEC-07 replay)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('appends the action to the persisted queue', () async {
      await persistPendingActionForTest('payload-1', 'makit_approve', null);

      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(kPendingActionsKey)!;
      expect(queue, hasLength(1));
      final decoded = jsonDecode(queue.single) as Map<String, dynamic>;
      expect(decoded['payload'], 'payload-1');
      expect(decoded['actionId'], 'makit_approve');
    });

    test(
      'caps the queue to the most recent kMaxPendingActions entries',
      () async {
        for (var i = 0; i < kMaxPendingActions + 20; i++) {
          await persistPendingActionForTest('p$i', 'makit_approve', null);
        }

        final prefs = await SharedPreferences.getInstance();
        final queue = prefs.getStringList(kPendingActionsKey)!;
        expect(queue, hasLength(kMaxPendingActions));
        // Oldest entries dropped; newest retained.
        final first = jsonDecode(queue.first) as Map<String, dynamic>;
        final last = jsonDecode(queue.last) as Map<String, dynamic>;
        expect(first['payload'], 'p20');
        expect(last['payload'], 'p${kMaxPendingActions + 19}');
      },
    );
  });
}
