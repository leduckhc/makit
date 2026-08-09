import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/timing_labels.dart';

ToolCallItem _tool({int ts = 1000, int? endedTs}) => ToolCallItem(
  seq: 1,
  ts: ts,
  callId: 'c',
  name: 'bash',
  args: const {},
  ended: endedTs != null,
  endedTs: endedTs,
);

void main() {
  group('toolDurationState (SPEC-47 D6a/D19)', () {
    test('a finished call uses its own end timestamp', () {
      final s = toolDurationState(
        item: _tool(ts: 1000, endedTs: 4000),
        enclosingTurnCloseTs: null,
        serverNowMs: 999999,
        sessionRunning: false,
      );
      expect(s.ms, 3000);
      expect(s.live, isFalse);
    });

    test('a running call inside a live session ticks off server-now', () {
      final s = toolDurationState(
        item: _tool(ts: 1000),
        enclosingTurnCloseTs: null,
        serverNowMs: 6000,
        sessionRunning: true,
      );
      expect(s.ms, 5000);
      expect(s.live, isTrue);
    });

    test('a backwards live span is unrepresentable (D10b)', () {
      final s = toolDurationState(
        item: _tool(ts: 5000),
        enclosingTurnCloseTs: null,
        serverNowMs: 1000,
        sessionRunning: true,
      );
      expect(s.ms, isNull);
      expect(s.live, isTrue);
    });

    test('a no-end call whose turn closed FREEZES at the idle (D6a)', () {
      final s = toolDurationState(
        item: _tool(ts: 1000),
        enclosingTurnCloseTs: 9000,
        serverNowMs: 999999,
        sessionRunning: false,
      );
      expect(s.ms, 8000);
      expect(s.live, isFalse, reason: 'never a climbing number');
    });

    test(
      'a no-end call in a non-running session with no closed turn shows nothing (D19)',
      () {
        final s = toolDurationState(
          item: _tool(ts: 1000),
          enclosingTurnCloseTs: null,
          serverNowMs: 999999,
          sessionRunning: false,
        );
        expect(s.ms, isNull);
        expect(s.live, isFalse);
      },
    );

    test('a backwards finished span is unrepresentable (D10b)', () {
      final s = toolDurationState(
        item: _tool(ts: 5000, endedTs: 1000),
        enclosingTurnCloseTs: null,
        serverNowMs: 0,
        sessionRunning: false,
      );
      expect(s.ms, isNull);
    });
  });

  group('duration thresholds', () {
    test('the finished floor is exactly 2000 ms (D2)', () {
      expect(kToolDurationFloor, 2000);
      expect(showsFinishedDuration(1999), isFalse);
      expect(showsFinishedDuration(2000), isTrue);
    });

    test('escalation is at 60 s (D6)', () {
      expect(kLiveEscalationMs, 60000);
      expect(escalates(59000), isFalse);
      expect(escalates(60000), isTrue);
    });
  });
}
