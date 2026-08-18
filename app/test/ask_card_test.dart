/// Widget tests for the inline ask card (SPEC-ask-user-inline-in-chat).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/store/elicitation.dart';
import 'package:makit/store/models.dart';
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

  testWidgets('free-text mode keeps a Skip escape hatch', (tester) async {
    await pump(tester, single());
    await tester.tap(find.text('Type a different answer'));
    await tester.pumpAndSettle();

    // Skip is still available so the user can bail without typing.
    expect(find.widgetWithText(TextButton, 'Skip'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();
    final (_, body) = responses.single;
    expect(body['cancelled'], true);
  });

  testWidgets('Skip cancels the ask', (tester) async {
    await pump(tester, single());
    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();
    final (_, body) = responses.single;
    expect(body['kind'], 'askUserQuestion');
    expect(body['cancelled'], true);
  });

  testWidgets('multi-select-over-input renders inline and answers via input', (
    tester,
  ) async {
    final ask = PendingAsk.fromMultiSelectInput(
      requestId: 'r1',
      sessionId: 's1',
      title:
          'Which platforms?\n\nOptions (select one or more):\n'
          '1. iOS \u2014 phones\n2. macOS\n3. Android',
    )!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          elicitationControllerProvider.overrideWith((ref) {
            final c = ElicitationController(
              respond: (id, b) => responses.add((id, b)),
              responded: responded.stream,
            );
            c.add(ask);
            return c;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (ctx, ref, _) {
                final a = ref.watch(pendingAskProvider('s1'));
                return a == null ? const SizedBox() : AskCard(ask: a);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Inline checkbox card — not a modal, no free-text handoff for multi-select.
    expect(find.text('Which platforms?'), findsOneWidget);
    expect(find.text('iOS'), findsOneWidget);
    expect(find.text('phones'), findsOneWidget); // option description
    expect(find.text('Type a different answer'), findsNothing);

    await tester.tap(find.text('iOS'));
    await tester.tap(find.text('macOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    // Answered on the input channel as comma-separated titles.
    final (_, body) = responses.single;
    expect(body['kind'], 'input');
    expect(body['value'], 'iOS, macOS');
  });

  group(
    'AnsweredAskCard (resolved history, SPEC-ask-user-inline-in-chat #1)',
    () {
      testWidgets('highlights the chosen option and dims the rest', (
        tester,
      ) async {
        final item = ToolCallItem(
          seq: 1,
          ts: 0,
          callId: 'c1',
          name: 'askUserQuestion',
          args: const {
            'question': 'Which CI?',
            'options': [
              {'label': 'GitHub Actions'},
              {'label': 'CircleCI'},
            ],
          },
          details: const {
            'answers': ['GitHub Actions'],
          },
          ended: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AnsweredAskCard(item: item)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Answered'), findsOneWidget);
        expect(find.text('Which CI?'), findsOneWidget);
        expect(find.text('GitHub Actions'), findsOneWidget);
        expect(find.text('CircleCI'), findsOneWidget);
        // The non-chosen option is dimmed via an Opacity wrapper.
        expect(find.byType(Opacity), findsWidgets);
      });

      testWidgets(
        'derives the choice from output when details are absent (pi ask_user)',
        (tester) async {
          final item = ToolCallItem(
            seq: 1,
            ts: 0,
            callId: 'c1',
            name: 'ask_user',
            args: const {
              'questions': [
                {
                  'question': 'Which CI?',
                  'options': [
                    {'label': 'GitHub Actions'},
                    {'label': 'CircleCI'},
                  ],
                },
              ],
            },
            // No details — pi's ask_user returns the chosen label as the output.
            output: 'GitHub Actions',
            ended: true,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: AnsweredAskCard(item: item)),
            ),
          );
          await tester.pumpAndSettle();
          // Exactly one option is marked chosen (filled check).
          expect(find.byIcon(PhosphorIconsFill.checkCircle), findsOneWidget);
          expect(find.text('GitHub Actions'), findsOneWidget);
        },
      );

      testWidgets('shows context and comment when present', (tester) async {
        final item = ToolCallItem(
          seq: 1,
          ts: 0,
          callId: 'c1',
          name: 'ask_user',
          args: const {},
          ended: true,
          details: {
            'question': 'Which PR?',
            'options': [
              {'title': 'PR #42'},
            ],
            'context': 'To keep the dashboard accurate',
            'response': {
              'kind': 'selection',
              'selections': ['PR #42'],
              'comment': 'This was my choice',
            },
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AnsweredAskCard(item: item)),
          ),
        );
        await tester.pump();
        expect(find.text('To keep the dashboard accurate'), findsOneWidget);
        expect(find.text('This was my choice'), findsOneWidget);
      });

      testWidgets('shows a free-text answer that matches no option', (
        tester,
      ) async {
        final item = ToolCallItem(
          seq: 1,
          ts: 0,
          callId: 'c1',
          name: 'ask_user',
          args: const {
            'questions': [
              {
                'question': 'Branch name?',
                'options': [
                  {'label': 'feat/ci'},
                  {'label': 'chore/actions'},
                ],
              },
            ],
          },
          output: 'my/custom-branch',
          ended: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AnsweredAskCard(item: item)),
          ),
        );
        await tester.pumpAndSettle();
        // The typed answer appears (as the chosen row), not lost.
        expect(find.text('my/custom-branch'), findsOneWidget);
        expect(find.byIcon(PhosphorIconsFill.checkCircle), findsOneWidget);
      });

      testWidgets(
        'reads pi\'s details shape (question + options[title] + response)',
        (tester) async {
          final item = ToolCallItem(
            seq: 1,
            ts: 0,
            callId: 'c1',
            name: 'ask_user',
            args: const {'question': "What's your favorite color?"},
            details: const {
              'question': "What's your favorite color?",
              'options': [
                {'title': 'Red'},
                {'title': 'Green'},
                {'title': 'Blue'},
              ],
              'response': {'kind': 'freeform', 'text': 'teal'},
            },
            output: 'User answered: teal',
            ended: true,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: AnsweredAskCard(item: item)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text("What's your favorite color?"), findsOneWidget);
          // Option titles render.
          expect(find.text('Red'), findsOneWidget);
          expect(find.text('Green'), findsOneWidget);
          // The freeform answer shows as the chosen row.
          expect(find.text('teal'), findsOneWidget);
          expect(find.byIcon(PhosphorIconsFill.checkCircle), findsOneWidget);
        },
      );

      testWidgets('renders context, option descriptions, and a comment', (
        tester,
      ) async {
        final item = ToolCallItem(
          seq: 1,
          ts: 0,
          callId: 'c1',
          name: 'ask_user',
          args: const {'question': 'PR pill?'},
          details: const {
            'question': 'PR pill?',
            'context':
                'findOpenPr only queries open PRs, so the pill vanishes.',
            'options': [
              {
                'title': 'Keep pill',
                'description': 'Query --state all instead.',
              },
              {'title': 'Drop it'},
            ],
            'response': {
              'kind': 'selection',
              'selections': ['Keep pill'],
              'comment': 'persist across merges',
            },
          },
          output: 'User answered: Keep pill',
          ended: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AnsweredAskCard(item: item)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('the pill vanishes'), findsOneWidget);
        expect(find.textContaining('Query --state all'), findsOneWidget);
        expect(find.text('persist across merges'), findsOneWidget);
        expect(find.byIcon(PhosphorIconsFill.checkCircle), findsOneWidget);
      });

      testWidgets('a cancelled ask shows Skipped and highlights nothing', (
        tester,
      ) async {
        final item = ToolCallItem(
          seq: 1,
          ts: 0,
          callId: 'c1',
          name: 'ask_user',
          args: const {'question': 'Which CI?'},
          details: const {
            'question': 'Which CI?',
            'options': [
              {'title': 'GitHub Actions'},
              {'title': 'CircleCI'},
            ],
            'response': null,
            'cancelled': true,
          },
          output: 'User cancelled the question',
          ended: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AnsweredAskCard(item: item)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Skipped'), findsOneWidget);
        expect(find.text('Answered'), findsNothing);
        expect(find.byIcon(PhosphorIconsFill.checkCircle), findsNothing);
      });
    },
  );
}
