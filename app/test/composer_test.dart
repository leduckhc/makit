import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/ui/composer/composer.dart';

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

  testWidgets('field starts compact (1 line) and expands to 3 lines on focus', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(Composer(onSend: (_) {})));

    final fieldBefore = tester.widget<TextField>(find.byType(TextField));
    expect(fieldBefore.minLines, 1);
    expect(fieldBefore.maxLines, 1);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final fieldAfter = tester.widget<TextField>(find.byType(TextField));
    expect(fieldAfter.minLines, 3);
    expect(fieldAfter.maxLines, 3);
  });

  testWidgets('losing focus collapses back to 1 line while preserving text', (
    tester,
  ) async {
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
  });

  testWidgets('IME return key is the standard newline key', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(wrap(Composer(onSend: sent.add)));

    var field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
  });

  testWidgets('submitting sends the text and dismisses the keyboard', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(wrap(Composer(onSend: sent.add)));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(sent, ['hello']);
    // Focus is released → composer collapses back to compact (1 line), which
    // only happens when the field is no longer focused.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
  });

  testWidgets(
    'cancel button shows only while running with empty input, and fires onCancel',
    (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(
        wrap(
          Composer(onSend: (_) {}, running: true, onCancel: () => cancelled++),
        ),
      );

      // Running + empty → stop button (no send arrow).
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      // Typing flips the trailing slot to the green send arrow.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);

      // Clearing the text (turn still running) flips back to cancel.
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.stop), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pumpAndSettle();
      expect(cancelled, 1);
    },
  );

  testWidgets('no cancel button when idle even with empty input', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(Composer(onSend: (_) {}, running: false, onCancel: () {})),
    );
    expect(find.byIcon(Icons.stop), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });

  group('configurable send/newline chords', () {
    Future<void> focusWithText(WidgetTester tester, String text) async {
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), text);
      await tester.pumpAndSettle();
    }

    testWidgets('Shift+Enter inserts a newline instead of sending', (
      tester,
    ) async {
      final sent = <String>[];
      await tester.pumpWidget(
        wrap(
          Composer(
            onSend: sent.add,
            sendChord: const KeyChord(LogicalKeyboardKey.enter),
            newlineChord: const KeyChord(LogicalKeyboardKey.enter, shift: true),
          ),
        ),
      );
      await focusWithText(tester, 'hi');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(sent, isEmpty);
      final field = tester.widget<TextField>(find.byType(TextField));
      // Newline inserted at the caret (end of 'hi'), caret left after it.
      expect(field.controller!.text, 'hi\n');
      expect(field.controller!.selection.baseOffset, 3);
    });

    testWidgets('configured plain Enter sends', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
        wrap(
          Composer(
            onSend: sent.add,
            sendChord: const KeyChord(LogicalKeyboardKey.enter),
            newlineChord: const KeyChord(LogicalKeyboardKey.enter, shift: true),
          ),
        ),
      );
      await focusWithText(tester, 'ship it');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sent, ['ship it']);
    });
  });
}
