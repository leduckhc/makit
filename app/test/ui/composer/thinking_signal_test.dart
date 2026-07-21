import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/composer/client_commands.dart' show thinkingLevels;
import 'package:makit/ui/composer/composer_selectors.dart' show ThinkingSignal;

void main() {
  ThemeData theme() => ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  );

  Future<List<Container>> pumpBars(WidgetTester tester, String level) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: Scaffold(
          body: Center(child: ThinkingSignal(level: level)),
        ),
      ),
    );
    return tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(ThinkingSignal),
            matching: find.byType(Container),
          ),
        )
        .toList();
  }

  testWidgets('one bar per thinking level', (tester) async {
    final bars = await pumpBars(tester, 'medium');
    expect(bars.length, thinkingLevels.length);
  });

  testWidgets('bars at or below the current level use the strong ink', (
    tester,
  ) async {
    final cs = theme().colorScheme;
    final bars = await pumpBars(tester, 'medium');
    final strong = bars
        .where((c) => (c.decoration as BoxDecoration).color == cs.onSurface)
        .length;
    // 'medium' is index 3 → 4 filled bars (off, minimal, low, medium).
    expect(strong, thinkingLevels.indexOf('medium') + 1);
  });

  testWidgets('an unknown level leaves every bar faded', (tester) async {
    final cs = theme().colorScheme;
    final bars = await pumpBars(tester, 'bogus');
    final strong = bars
        .where((c) => (c.decoration as BoxDecoration).color == cs.onSurface)
        .length;
    expect(strong, 0);
  });
}
