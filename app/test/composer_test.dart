import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/ui/composer/composer.dart';

void _noop(String _) {}

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  // Whether the send button is currently tappable. The send arrow is always
  // present when idle; it's disabled (onPressed == null) while the field is
  // empty and enabled once there's text.
  bool sendEnabled(WidgetTester tester) {
    final btn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(PhosphorIconsLight.arrowUp),
        matching: find.byType(IconButton),
      ),
    );
    return btn.onPressed != null;
  }

  testWidgets(
    'send button is visible but disabled when empty and enables once text is entered',
    (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(wrap(Composer(onSend: sent.add)));

      // No text yet → send button visible but disabled.
      expect(find.byIcon(PhosphorIconsLight.arrowUp), findsOneWidget);
      expect(sendEnabled(tester), isFalse);

      // Focus the field (realistic: you tap to type), then enter text.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      // Focusing alone must not enable the send button.
      expect(sendEnabled(tester), isFalse);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();
      expect(sendEnabled(tester), isTrue);

      await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
      await tester.pumpAndSettle();
      expect(sent, ['hello']);
      // After sending, the field clears and send disables again (still visible).
      expect(find.byIcon(PhosphorIconsLight.arrowUp), findsOneWidget);
      expect(sendEnabled(tester), isFalse);
    },
  );

  testWidgets(
    'seeds the field from initialText and shows the send affordance',
    (tester) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, initialText: 'half typed')),
      );

      // The restored draft is visible immediately, even before focus.
      expect(find.text('half typed'), findsOneWidget);
      // Non-empty seed → send affordance shows without any typing.
      expect(find.byIcon(PhosphorIconsLight.arrowUp), findsOneWidget);
    },
  );

  testWidgets(
    'reports draft text via onDraftChanged while editing and clears on send',
    (tester) async {
      final drafts = <String>[];
      final sent = <String>[];
      await tester.pumpWidget(
        wrap(Composer(onSend: sent.add, onDraftChanged: drafts.add)),
      );

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pumpAndSettle();
      expect(drafts.last, 'hi');

      await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
      await tester.pumpAndSettle();
      expect(sent, ['hi']);
      // Sending clears the field, so the last reported draft is empty — the
      // caller uses this to prune the persisted draft.
      expect(drafts.last, '');
    },
  );

  testWidgets('field starts compact (1 line) and grows to 10 lines on focus', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(Composer(onSend: (_) {})));

    final fieldBefore = tester.widget<TextField>(find.byType(TextField));
    expect(fieldBefore.minLines, 1);
    expect(fieldBefore.maxLines, 1);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final fieldAfter = tester.widget<TextField>(find.byType(TextField));
    // Expanded starts 3 rows tall and auto-grows up to 10 before scrolling.
    expect(fieldAfter.minLines, 3);
    expect(fieldAfter.maxLines, 10);
  });

  testWidgets(
    'alwaysExpanded keeps the full form (10-line field + footer) when unfocused',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const Composer(
            onSend: _noop,
            alwaysExpanded: true,
            footerActions: [Text('MODEL'), Text('THINK')],
          ),
        ),
      );

      // Full form up immediately, with no focus and no text.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 10);
      // Footer actions render in the action row.
      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('THINK'), findsOneWidget);
      // The add affordance is present (disabled placeholder).
      expect(find.byIcon(PhosphorIconsLight.paperclip), findsOneWidget);
    },
  );

  testWidgets(
    'footerActions stay hidden while compact (unfocused, not alwaysExpanded)',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const Composer(
            onSend: _noop,
            footerActions: [Text('MODEL'), Text('THINK')],
          ),
        ),
      );

      // Mobile default: compact one-liner, so the footer (and its selectors)
      // is not rendered until the field is focused/expanded.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 1);
      expect(find.text('MODEL'), findsNothing);
      expect(find.text('THINK'), findsNothing);
    },
  );

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
    expect(find.byIcon(PhosphorIconsLight.arrowUp), findsOneWidget);
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

    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
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
      expect(find.byIcon(PhosphorIconsLight.stop), findsOneWidget);
      expect(find.byIcon(PhosphorIconsLight.arrowUp), findsNothing);

      // Typing flips the trailing slot to the green send arrow.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pumpAndSettle();
      expect(find.byIcon(PhosphorIconsLight.arrowUp), findsOneWidget);
      expect(find.byIcon(PhosphorIconsLight.stop), findsNothing);

      // Clearing the text (turn still running) flips back to cancel.
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.byIcon(PhosphorIconsLight.stop), findsOneWidget);

      await tester.tap(find.byIcon(PhosphorIconsLight.stop));
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
    expect(find.byIcon(PhosphorIconsLight.stop), findsNothing);
    // Idle + empty shows the disabled send button, not the cancel affordance.
    expect(find.byIcon(PhosphorIconsLight.arrowUp), findsOneWidget);
    expect(sendEnabled(tester), isFalse);
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
