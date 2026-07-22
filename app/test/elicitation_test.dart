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
}
