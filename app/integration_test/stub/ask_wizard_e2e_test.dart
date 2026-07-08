import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('drives multi-question multi-select wizard end to end', (
    tester,
  ) async {
    await launchPino(tester);
    await openFirstSession(tester);

    // Stub adapter recognises "ASK_MULTI" and triggers a 2-question wizard
    // (single-select then multi-select).
    await sendComposerText(tester, 'ASK_MULTI');

    await pumpUntil(tester, find.text('1/2'));
    expect(find.text('Which language?'), findsOneWidget);
    await tester.tap(find.text('Dart'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('Which tools?'), findsOneWidget);
    await tester.tap(find.text('Simulator'));
    await tester.pump();
    await tester.tap(find.text('Logs'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pump();

    // Stub adapter echoes the response JSON back as an agent.message.
    // Wizard joins multi-select labels with " + ".
    await pumpUntil(
      tester,
      find.textContaining('"answers":["Dart","Simulator + Logs"]'),
    );
  });
}
