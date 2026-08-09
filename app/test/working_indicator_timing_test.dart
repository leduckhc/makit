import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/live_now.dart';

SessionEvent _ev(int seq, EventKind k, Map<String, dynamic> p) => SessionEvent(
  seq: seq,
  sessionId: 's1',
  ts: seq * 1000,
  kind: k,
  payload: p,
);

void main() {
  testWidgets('the working indicator shows a live turn counter (D8)', (
    tester,
  ) async {
    final now = ValueNotifier<int>(48000);
    addTearDown(now.dispose);
    final events = EventsState({
      's1': [
        _ev(1, EventKind.userMessage, {'text': 'go'}),
        _ev(2, EventKind.sessionStatus, {'status': 'running'}),
      ],
    }, const {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          eventsProvider.overrideWithValue(events),
          liveNowProvider(1).overrideWithValue(now),
        ],
        child: MaterialApp(
          theme: makitDarkTheme,
          home: const Scaffold(body: WorkingIndicator(sessionId: 's1')),
        ),
      ),
    );
    await tester.pump();
    // Turn opened at ts 1000; server now 48000 → 47s.
    expect(find.text('47s'), findsOneWidget);

    now.value = 60000; // 59s
    await tester.pump();
    expect(find.text('59s'), findsOneWidget);
  });

  testWidgets('no counter when there is no open turn', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        ],
        child: MaterialApp(
          theme: makitDarkTheme,
          home: const Scaffold(body: WorkingIndicator(sessionId: 's1')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ValueListenableBuilder<int>), findsNothing);
  });
}
