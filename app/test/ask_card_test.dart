/// Widget tests for the inline ask card (SPEC-25).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/elicitation.dart';
import 'package:makit/ui/session/ask_card.dart';

void main() {
  late List<(String, Map<String, dynamic>)> responses;
  late StreamController<String> responded;

  setUp(() {
    responses = [];
    responded = StreamController<String>.broadcast();
  });
  tearDown(() => responded.close());

  /// Pump the ask card for [questions], wired to a captured controller. The
  /// harness watches `pendingAskProvider` (like the real transcript) so the
  /// card rebuilds when the store changes (e.g. free-text mode).
  Future<void> pump(
    WidgetTester tester,
    List<Map<String, dynamic>> questions,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          elicitationControllerProvider.overrideWith((ref) {
            final c = ElicitationController(
              respond: (id, body) => responses.add((id, body)),
              responded: responded.stream,
            );
            c.add(
              PendingAsk(
                requestId: 'r1',
                sessionId: 's1',
                questions: questions,
              ),
            );
            return c;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (ctx, ref, _) {
                final ask = ref.watch(pendingAskProvider('s1'));
                return ask == null ? const SizedBox() : AskCard(ask: ask);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<Map<String, dynamic>> single() => [
    {
      'question': 'Which CI?',
      'options': [
        {'label': 'GitHub Actions'},
        {'label': 'CircleCI'},
      ],
    },
  ];

  testWidgets(
    'single-select requires an explicit Submit (tap alone does not answer)',
    (tester) async {
      await pump(tester, single());

      // Tapping an option selects but does not submit.
      await tester.tap(find.text('GitHub Actions'));
      await tester.pumpAndSettle();
      expect(responses, isEmpty);

      // Submit sends the canonical response.
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pumpAndSettle();
      expect(responses, hasLength(1));
      final (_, body) = responses.single;
      expect(body['indices'], [0]);
      expect(body['answers'], ['GitHub Actions']);
    },
  );

  testWidgets('multi-select joins chosen labels with " + "', (tester) async {
    await pump(tester, [
      {
        'question': 'Platforms?',
        'multi': true,
        'options': [
          {'label': 'iOS'},
          {'label': 'macOS'},
          {'label': 'Android'},
        ],
      },
    ]);

    await tester.tap(find.text('iOS'));
    await tester.tap(find.text('macOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    final (_, body) = responses.single;
    expect(body['answers'], ['iOS + macOS']);
  });

  testWidgets('multi-question steps with Next then Submits', (tester) async {
    await pump(tester, [
      {
        'question': 'Q1',
        'options': [
          {'label': 'A'},
          {'label': 'B'},
        ],
      },
      {
        'question': 'Q2',
        'options': [
          {'label': 'C'},
          {'label': 'D'},
        ],
      },
    ]);

    // Step 1: pick, Next (not Submit yet).
    expect(find.widgetWithText(FilledButton, 'Next'), findsOneWidget);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    // Step 2: pick, Submit.
    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    final (_, body) = responses.single;
    expect(body['indices'], [0, 1]);
    expect(body['answers'], ['A', 'D']);
  });

  testWidgets('"Type a different answer" hands off to the composer', (
    tester,
  ) async {
    await pump(tester, single());
    await tester.tap(find.text('Type a different answer'));
    await tester.pumpAndSettle();

    // No response is sent yet; the card switches to the free-text note.
    expect(responses, isEmpty);
    expect(find.textContaining('message box below'), findsOneWidget);
    expect(find.text('GitHub Actions'), findsNothing);
  });

  testWidgets('Skip cancels the ask', (tester) async {
    await pump(tester, single());
    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();
    final (_, body) = responses.single;
    expect(body['kind'], 'askUserQuestion');
    expect(body['cancelled'], true);
  });
}
