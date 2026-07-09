/// Tests for the AskUserQuestion wire schema → UI roundtrip.
///
/// Why these exist: we shipped a regression where pi's tool args used the
/// Anthropic-standard `questions: [...]` form but our handler only knew
/// about the single-`question` form. The dialog never opened, the agent
/// timed out. These tests pin down both schemas so a future schema drift
/// breaks CI rather than the simulator.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/widgets/srv_request_handler.dart';

void main() {
  group('AskWizard wire schema', () {
    testWidgets(
      'single-question form renders one page and submits a String answer',
      (tester) async {
        await _pumpWizard(tester, [
          {
            'header': 'Style',
            'question': 'How do you prefer code reviews?',
            'options': [
              {'label': 'Terse', 'description': 'Just the facts'},
              {'label': 'Detailed'},
            ],
          },
        ]);

        // Question + options visible.
        expect(find.text('Style'), findsOneWidget);
        expect(find.text('How do you prefer code reviews?'), findsOneWidget);
        expect(find.text('Terse'), findsOneWidget);
        expect(find.text('Detailed'), findsOneWidget);

        // Submit is disabled until something is picked.
        final submit = find.widgetWithText(FilledButton, 'Submit');
        expect(_isButtonEnabled(tester, submit), isFalse);

        await tester.tap(find.text('Terse'));
        await tester.pump();
        expect(_isButtonEnabled(tester, submit), isTrue);

        await tester.tap(submit);
        await tester.pumpAndSettle();

        // The wizard resolves with the canonical UIResponse shape.
        expect(_lastResult, isA<Map<String, dynamic>>());
        expect((_lastResult as Map)['indices'], [0]);
        expect((_lastResult as Map)['answers'], ['Terse']);
      },
    );

    testWidgets(
      'multi-question (wizard) form paginates and returns array of answers',
      (tester) async {
        await _pumpWizard(tester, [
          {
            'header': 'Language',
            'question': 'Which language?',
            'recommended': 1,
            'options': [
              {'label': 'Python'},
              {'label': 'TypeScript'},
            ],
          },
          {
            'header': 'Tools',
            'question': 'Which tools?',
            'multi': true,
            'options': [
              {'label': 'Vim'},
              {'label': 'VS Code'},
              {'label': 'Xcode'},
            ],
          },
        ]);

        // Page indicator on first question.
        expect(find.text('1/2'), findsOneWidget);

        // Pick TypeScript → Next is enabled.
        await tester.tap(find.text('TypeScript'));
        await tester.pump();
        final nextBtn = find.widgetWithText(FilledButton, 'Next');
        expect(_isButtonEnabled(tester, nextBtn), isTrue);
        await tester.tap(nextBtn);
        await tester.pumpAndSettle();

        // Second page now visible.
        expect(find.text('2/2'), findsOneWidget);
        expect(find.text('Which tools?'), findsOneWidget);

        // Multi-select: pick Vim and Xcode.
        await tester.tap(find.text('Vim'));
        await tester.pump();
        await tester.tap(find.text('Xcode'));
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
        await tester.pumpAndSettle();

        // Q1 single-select → String; Q2 multi-select → List<String>.
        // Canonical shape: indices/answers parallel arrays, multi-select
        // labels joined with " + ".
        expect(_lastResult, isA<Map<String, dynamic>>());
        expect((_lastResult as Map)['indices'], [1, 0]);
        expect((_lastResult as Map)['answers'], ['TypeScript', 'Vim + Xcode']);
      },
    );

    testWidgets('Cancel returns null', (tester) async {
      await _pumpWizard(tester, [
        {
          'question': 'Quit?',
          'options': [
            {'label': 'Yes'},
            {'label': 'No'},
          ],
        },
      ]);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(_lastResult, isNull);
    });

    testWidgets('Recommended option shows a "Recommended" badge', (
      tester,
    ) async {
      await _pumpWizard(tester, [
        {
          'question': 'Pick',
          'recommended': 0,
          'options': [
            {'label': 'A'},
            {'label': 'B'},
          ],
        },
      ]);

      expect(find.text('Recommended'), findsOneWidget);
    });

    testWidgets('Back button returns to a previous page', (tester) async {
      await _pumpWizard(tester, [
        {
          'question': 'First',
          'options': [
            {'label': 'a1'},
          ],
        },
        {
          'question': 'Second',
          'options': [
            {'label': 'b1'},
          ],
        },
      ]);

      await tester.tap(find.text('a1'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Next'));
      await tester.pumpAndSettle();

      expect(find.text('Second'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Back'));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
    });
  });

  group('SrvRequestHandler dispatch', () {
    test('Envelope decodes srv.request with questions array', () {
      const raw =
          '{"v":1,"t":"srv.request","id":"srv-1","kind":"askUserQuestion","questions":[{"question":"Q","options":[{"label":"A"}]}]}';
      final env = Envelope.decode(raw);
      expect(env, isNotNull);
      expect(env!.t, MsgType.srvRequest);
      expect(env.body['kind'], 'askUserQuestion');
      expect(env.body['questions'], isA<List<dynamic>>());
      final qs = env.body['questions'] as List;
      expect(qs.first, isA<Map<dynamic, dynamic>>());
    });

    test(
      'Envelope decodes the legacy single-question schema for back-compat',
      () {
        const raw =
            '{"v":1,"t":"srv.request","id":"srv-2","kind":"askUserQuestion","question":"Yes?","options":[{"label":"Yes"},{"label":"No"}]}';
        final env = Envelope.decode(raw);
        expect(env, isNotNull);
        expect(env!.body['question'], 'Yes?');
        expect(env.body['options'], isA<List<dynamic>>());
      },
    );

    test('MsgType.srvRequest / srvResponse round-trip via wire', () {
      expect(MsgType.fromWire('srv.request'), MsgType.srvRequest);
      expect(MsgType.fromWire('srv.response'), MsgType.srvResponse);
      expect(MsgType.srvRequest.wire, 'srv.request');
      expect(MsgType.srvResponse.wire, 'srv.response');
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

dynamic _lastResult;

/// Pump the wizard widget directly (bypassing the full app + WS plumbing)
/// and capture the popped result into [_lastResult].
///
/// `_AskWizard` is a private class; we drive it the same way real code does
/// — through `showDialog<Map<String, dynamic>?>(...)` against [SrvRequestHandler]'s
/// internal helper. To keep this test isolated we use a published builder
/// function that mirrors the production dispatch logic. See
/// [debugAskWizardFor] in srv_request_handler.dart (added below if missing).
Future<void> _pumpWizard(
  WidgetTester tester,
  List<Map<String, dynamic>> questions,
) async {
  _lastResult = 'sentinel-not-set';
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                _lastResult = await showDialog<Map<String, dynamic>?>(
                  context: ctx,
                  barrierDismissible: false,
                  builder: (dctx) => debugAskWizardFor(questions),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool _isButtonEnabled(WidgetTester tester, Finder finder) {
  final w = tester.widget<ButtonStyleButton>(finder);
  return w.onPressed != null;
}
