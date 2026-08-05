/// The composer's pending-queue slot (SPEC-35 wire → SPEC-38 UI).
///
/// The composer knows nothing about the queue's commands: it is handed a widget
/// and renders it above the field. That is what lets the identical queue widget
/// be mounted in the transcript instead (`PendingQueueSlot`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/ui/composer/composer.dart';

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

  test('a malformed queue entry is skipped, not fatal to the snapshot', () {
    final sessions = WireCodec.decodeSessions([
      {
        'id': 's1',
        'projectId': 'p',
        'agent': 'codex',
        'title': 't',
        'status': 'running',
        'policy': 'ask-on-risky',
        'queued': [
          {'text': 'no id'},
          {'id': 'q2', 'text': 'fine', 'queuedAt': 1},
          'garbage',
        ],
      },
    ]);
    expect(sessions!.single.queued.map((q) => q.id), ['q2']);
  });

  testWidgets('the composer renders the pending-queue widget it is given', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            pendingQueue: const Text('QUEUE HERE'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('QUEUE HERE'), findsOneWidget);
  });

  testWidgets('the queue stays visible while an inline ask disables the field', (
    tester,
  ) async {
    // The messages still exist and must stay cancellable, exactly like staged
    // attachments (SPEC-33) — otherwise one would fire when the ask is answered
    // with no way to have stopped it.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            enabled: false,
            disabledHint: 'Answer above…',
            pendingQueue: const Text('QUEUE HERE'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('QUEUE HERE'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('no queue widget means no extra chrome', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Composer(onSend: (_) {})),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('QUEUE HERE'), findsNothing);
  });
}
