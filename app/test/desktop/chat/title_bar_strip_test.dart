// Widget tests for TitleBarStrip's optional `title`/`titleInset` label — the
// passive worktree/branch caption shown on the traffic-light row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart' show kTrafficLightInset;
import 'package:makit/desktop/chat/title_bar_strip.dart';

Future<void> _pump(WidgetTester tester, TitleBarStrip strip) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: strip)));

void main() {
  group('TitleBarStrip title', () {
    testWidgets('renders no title label when none is given', (tester) async {
      await _pump(tester, const TitleBarStrip());
      expect(find.text('main'), findsNothing);
    });

    testWidgets('renders the given title label wrapped in IgnorePointer', (
      tester,
    ) async {
      await _pump(tester, const TitleBarStrip(title: Text('main')));

      expect(find.text('main'), findsOneWidget);
      // IgnorePointer keeps the passive label from swallowing window-drag
      // gestures underneath it. (Match the active one specifically: the
      // framework inserts other `ignoring: false` IgnorePointers around it.)
      expect(
        find.ancestor(
          of: find.text('main'),
          matching: find.byWidgetPredicate(
            (w) => w is IgnorePointer && w.ignoring,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('defaults titleInset to kTrafficLightInset', (tester) async {
      await _pump(tester, const TitleBarStrip(title: Text('main')));

      final positioned = tester.widget<Positioned>(
        find.ancestor(of: find.text('main'), matching: find.byType(Positioned)),
      );
      expect(positioned.left, kTrafficLightInset);
    });

    testWidgets('honors a custom titleInset', (tester) async {
      await _pump(
        tester,
        const TitleBarStrip(title: Text('main'), titleInset: 12),
      );

      final positioned = tester.widget<Positioned>(
        find.ancestor(of: find.text('main'), matching: find.byType(Positioned)),
      );
      expect(positioned.left, 12);
    });

    testWidgets('renders both a leading control and a title together', (
      tester,
    ) async {
      await _pump(
        tester,
        const TitleBarStrip(
          leading: Icon(Icons.menu),
          title: Text('feat/login'),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(find.text('feat/login'), findsOneWidget);
    });
  });
}
