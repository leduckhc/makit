import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/app/theme.dart' show kRadius16;
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/context_usage.dart' show kUsageTargetSize;

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

  // ─── SPEC-40: the footer distributes space by need ─────────────────────────

  group('SPEC-40 — footerTrailing does not reserve flex', () {
    /// A stand-in footer action that records the `maxWidth` the footer granted
    /// it. The granted CONSTRAINT is the thing under test — not a rendered
    /// width, which for a shrink-wrapping pill would report its natural size
    /// however starved it was, and which drifts with font metrics.
    Widget probe(void Function(double) onWidth) => LayoutBuilder(
      builder: (context, constraints) {
        onWidth(constraints.maxWidth);
        return const SizedBox(height: 32);
      },
    );

    /// A stand-in for the usage ring at its real size, taken from the constant
    /// rather than copied: if the ring's footprint changes, this test's
    /// arithmetic must move with it instead of failing cryptically.
    const ring = SizedBox(width: kUsageTargetSize, height: kUsageTargetSize);

    /// The gap `Composer` puts after each footer action
    /// (`EdgeInsets.only(right: 6)` in `_buildExpanded`).
    const actionGap = 6.0;

    /// Pumps a composer of [width] and returns the maxWidth the single flexible
    /// action was granted. [trailing] chooses where the ring goes: the new
    /// trailing slot, or a second `footerActions` entry (today's wiring).
    Future<double> grantedWidth(
      WidgetTester tester, {
      required double width,
      required bool trailing,
    }) async {
      var granted = -1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: Composer(
                  onSend: _noop,
                  alwaysExpanded: true,
                  footerActions: [
                    probe((w) => granted = w),
                    if (!trailing) ring,
                  ],
                  footerTrailing: trailing ? ring : null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(granted, greaterThan(0), reason: 'the probe never laid out');
      return granted;
    }

    testWidgets('a trailing control takes only its own width, not a share', (
      tester,
    ) async {
      const width = 375.0;
      final asAction = await grantedWidth(
        tester,
        width: width,
        trailing: false,
      );
      final asTrailing = await grantedWidth(
        tester,
        width: width,
        trailing: true,
      );

      // Today's wiring: two equal-share `Flexible` children, so the probe is
      // capped at ~half the row even though the ring uses 36 of its share.
      // `FlexFit.loose` does not redistribute what the ring leaves behind.
      expect(
        asAction,
        lessThan(asTrailing / 1.5),
        reason: 'a second footerActions entry should roughly halve the share',
      );

      // Exact arithmetic, both derived from the same row width:
      //   as an action → probe gets (row / 2) - actionGap   [half, minus its pad]
      //   as trailing  → probe gets row - ring - actionGap  [all but the ring]
      // so the row width implied by the first measurement pins the second.
      final row = (asAction + actionGap) * 2;
      expect(
        asTrailing,
        closeTo(row - kUsageTargetSize - actionGap, 1.5),
        reason:
            'the trailing control must cost the actions only its own '
            '${kUsageTargetSize}pt',
      );
    });

    testWidgets('the trailing control renders after the actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 375,
                child: Composer(
                  onSend: _noop,
                  alwaysExpanded: true,
                  footerActions: [
                    SizedBox(key: Key('action'), width: 40, height: 32),
                  ],
                  footerTrailing: SizedBox(
                    key: Key('trailing'),
                    width: kUsageTargetSize,
                    height: kUsageTargetSize,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final action = tester.getTopLeft(find.byKey(const Key('action')));
      final trailing = tester.getTopLeft(find.byKey(const Key('trailing')));
      final plus = tester.getTopLeft(find.byIcon(PhosphorIconsLight.paperclip));
      expect(action.dx, lessThan(trailing.dx));
      expect(trailing.dx, lessThan(plus.dx));
      // Natural width, not a flex share.
      expect(
        tester.getSize(find.byKey(const Key('trailing'))).width,
        kUsageTargetSize,
      );
    });
  });

  group('header', () {
    Widget withHeader({bool enabled = true}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 375,
            child: Composer(
              onSend: _noop,
              alwaysExpanded: true,
              enabled: enabled,
              header: const SizedBox(key: Key('header'), height: 28),
            ),
          ),
        ),
      ),
    );

    testWidgets('sits inside the composer box, above the field', (
      tester,
    ) async {
      await tester.pumpWidget(withHeader());
      await tester.pumpAndSettle();

      // Inside the rounded box, not a sibling above it — that placement is the
      // whole point (SPEC-38 mockup §5, "inside the composer").
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).borderRadius ==
                    BorderRadius.circular(kRadius16),
          ),
          matching: find.byKey(const Key('header')),
        ),
        findsOneWidget,
      );
      final header = tester.getRect(find.byKey(const Key('header')));
      final field = tester.getRect(find.byType(TextField));
      expect(header.bottom, lessThanOrEqualTo(field.top));
    });

    testWidgets('is separated from the field by a hairline', (tester) async {
      await tester.pumpWidget(withHeader());
      await tester.pumpAndSettle();

      final rule = tester.getRect(find.byKey(kComposerHeaderRuleKey));
      expect(rule.height, 1);
      final header = tester.getRect(find.byKey(const Key('header')));
      final field = tester.getRect(find.byType(TextField));
      expect(rule.top, greaterThanOrEqualTo(header.bottom));
      expect(rule.bottom, lessThanOrEqualTo(field.top));
    });

    testWidgets('stays rendered while the composer is disabled', (
      tester,
    ) async {
      // The PR bar is the only caller, and its actions (push, fix, wrap up) stay
      // legitimate while an inline ask has the field locked — the same reason
      // PendingQueueSlot is not a Composer child.
      await tester.pumpWidget(withHeader(enabled: false));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('header')), findsOneWidget);
      expect(find.byKey(kComposerHeaderRuleKey), findsOneWidget);
    });

    testWidgets('no header means no hairline and no reserved space', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 375,
                child: Composer(onSend: _noop, alwaysExpanded: true),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(kComposerHeaderRuleKey), findsNothing);
    });
  });
}
