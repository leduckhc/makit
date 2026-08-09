import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/live_now.dart';
import 'package:makit/ui/session/tool_call_card.dart';

ToolCallItem _tool({required int ts, int? endedTs, int seq = 4}) =>
    ToolCallItem(
      seq: seq,
      ts: ts,
      callId: 'c$seq',
      name: 'bash',
      args: const {'cmd': 'echo hi'},
      ended: endedTs != null,
      exitCode: endedTs != null ? 0 : null,
      summary: 'echo hi',
      endedTs: endedTs,
    );

Session _session(SessionStatus status) => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 't',
  status: status,
  policy: ApprovalPolicy.askOnRisky,
);

Widget _wrap(ToolCallItem item) => MaterialApp(
  theme: makitDarkTheme,
  home: Scaffold(
    body: ToolCallCard(item: item, sessionId: 's1', expansionKey: 'k'),
  ),
);

void main() {
  testWidgets('a finished call ≥ 2 s shows its duration (D2)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: _wrap(_tool(ts: 0, endedTs: 3000))),
    );
    await tester.pump();
    expect(find.text('3s'), findsOneWidget);
  });

  testWidgets('a finished call under 2 s shows no duration (D2)', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(child: _wrap(_tool(ts: 0, endedTs: 1500))),
    );
    await tester.pump();
    expect(find.text('1.5s'), findsNothing);
  });

  testWidgets(
    'a running call in a live session ticks and escalates past 60 s',
    (tester) async {
      final now = ValueNotifier<int>(6000);
      addTearDown(now.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionsProvider.overrideWithValue(
              SessionsState([_session(SessionStatus.running)]),
            ),
            liveNowProvider(1).overrideWithValue(now),
          ],
          child: _wrap(_tool(ts: 1000)),
        ),
      );
      await tester.pump();
      expect(find.text('5s'), findsOneWidget);

      now.value = 65000; // 64s elapsed
      await tester.pump();
      expect(find.text('1m 04s'), findsOneWidget);

      final label = tester.widget<Text>(find.text('1m 04s'));
      expect(label.style?.color, kStatusWarning, reason: 'D6 escalation');
    },
  );

  testWidgets(
    'an orphaned no-end call in an idle session shows no counter (D19)',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionsProvider.overrideWithValue(
              SessionsState([_session(SessionStatus.idle)]),
            ),
          ],
          child: _wrap(_tool(ts: 1000)),
        ),
      );
      await tester.pump();
      expect(find.text('0s'), findsNothing);
      expect(find.text('1s'), findsNothing);
    },
  );
}
