import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/ui/session/turn_receipt.dart';

Future<void> _pump(
  WidgetTester tester,
  TurnReceiptItem item, {
  double width = 720,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: TurnReceipt(item: item),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

TurnReceiptItem _receipt({
  int wallMs = 133000,
  int gatedMs = 0,
  int toolCount = 14,
}) => TurnReceiptItem(
  seq: 9,
  ts: 0,
  wallMs: wallMs,
  gatedMs: gatedMs,
  toolCount: toolCount,
);

void main() {
  testWidgets('D9: headline is the wall clock plus the tool count', (t) async {
    await _pump(t, _receipt());
    expect(find.textContaining('2m 13s'), findsOneWidget);
    expect(find.textContaining('14 tools'), findsOneWidget);
  });

  testWidgets('D20: the tool count is singular at one', (t) async {
    await _pump(t, _receipt(toolCount: 1));
    expect(find.textContaining('1 tool'), findsOneWidget);
    expect(find.textContaining('1 tools'), findsNothing);
  });

  testWidgets('D9: the gate token is absent on an ungated turn', (t) async {
    await _pump(t, _receipt());
    expect(find.textContaining('waiting on you'), findsNothing);
  });

  testWidgets('D9: a gated turn names the wait, in the caution tone', (
    t,
  ) async {
    await _pump(t, _receipt(wallMs: 400000, gatedMs: 252000));
    final gate = find.textContaining('waiting on you');
    expect(gate, findsOneWidget);
    expect(t.widget<Text>(gate).style?.color, kStatusCaution);
    // The headline stays the wall clock, not the agent-only remainder (D9).
    expect(find.textContaining('6m 40s'), findsOneWidget);
  });

  testWidgets('D9b: quiet by size and tone, never a dimmer custom grey', (
    t,
  ) async {
    await _pump(t, _receipt());
    final text = t.widget<Text>(find.textContaining('2m 13s'));
    final cs = makitDarkTheme.colorScheme;
    expect(text.style?.color, cs.onSurfaceVariant);
    expect(text.style?.fontSize, makitDarkTheme.textTheme.labelSmall?.fontSize);
  });

  testWidgets('D9c: a narrow surface stacks the gate onto its own line', (
    t,
  ) async {
    await _pump(t, _receipt(wallMs: 400000, gatedMs: 252000), width: 340);
    // Two Text runs stacked in a Column rather than one Row that wraps.
    expect(find.byType(Column), findsWidgets);
    expect(find.textContaining('waiting on you'), findsOneWidget);
    expect(find.textContaining('6m 40s'), findsOneWidget);
  });

  testWidgets('D17: the receipt reads as one sentence to a screen reader', (
    t,
  ) async {
    await _pump(t, _receipt(wallMs: 400000, gatedMs: 252000));
    expect(
      find.bySemanticsLabel(RegExp('turn took 6m 40s.*14 tools.*waiting')),
      findsOneWidget,
    );
  });
}
