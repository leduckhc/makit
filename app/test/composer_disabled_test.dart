/// Composer pause/disabled state (SPEC-25): while a session awaits an inline
/// answer, the composer is inert and shows a hint instead of the field + send.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/composer/composer.dart';

void main() {
  testWidgets('disabled composer shows the hint and no input field', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            enabled: false,
            disabledHint: 'Answer the question above to continue…',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Answer the question above to continue…'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('enabled composer shows the input field', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Composer(onSend: (_) {})),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });
}
