import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/ui/composer/composer.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets(
    'send button is hidden when empty and fades in once text is entered',
    (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(wrap(Composer(onSend: sent.add)));

      // No text yet → no send affordance.
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      // Focus the field (realistic: you tap to type), then enter text.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      // Focusing alone must not surface the send button.
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();
      expect(sent, ['hello']);
      // After sending, the field clears and send hides again.
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
    },
  );

  testWidgets(
    'field starts compact (1 line) and expands to 3 lines on focus',
    (tester) async {
      await tester.pumpWidget(wrap(Composer(onSend: (_) {})));

      final fieldBefore = tester.widget<TextField>(find.byType(TextField));
      expect(fieldBefore.minLines, 1);
      expect(fieldBefore.maxLines, 1);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      final fieldAfter = tester.widget<TextField>(find.byType(TextField));
      expect(fieldAfter.minLines, 3);
      expect(fieldAfter.maxLines, 3);
    },
  );

  testWidgets(
    'losing focus collapses back to 1 line while preserving text',
    (tester) async {
      await tester.pumpWidget(wrap(Composer(onSend: (_) {})));

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.pumpAndSettle();

      // Blur the field by focusing nothing.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.minLines, 1);
      expect(field.maxLines, 1);
      expect(find.text('draft'), findsOneWidget);
      // Draft is non-empty → send stays visible even in compact form.
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    },
  );
}
