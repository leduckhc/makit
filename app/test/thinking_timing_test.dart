import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/live_now.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: makitDarkTheme,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a finished thought leads with "Thought for 12s" (D7)', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: _wrap(
          const ThinkingLine(
            text: 'reasoning',
            expansionKey: 'k',
            startTs: 0,
            lastTs: 12000,
            streaming: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Thought for 12s'), findsOneWidget);
  });

  testWidgets('the duration is at least 1s (D7)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: _wrap(
          const ThinkingLine(
            text: 'x',
            expansionKey: 'k',
            startTs: 0,
            lastTs: 400,
            streaming: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Thought for 1s'), findsOneWidget);
  });

  testWidgets('the new label uses onSurfaceVariant at FULL opacity (D9b)', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: _wrap(
          const ThinkingLine(
            text: 'x',
            expansionKey: 'k',
            startTs: 0,
            lastTs: 12000,
            streaming: false,
          ),
        ),
      ),
    );
    await tester.pump();
    final label = tester.widget<Text>(find.text('Thought for 12s'));
    // Must NOT inherit the existing preview's alpha 0.65 (3.57:1, fails AA).
    expect(label.style!.color!.a, 1.0);
  });

  testWidgets('a streaming thought reads "Thinking … 41s" (D7)', (
    tester,
  ) async {
    final now = ValueNotifier<int>(41000);
    addTearDown(now.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [liveNowProvider(1).overrideWithValue(now)],
        child: _wrap(
          const ThinkingLine(
            text: 'x',
            expansionKey: 'k',
            startTs: 0,
            lastTs: 5000,
            streaming: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Thinking … 41s'), findsOneWidget);
  });

  // Folded, the label and the preview share one line — the row is a one-liner.
  // Unfolded, the reasoning is a paragraph, so the label gets its own line and
  // the text starts fresh underneath it instead of being indented around it.
  group('the unfolded layout gives the reasoning its own line', () {
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      ProviderScope(
        child: _wrap(
          const ThinkingLine(
            text:
                'The risk tint fires on edit/write/bash, so it is on for '
                'almost every row; monochrome loses nothing.',
            expansionKey: 'k',
            startTs: 0,
            lastTs: 4000,
          ),
        ),
      ),
    );

    testWidgets('folded: label and preview sit on one line', (tester) async {
      await pump(tester);
      final label = tester.getTopLeft(find.text('Thought for 4s'));
      final text = tester.getTopLeft(find.textContaining('The risk tint'));
      expect(text.dy, label.dy, reason: 'same line');
      expect(
        text.dx,
        greaterThan(label.dx),
        reason: 'preview trails the label',
      );
    });

    testWidgets('unfolded: the text starts below, flush with the label', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.textContaining('The risk tint'));
      await tester.pumpAndSettle();

      final label = tester.getTopLeft(find.text('Thought for 4s'));
      final text = tester.getTopLeft(find.textContaining('The risk tint'));
      expect(text.dy, greaterThan(label.dy), reason: 'on its own line');
      expect(
        text.dx,
        moreOrLessEquals(label.dx, epsilon: 0.5),
        reason: 'left edge aligns with the label, not indented past it',
      );
    });

    testWidgets('unfolded: the text keeps the full column width', (
      tester,
    ) async {
      await pump(tester);
      final foldedWidth = tester
          .getSize(find.textContaining('The risk tint'))
          .width;
      await tester.tap(find.textContaining('The risk tint'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.textContaining('The risk tint')).width,
        greaterThan(foldedWidth),
        reason: 'no longer sharing the line with the label',
      );
    });
  });
}
