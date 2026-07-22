/// Tests for the inline-ask elicitation store (SPEC-25).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/elicitation.dart';

PendingAsk _ask({
  String requestId = 'r1',
  String sessionId = 's1',
  List<Map<String, dynamic>>? questions,
}) => PendingAsk(
  requestId: requestId,
  sessionId: sessionId,
  questions:
      questions ??
      [
        {
          'question': 'Which CI?',
          'options': [
            {'label': 'GitHub Actions'},
            {'label': 'CircleCI'},
          ],
        },
      ],
);

void main() {
  late List<(String, Map<String, dynamic>)> responses;
  late StreamController<String> responded;
  late ElicitationController c;

  setUp(() {
    responses = [];
    responded = StreamController<String>.broadcast();
    c = ElicitationController(
      respond: (id, body) => responses.add((id, body)),
      responded: responded.stream,
    );
  });

  tearDown(() {
    c.dispose();
    responded.close();
  });

  test('add exposes the pending ask keyed by session', () {
    c.add(_ask());
    expect(c.state['s1']?.requestId, 'r1');
  });

  test('a replacement ask drops the displaced request mapping', () {
    c.add(_ask(requestId: 'r1'));
    c.add(_ask(requestId: 'r2')); // same session s1
    expect(c.state['s1']?.requestId, 'r2');
    // A late `responded` for the displaced r1 must not clear r2's card.
    responded.add('r1');
    return Future<void>.delayed(Duration.zero, () {
      expect(c.state['s1']?.requestId, 'r2');
    });
  });

  test('submit sends canonical {indices, answers} and clears the card', () {
    c.add(_ask());
    c.submit('r1', indices: [0], answers: ['GitHub Actions']);

    expect(c.state.containsKey('s1'), isFalse);
    expect(responses, hasLength(1));
    final (id, body) = responses.single;
    expect(id, 'r1');
    expect(body['kind'], 'askUserQuestion');
    expect(body['indices'], [0]);
    expect(body['answers'], ['GitHub Actions']);
    // Single answer adds the convenience alias.
    expect(body['answer'], 'GitHub Actions');
  });

  test('submitFreeText answers with index -1 and the typed text', () {
    c.add(_ask());
    c.submitFreeText('r1', 'feat/ci');
    final (_, body) = responses.single;
    expect(body['indices'], [-1]);
    expect(body['answers'], ['feat/ci']);
  });

  test('a responded event clears a card answered elsewhere', () {
    c.add(_ask());
    responded.add('r1');
    // Give the stream microtask a chance to run.
    return Future<void>.delayed(Duration.zero, () {
      expect(c.state.containsKey('s1'), isFalse);
    });
  });

  test('cancel sends the cancelled shape and clears', () {
    c.add(_ask());
    c.cancel('r1');
    expect(c.state.containsKey('s1'), isFalse);
    final (_, body) = responses.single;
    expect(body['kind'], 'askUserQuestion');
    expect(body['cancelled'], true);
  });

  test('enableFreeText flips the flag on a single-question ask', () {
    c.add(_ask());
    c.enableFreeText('r1');
    expect(c.state['s1']?.freeText, isTrue);
  });

  test('enableFreeText is a no-op for a multi-question ask', () {
    c.add(
      _ask(
        questions: [
          {
            'question': 'Q1',
            'options': [
              {'label': 'A'},
            ],
          },
          {
            'question': 'Q2',
            'options': [
              {'label': 'B'},
            ],
          },
        ],
      ),
    );
    c.enableFreeText('r1');
    expect(c.state['s1']?.freeText, isFalse);
  });

  group('multi-select over ctx.ui.input', () {
    const title =
        'Which platforms?\n\nContext:\nThe build matrix drives CI cost.\n\n'
        'Options (select one or more):\n'
        '1. iOS \u2014 iPhone + iPad\n'
        '2. macOS \u2014 desktop app\n'
        '3. Android';

    test('fromMultiSelectInput parses question, context, and options', () {
      final ask = PendingAsk.fromMultiSelectInput(
        requestId: 'r1',
        sessionId: 's1',
        title: title,
      )!;
      expect(ask.viaInputText, isTrue);
      final q = ask.questions.single;
      expect(q['question'], 'Which platforms?');
      expect(q['context'], 'The build matrix drives CI cost.');
      expect(q['multi'], true);
      final opts = (q['options'] as List).cast<Map<String, dynamic>>();
      expect(opts.map((o) => o['label']), ['iOS', 'macOS', 'Android']);
      expect(opts[0]['description'], 'iPhone + iPad');
      expect(opts[2].containsKey('description'), isFalse);
    });

    test('fromMultiSelectInput returns null for ordinary free-text input', () {
      expect(
        PendingAsk.fromMultiSelectInput(
          requestId: 'r1',
          sessionId: 's1',
          title: 'What should I name the branch?',
        ),
        isNull,
      );
    });

    test('submit answers on the input channel as comma-separated titles', () {
      c.add(
        PendingAsk.fromMultiSelectInput(
          requestId: 'r1',
          sessionId: 's1',
          title: title,
        )!,
      );
      // AskCard joins a multi-select question's picks with ' + '.
      c.submit('r1', indices: [0], answers: ['iOS + macOS']);
      final (id, body) = responses.single;
      expect(id, 'r1');
      expect(body['kind'], 'input');
      expect(body['value'], 'iOS, macOS');
      expect(c.state.containsKey('s1'), isFalse);
    });

    test('cancel answers on the input channel', () {
      c.add(
        PendingAsk.fromMultiSelectInput(
          requestId: 'r1',
          sessionId: 's1',
          title: title,
        )!,
      );
      c.cancel('r1');
      final (_, body) = responses.single;
      expect(body['kind'], 'input');
      expect(body['cancelled'], true);
    });
  });
}
