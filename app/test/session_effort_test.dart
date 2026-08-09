import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/turns.dart';
import 'package:makit/ui/composer/context_usage.dart';

Future<void> _pump(
  WidgetTester tester, {
  required TurnRollup rollup,
  int? createdAt,
  int nowMs = 0,
  bool historyLoaded = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: SessionEffortSection(
          rollup: rollup,
          createdAt: createdAt,
          nowMs: nowMs,
          historyLoaded: historyLoaded,
        ),
      ),
    ),
  );
  await tester.pump();
}

const _day = 86400000;

TurnRollup _rollup({
  int turns = 18,
  int agentMs = 2468000,
  int? median = 82000,
}) => TurnRollup(turnCount: turns, agentMs: agentMs, medianWallMs: median);

void main() {
  testWidgets('D11: renders age, agent time, turns and median turn', (t) async {
    await _pump(
      t,
      rollup: _rollup(),
      createdAt: 0,
      nowMs: 3 * _day + 4 * 3600000,
    );
    expect(find.text('Age'), findsOneWidget);
    expect(find.text('3d 4h'), findsOneWidget);
    expect(find.text('Agent time'), findsOneWidget);
    expect(find.text('41m 08s'), findsOneWidget);
    expect(find.text('Turns'), findsOneWidget);
    expect(find.text('18'), findsOneWidget);
    expect(find.text('Median turn'), findsOneWidget);
    expect(find.text('1m 22s'), findsOneWidget);
  });

  testWidgets('D12: no createdAt → no Age row, never a fabricated age', (
    t,
  ) async {
    await _pump(t, rollup: _rollup(), createdAt: null, nowMs: 5 * _day);
    expect(find.text('Age'), findsNothing);
    // The other three still render — one absent fact does not hide the rest.
    expect(find.text('Turns'), findsOneWidget);
  });

  testWidgets(
    'D16: a tail-only session renders nothing rather than undercount',
    (t) async {
      await _pump(
        t,
        rollup: _rollup(turns: 3),
        createdAt: 0,
        nowMs: _day,
        historyLoaded: false,
      );
      expect(find.text('Turns'), findsNothing);
      expect(find.text('Age'), findsNothing);
    },
  );

  testWidgets('D20: one turn is singular', (t) async {
    await _pump(
      t,
      rollup: _rollup(turns: 1, median: 1000),
      createdAt: 0,
      nowMs: _day,
    );
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Turn'), findsOneWidget);
  });

  testWidgets('a session with no completed turns shows no median', (t) async {
    await _pump(
      t,
      rollup: _rollup(turns: 0, agentMs: 0, median: null),
      createdAt: 0,
      nowMs: _day,
    );
    expect(find.text('Turns'), findsOneWidget);
    expect(find.text('Median turn'), findsNothing);
    expect(find.text('Age'), findsOneWidget);
  });
}
