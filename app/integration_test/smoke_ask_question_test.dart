import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('answers an AskUserQuestion round-trip from the stub adapter', (
    tester,
  ) async {
    await launchPino(tester);
    await openFirstSession(tester);

    await sendComposerText(tester, 'ASK_QUESTION');

    await pumpUntil(tester, find.text('Pick a greeting'));
    await tester.tap(find.text('Hello'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pump();

    await pumpUntil(tester, find.text('echo: Hello'));
  });
}
