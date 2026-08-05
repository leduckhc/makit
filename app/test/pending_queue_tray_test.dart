// The queue tray (mockup variant C) — the compact alternative presentation, and
// the only one that offers **promote**.
//
// These tests assert intent, not transport: the widget reports what the user
// asked for (edit / reorder / cancel / promote) and the store turns that into a
// command. What promote *does* to a running turn is proved server-side, in
// session.test.ts and ws/commands/queue.test.ts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/pending_queue_tray.dart';
import 'package:makit/ui/composer/slash_palette.dart';

QueuedMessage _q(String id, String text) =>
    QueuedMessage(id: id, text: text, queuedAt: 0);

const _commands = [
  SlashCmd(name: 'review', description: 'Review the diff', source: 'prompt'),
  SlashCmd(name: 'fix-tests', description: 'Fix the suite', source: 'prompt'),
];

class _Calls {
  final edits = <(String, String)>[];
  final orders = <List<String>>[];
  final cancels = <String>[];
  final promotes = <String>[];
}

Widget _host(List<QueuedMessage> queued, _Calls calls) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: 600,
        child: PendingQueueTray(
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
  testWidgets('renders one row per pending message, with a count header', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], _Calls()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TrayRow), findsNWidgets(2));
    expect(find.text('2 messages waiting'), findsOneWidget);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('the header is singular for one message', (tester) async {
    await tester.pumpWidget(_host([_q('q1', 'only')], _Calls()));
    await tester.pumpAndSettle();
    expect(find.text('1 message waiting'), findsOneWidget);
  });

  testWidgets('an empty queue renders nothing at all', (tester) async {
    await tester.pumpWidget(_host([], _Calls()));
    await tester.pumpAndSettle();
    expect(find.byType(TrayRow), findsNothing);
    expect(find.textContaining('waiting'), findsNothing);
  });

  testWidgets('⤒ promotes exactly that message', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], calls),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('second'),
          matching: find.byType(TrayRow),
        ),
        matching: find.byTooltip('Stop the current turn and send this now'),
      ),
    );

    expect(calls.promotes, ['q2']);
    expect(calls.cancels, isEmpty, reason: 'promote is not a cancel');
    expect(
      calls.orders,
      isEmpty,
      reason: 'the order is the server\'s to change',
    );
  });

  testWidgets('promote is spelled out as an interrupt, not as "now"', (
    tester,
  ) async {
    // The label is the only place the user learns promote costs them the turn in
    // flight, so it is worth a test of its own.
    await tester.pumpWidget(_host([_q('q1', 'first')], _Calls()));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Stop the current turn and send this now'),
      findsOneWidget,
    );
  });

  testWidgets('↓ on the first row asks for the swapped order', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], calls),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('first'),
          matching: find.byType(TrayRow),
        ),
        matching: find.byTooltip('Send this later'),
      ),
    );

    expect(calls.orders, [
      ['q2', 'q1'],
    ]);
  });

  testWidgets('↑ is inert on the first row, ↓ on the last', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host([_q('q1', 'first'), _q('q2', 'second')], calls),
    );
    await tester.pumpAndSettle();

    final firstRow = find.ancestor(
      of: find.text('first'),
      matching: find.byType(TrayRow),
    );
    final lastRow = find.ancestor(
      of: find.text('second'),
      matching: find.byType(TrayRow),
    );
    final up = tester.widget<IconButton>(
      find.descendant(
        of: firstRow,
        matching: find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Send this sooner',
        ),
      ),
    );
    final down = tester.widget<IconButton>(
      find.descendant(
        of: lastRow,
        matching: find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Send this later',
        ),
      ),
    );
    expect(up.onPressed, isNull);
    expect(down.onPressed, isNull);
    expect(calls.orders, isEmpty);
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

    await tester.enterText(find.byType(TextField), 'first, revised');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(calls.edits, [('q1', 'first, revised')]);
  });

  testWidgets('✕ while editing abandons the edit instead of cancelling', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'never mind');
    await tester.tap(find.byTooltip('Cancel this message'));
    await tester.pumpAndSettle();

    expect(calls.cancels, isEmpty, reason: 'the message must survive');
    expect(calls.edits, isEmpty, reason: 'the abandoned text must not commit');
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('✕ when not editing cancels the message', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Cancel this message'));
    await tester.pumpAndSettle();

    expect(calls.cancels, ['q1']);
  });

  testWidgets(
    'promote is unavailable mid-edit — the text is not committed yet',
    (tester) async {
      await tester.pumpWidget(_host([_q('q1', 'first')], _Calls()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();

      final promote = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) =>
              w is IconButton &&
              w.tooltip == 'Stop the current turn and send this now',
        ),
      );
      expect(promote.onPressed, isNull);
    },
  );

  testWidgets('the editor offers the slash palette — agent commands only', (
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
    // A client command would run NOW; this message runs later.
    expect(find.text('/cancel'), findsNothing);
  });

  testWidgets('a double-tap on ⤒ promotes once, not twice', (tester) async {
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

  testWidgets('an edit commits trimmed text, like the bubble editor', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  padded on both sides  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(calls.edits, [('q1', 'padded on both sides')]);
  });

  testWidgets('any whitespace after a slash command closes the palette', (
    tester,
  ) async {
    // A tab or a pasted newline used to leave the palette open over the
    // arguments, because only a literal space was tested for.
    await tester.pumpWidget(_host([_q('q1', 'first')], _Calls()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/review');
    await tester.pumpAndSettle();
    expect(find.byType(SlashPalette), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/review\tthe diff');
    await tester.pumpAndSettle();
    expect(find.byType(SlashPalette), findsNothing);
  });

  testWidgets('committing an unchanged edit sends nothing', (tester) async {
    // Enter on an untouched row used to fire `queue.update` and a sessions
    // snapshot for a no-op (the bubble editor already suppressed this).
    final calls = _Calls();
    await tester.pumpWidget(_host([_q('q1', 'first')], calls));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(calls.edits, isEmpty);
    expect(calls.cancels, isEmpty);
  });

  testWidgets(
    'committing whitespace-only padding around the SAME text is a no-op',
    (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_host([_q('q1', 'first')], calls));
      await tester.pumpAndSettle();

      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  first  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(calls.edits, isEmpty, reason: 'trimmed, it is the same message');
    },
  );
}
