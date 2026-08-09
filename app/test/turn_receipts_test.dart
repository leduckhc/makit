import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/store/turns.dart';

/// The fold's output for a two-turn transcript, hand-built so the projection is
/// tested independently of `deriveTurns` (which has its own suite).
List<ChatItem> _items() => [
  UserMessageItem(seq: 1, ts: 1000, text: 'first'),
  ToolCallItem(seq: 2, ts: 1100, callId: 'c1', name: 'read', args: const {}),
  AgentMessageItem(seq: 3, ts: 1200, text: 'done'),
  UserMessageItem(seq: 5, ts: 5000, text: 'second'),
  AgentMessageItem(seq: 6, ts: 5200, text: 'done again'),
];

TurnSpan _span({
  required int openTs,
  required int closeTs,
  required int openSeq,
  required int closeSeq,
  int gatedMs = 0,
  int toolCount = 1,
}) => TurnSpan(
  openTs: openTs,
  closeTs: closeTs,
  openSeq: openSeq,
  closeSeq: closeSeq,
  gatedMs: gatedMs,
  toolCount: toolCount,
  hasAgentMessage: true,
);

void main() {
  group('withTurnReceipts — projecting D9 receipts into the fold', () {
    test('a receipt lands after the last item of its turn', () {
      final out = withTurnReceipts(_items(), [
        _span(openTs: 1000, closeTs: 1300, openSeq: 1, closeSeq: 4),
      ]);
      // The receipt sits after seq 3 (the turn's last row) and before seq 5.
      final kinds = out.map((i) => i.runtimeType.toString()).toList();
      expect(kinds.indexOf('TurnReceiptItem'), 3);
      expect(out.length, _items().length + 1);
    });

    test('carries wall clock, gate time and tool count', () {
      final out = withTurnReceipts(_items(), [
        _span(
          openTs: 1000,
          closeTs: 401000,
          openSeq: 1,
          closeSeq: 4,
          gatedMs: 252000,
          toolCount: 14,
        ),
      ]);
      final r = out.whereType<TurnReceiptItem>().single;
      expect(r.wallMs, 400000);
      expect(r.gatedMs, 252000);
      expect(r.toolCount, 14);
    });

    test('two turns get two receipts, each after its own turn', () {
      final out = withTurnReceipts(_items(), [
        _span(openTs: 1000, closeTs: 1300, openSeq: 1, closeSeq: 4),
        _span(openTs: 5000, closeTs: 5300, openSeq: 5, closeSeq: 7),
      ]);
      expect(out.whereType<TurnReceiptItem>().length, 2);
      expect(out.last, isA<TurnReceiptItem>());
    });

    test('no spans leaves the list untouched and identical', () {
      final items = _items();
      expect(withTurnReceipts(items, const []), same(items));
    });

    test('a receipt for a turn whose rows are absent is dropped, not appended '
        'at a wrong position', () {
      // A tail-only transcript can hold a span whose rows were never loaded.
      final out = withTurnReceipts(
        [UserMessageItem(seq: 90, ts: 9000, text: 'late')],
        [_span(openTs: 1000, closeTs: 1300, openSeq: 1, closeSeq: 4)],
      );
      expect(out.whereType<TurnReceiptItem>(), isEmpty);
    });
  });
}
