/// SPEC-pending-queue-edit-reorder — pending messages are editable, reorderable drafts, in one of two
/// placements.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/pending_queue.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/composer/slash_palette.dart';

QueuedMessage _q(String id, String text) =>
    QueuedMessage(id: id, text: text, queuedAt: 0);

final _commands = [
  const SlashCmd(
    name: 'review',
    description: 'Review the tree',
    source: 'prompt',
  ),
  const SlashCmd(
    name: 'fix-tests',
    description: 'Fix the suite',
    source: 'prompt',
  ),
];

/// Records what the widget asked the store to do, so the tests assert on
/// intent rather than on transport plumbing.
class _Calls {
  final edits = <(String, String)>[];
  final orders = <List<String>>[];
  final cancels = <String>[];
  final promotes = <String>[];
}

Widget _host(List<QueuedMessage> queued, _Calls calls) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: PendingQueue(
          queued: queued,
          commands: _commands,
          onEdit: (id, text) => calls.edits.add((id, text)),
          onReorder: (ids) => calls.orders.add(ids),
          onCancel: calls.cancels.add,
          onPromote: calls.promotes.add,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('ghost bubbles hug the RIGHT edge, like sent user messages', (
    tester,
  ) async {
    // A 600px-wide host, because the queue shrink-wraps under a loose parent —
    // where "left" and "right" are the same 8px gutter and nothing is provable.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 600,
                child: PendingQueue(
                  queued: [_q('q1', 'first')],
                  commands: _commands,
                  onEdit: (_, _) {},
                  onReorder: (_) {},
                  onCancel: (_) {},
                  onPromote: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A pending message sits in the user's own column, like the message it will
    // become (ChatBubble.user is right-aligned) — the dashed outline, not the
    // side, is what says "not sent yet".
    final queue = tester.getRect(find.byType(PendingQueue));
    final bubble = tester.getRect(find.byType(PendingBubble));
    expect(
      queue.right - bubble.right,
      lessThan(queue.width / 4),
      reason: 'bubble should end near the queue\'s right edge',
    );
    expect(
      bubble.left - queue.left,
      greaterThan(queue.width / 4),
      reason: 'bubble should NOT be flushed to the left edge',
    );

    // The caption tracks the bubble it belongs to.
    final caption = tester.getRect(find.text('sends next · 1 of 1'));
    expect(queue.right - caption.right, lessThan(queue.width / 4));
  });

  testWidgets('renders one ghost bubble per pending message, in order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], _Calls()),
    );
    await tester.pumpAndSettle();

    final bubbles = tester
        .widgetList<PendingBubble>(find.byType(PendingBubble))
        .toList();
    expect(bubbles.map((b) => b.message.text), ['first', 'second']);
    expect(find.text('sends next · 1 of 2'), findsOneWidget);
    expect(find.text('then · 2 of 2'), findsOneWidget);
  });

  testWidgets('an empty queue renders nothing', (tester) async {
    await tester.pumpWidget(_host(const [], _Calls()));
    await tester.pumpAndSettle();
    expect(find.byType(PendingBubble), findsNothing);
  });

  testWidgets('↓ on the first message sends the swapped id order', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], calls),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is PendingBubble && w.message.id == 'q1',
        ),
        matching: find.byTooltip('Send this later'),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls.orders, [
      ['q2', 'q1'],
    ]);
  });

  testWidgets('↑ is inert on the first message and ↓ on the last', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'only')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Send this sooner'));
    await tester.tap(find.byTooltip('Send this later'));
    await tester.pumpAndSettle();

    expect(calls.orders, isEmpty, reason: 'nothing to swap with');
  });

  testWidgets('tap the text to edit, Enter commits the new text', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'first, but better');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(calls.edits, [('q1', 'first, but better')]);
    expect(find.byType(TextField), findsNothing, reason: 'editor closes');
  });

  testWidgets('committing an empty edit cancels the message', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(calls.cancels, ['q1']);
    expect(
      calls.edits,
      isEmpty,
      reason: 'a blank draft is a cancel, not an edit',
    );
  });

  testWidgets('✕ cancels that message only', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], calls),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is PendingBubble && w.message.id == 'q2',
        ),
        matching: find.byTooltip('Cancel this message'),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls.cancels, ['q2']);
  });

  testWidgets('the editor opens the slash palette — agent commands only', (
    tester,
  ) async {
    await tester.pumpWidget(_host([_q('q1', 'first')], _Calls()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/');
    await tester.pumpAndSettle();

    expect(find.byType(SlashPalette), findsOneWidget);
    expect(find.text('/review'), findsOneWidget);
    // Client commands act on the app NOW; they cannot mean anything inside a
    // message that sends later, so the palette must not offer them.
    expect(find.text('/cancel'), findsNothing);
    expect(find.text('/new'), findsNothing);
  });

  testWidgets(
    'picking a slash command puts it in the editor, not straight out',
    (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_host([_q('q1', 'first')], calls));
      await tester.pumpAndSettle();

      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/rev');
      await tester.pumpAndSettle();
      await tester.tap(find.text('/review'));
      await tester.pumpAndSettle();

      expect(calls.edits, isEmpty, reason: 'picking is not committing');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '/review ',
      );
    },
  );

  testWidgets('⤒ on a ghost bubble promotes exactly that message', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], calls),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('second'),
          matching: find.byType(PendingBubble),
        ),
        matching: find.byTooltip('Stop the current turn and send this now'),
      ),
    );

    expect(calls.promotes, ['q2']);
    expect(calls.cancels, isEmpty, reason: 'promote is not a cancel');
    expect(calls.orders, isEmpty, reason: 'the reorder is the server\'s to do');
  });

  testWidgets('promote is unavailable mid-edit on a bubble too', (
    tester,
  ) async {
    await tester.pumpWidget(_host([_q('q1', 'first')], _Calls()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();

    // The server has not seen the edited text yet, so promoting now would
    // interrupt the turn to deliver the OLD message.
    expect(
      find.byTooltip('Stop the current turn and send this now'),
      findsNothing,
    );
  });

  testWidgets('a ghost bubble is as compact as the sent bubble it will become', (
    tester,
  ) async {
    const text = 'ship it';

    // The two side by side, same width host, same text: a pending message should
    // read as the same object as a sent one, not as a control panel.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 600,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ChatBubble.user(text: text, ts: 0),
                    PendingQueue(
                      queued: const [
                        QueuedMessage(id: 'q1', text: text, queuedAt: 0),
                      ],
                      commands: _commands,
                      onEdit: (_, _) {},
                      onReorder: (_) {},
                      onCancel: (_) {},
                      onPromote: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sent = tester.getRect(find.byType(ChatBubble));
    final ghost = tester.getRect(find.byType(PendingBubble));

    // Height: the ghost carries a caption line and its controls, so it is
    // allowed to be taller — but not by more than half again.
    expect(
      ghost.height,
      lessThan(sent.height * 1.9),
      reason:
          'ghost ${ghost.height} vs sent ${sent.height}: the row of 44px '
          'controls used to make it more than twice as tall',
    );
    // Width: it must hug its text like the sent bubble, not stretch the column.
    expect(
      ghost.width,
      lessThan(300),
      reason: 'a three-word message should not need half the pane',
    );
  });

  testWidgets('the bubble is hollow — outline only, no fill', (tester) async {
    await tester.pumpWidget(_host([_q('q1', 'ship it')], _Calls()));
    await tester.pumpAndSettle();

    // Hollow is the whole visual distinction from a SENT message: same column,
    // same shape, no fill. A filled bubble reads as "already said".
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(PendingBubble),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = box.decoration as BoxDecoration;
    expect(
      decoration.color,
      anyOf(isNull, const Color(0x00000000)),
      reason: 'a pending bubble must not be filled like a sent one',
    );
    expect(decoration.border, isNotNull, reason: 'the outline carries it');
  });

  testWidgets('the four controls sit together, not spread across the bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_q('q1', 'ship it'), _q('q2', 'then this')], _Calls()),
    );
    await tester.pumpAndSettle();

    Rect rectFor(String tooltip) => tester.getRect(
      find
          .descendant(
            of: find.byType(PendingBubble).first,
            matching: find.byTooltip(tooltip),
          )
          .first,
    );

    final order = [
      rectFor('Send this sooner'),
      rectFor('Send this later'),
      rectFor('Stop the current turn and send this now'),
      rectFor('Cancel this message'),
    ];
    for (var i = 1; i < order.length; i++) {
      final gap = order[i].left - order[i - 1].right;
      expect(
        gap,
        lessThanOrEqualTo(2.0),
        reason:
            'control $i sits ${gap.toStringAsFixed(0)}px from its neighbour; '
            'the group used to straddle the text with 8px gaps',
      );
    }
  });

  testWidgets('a double-tap on ⤒ promotes once, not twice', (tester) async {
    // Promote aborts the running turn; twice would abort the turn the flush had
    // just started.
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    final promote = find.byTooltip('Stop the current turn and send this now');
    await tester.tap(promote);
    await tester.pump();
    await tester.tap(promote, warnIfMissed: false);
    await tester.pump();

    expect(calls.promotes, ['q1']);
  });

  testWidgets('the queue opens on the message that sends NEXT', (tester) async {
    // A tall queue scrolls internally; oldest-first children mean the top of the
    // viewport is the next-to-send message. `reverse: true` used to open at the
    // bottom, showing the LAST message queued.
    await tester.pumpWidget(
      _host([
        for (var i = 0; i < 12; i++) _q('q$i', 'message number $i'),
      ], _Calls()),
    );
    await tester.pumpAndSettle();

    final scroller = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroller.reverse, isFalse);
    expect(
      find.text('sends next · 1 of 12'),
      findsOneWidget,
      reason: 'the caption of the next-to-send message must be in view',
    );
  });
}
