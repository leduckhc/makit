/// The queue on the wire: `sessions.snapshot` → `Session.queued` (SPEC-35).
///
/// The composer-side widget tests that used to live here are gone with the
/// `Composer.pendingQueue` parameter: the queue is now a SIBLING above the
/// composer, not a child of it, and `pending_queue_outside_composer_test.dart`
/// holds that invariant.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/codec.dart';

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
}
