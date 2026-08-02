// T2 — SPEC-34: positions of the user's own messages within the transcript.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/navigator/user_message_indices.dart';

List<ChatItem> _items(String pattern) => [
  for (var i = 0; i < pattern.length; i++)
    switch (pattern[i]) {
      'u' => UserMessageItem(seq: i, ts: 0, text: 'user $i'),
      'a' => AgentMessageItem(seq: i, ts: 0, text: 'agent $i'),
      _ => ToolCallItem(
        seq: i,
        ts: 0,
        callId: 'c$i',
        name: 'bash',
        args: const {},
        ended: true,
      ),
    },
];

void main() {
  test('returns the ascending positions of user messages only', () {
    expect(userMessagePositions(_items('uatauua')), [0, 4, 5]);
  });

  test('empty and assistant-only transcripts yield no positions', () {
    expect(userMessagePositions(const []), isEmpty);
    expect(userMessagePositions(_items('ata')), isEmpty);
  });

  test('appending an assistant item leaves prior positions identical — the '
      'rail must not renumber itself while the agent streams', () {
    final before = userMessagePositions(_items('uau'));
    final after = userMessagePositions(_items('uaua'));
    expect(after.take(before.length), before);
    expect(after, before);
  });

  test('a user message is included even while it is the newest row', () {
    expect(userMessagePositions(_items('aau')), [2]);
  });

  test(
    'provider reads through chatItemsProvider and is stable across reads',
    () {
      final container = ProviderContainer(
        overrides: [
          chatItemsProvider.overrideWith((ref, id) => _items('uauua')),
        ],
      );
      addTearDown(container.dispose);
      final first = container.read(userMessagePositionsProvider('s1'));
      final second = container.read(userMessagePositionsProvider('s1'));
      expect(first, [0, 2, 3]);
      expect(second, same(first), reason: 'provider must cache, not recompute');
    },
  );

  test('an unknown session yields an empty list rather than throwing', () {
    final container = ProviderContainer(
      overrides: [chatItemsProvider.overrideWith((ref, id) => const [])],
    );
    addTearDown(container.dispose);
    expect(container.read(userMessagePositionsProvider('nope')), isEmpty);
  });
}
