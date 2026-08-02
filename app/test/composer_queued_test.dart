/// SPEC-35 — queued mid-turn messages in the composer.
///
/// A message the agent could not be steered with waits in a queue on the
/// server; the composer shows one chip per pending message, oldest first, each
/// cancellable. Chips live in the composer's own column (never a transcript
/// row) so SPEC-21 anchoring and SPEC-34's index-keyed markers are untouched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/queued_chips.dart';

QueuedMessage _q(String id, String text, {int? attachmentCount}) =>
    QueuedMessage(
      id: id,
      text: text,
      queuedAt: 0,
      attachmentCount: attachmentCount,
    );

void main() {
  test('sessions.snapshot decodes queued messages, defaulting to empty', () {
    final sessions = WireCodec.decodeSessions([
      {
        'id': 's1',
        'projectId': 'p',
        'agent': 'codex',
        'title': 't',
        'status': 'running',
        'policy': 'ask-on-risky',
        'queued': [
          {'id': 'q1', 'text': 'first', 'queuedAt': 7},
          {'id': 'q2', 'text': 'with pic', 'queuedAt': 9, 'attachmentCount': 2},
        ],
      },
      {
        'id': 's2',
        'projectId': 'p',
        'agent': 'pi',
        'title': 't',
        'status': 'idle',
        'policy': 'ask-on-risky',
      },
    ]);

    expect(sessions, isNotNull);
    expect(sessions![0].queued.map((q) => q.text), ['first', 'with pic']);
    expect(sessions[0].queued[0].id, 'q1');
    expect(sessions[0].queued[0].queuedAt, 7);
    expect(sessions[0].queued[1].attachmentCount, 2);
    expect(
      sessions[1].queued,
      isEmpty,
      reason: 'a server without a queue is empty',
    );
  });

  testWidgets('one chip per queued message, in order', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            queued: [_q('q1', 'first'), _q('q2', 'second')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(QueuedChip), findsNWidgets(2));
    final texts = tester
        .widgetList<QueuedChip>(find.byType(QueuedChip))
        .map((c) => c.message.text)
        .toList();
    expect(texts, ['first', 'second']);
  });

  testWidgets('no queue means no chip row at all', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Composer(onSend: (_) {}))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QueuedChips), findsNothing);
  });

  testWidgets('tapping ✕ cancels that message by id', (tester) async {
    final cancelled = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            queued: [_q('q1', 'first'), _q('q2', 'second')],
            onCancelQueued: cancelled.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is QueuedChip && w.message.id == 'q2',
        ),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();

    expect(cancelled, ['q2']);
  });

  testWidgets('chips show while the composer is disabled by an inline ask', (
    tester,
  ) async {
    // The messages still exist and must stay cancellable, exactly like staged
    // attachments (SPEC-33).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            enabled: false,
            disabledHint: 'Answer above…',
            queued: [_q('q1', 'first')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(QueuedChip), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('an attachment count is shown on the chip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            queued: [_q('q1', 'look', attachmentCount: 2)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
  });
}
