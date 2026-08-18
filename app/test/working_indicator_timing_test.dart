import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/live_now.dart';

void main() {
  testWidgets('the working indicator shows a live turn counter (D8)', (
    tester,
  ) async {
    final now = ValueNotifier<int>(48000);
    addTearDown(now.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The turn opened at ts 1000. The store keeps this, folded (SPEC-session-timings
          // D8); the indicator only reads it.
          openTurnStartProvider('s1').overrideWithValue(1000),
          liveNowProvider(kLiveTickCadence.inSeconds).overrideWithValue(now),
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
        overrides: [openTurnStartProvider('s1').overrideWithValue(null)],
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
