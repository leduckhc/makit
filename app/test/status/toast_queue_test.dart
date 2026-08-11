import 'package:flutter_test/flutter_test.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/toast_queue.dart';

void main() {
  group('dwell', () {
    test('escalates with severity and nothing is sticky', () {
      expect(toastDwell(StatusSeverity.info), const Duration(seconds: 3));
      expect(toastDwell(StatusSeverity.success), const Duration(seconds: 3));
      expect(toastDwell(StatusSeverity.progress), const Duration(seconds: 4));
      expect(toastDwell(StatusSeverity.warning), const Duration(seconds: 6));
      expect(toastDwell(StatusSeverity.failure), const Duration(seconds: 8));
    });
  });

  group('visibility', () {
    test('shows at most three, newest first', () {
      final q = ToastQueue();
      for (var i = 0; i < 5; i++) {
        q.push(_event(id: 'e$i', title: 'n$i'));
      }
      expect(q.visible.map((e) => e.title), ['n4', 'n3', 'n2']);
      expect(q.overflow, 2);
    });

    test('overflow is zero below the cap', () {
      final q = ToastQueue();
      q.push(_event(id: 'a'));
      expect(q.overflow, 0);
    });

    test('dismissing one promotes the next', () {
      final q = ToastQueue();
      for (var i = 0; i < 4; i++) {
        q.push(_event(id: 'e$i', title: 'n$i'));
      }
      q.dismiss('e3');
      expect(q.visible.map((e) => e.title), ['n2', 'n1', 'n0']);
      expect(q.overflow, 0);
    });

    test('dismissing an unknown id is a no-op', () {
      final q = ToastQueue();
      q.push(_event(id: 'a'));
      q.dismiss('nope');
      expect(q.visible, hasLength(1));
    });
  });

  group('coalesced repeats', () {
    test('update in place instead of stacking a second toast', () {
      final q = ToastQueue();
      q.push(_event(id: 'a', title: 'Boom'));
      q.push(_event(id: 'b', title: 'Other'));
      final isNew = q.push(_event(id: 'a', title: 'Boom', count: 2));
      expect(isNew, isFalse);
      expect(q.visible, hasLength(2));
      // Keeps its slot: an updating count must not make rows jump around.
      expect(q.visible.map((e) => e.id), ['b', 'a']);
      expect(q.visible.last.count, 2);
    });

    test('a repeat whose toast already expired comes back as new', () {
      final q = ToastQueue();
      q.push(_event(id: 'a', title: 'Boom'));
      q.dismiss('a');
      expect(q.push(_event(id: 'a', title: 'Boom', count: 2)), isTrue);
      expect(q.visible, hasLength(1));
    });
  });

  test('clear empties the layer', () {
    final q = ToastQueue();
    q.push(_event(id: 'a'));
    q.push(_event(id: 'b'));
    q.clear();
    expect(q.visible, isEmpty);
    expect(q.overflow, 0);
  });
}

StatusEvent _event({
  String id = 'e1',
  String title = 'Something happened',
  StatusSeverity severity = StatusSeverity.info,
  int count = 1,
}) => StatusEvent(
  id: id,
  ts: DateTime(2026, 8, 9, 12, 0),
  severity: severity,
  title: title,
  source: 'test',
  count: count,
);
