import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/sections/shortcuts_section.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/shortcuts/shortcut_action.dart';

Future<void> _pump(WidgetTester tester, KeymapController controller) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [keymapProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(home: Scaffold(body: ShortcutsSection())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders the section with Chat and Window scope headers', (
    tester,
  ) async {
    final controller = KeymapController.ephemeral(
      cmdIsPrimary: cmdIsPrimaryModifier,
    );
    await _pump(tester, controller);

    expect(find.text('SHORTCUTS'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('WINDOW'), findsOneWidget);
    expect(find.text('Send message'), findsOneWidget);
    expect(find.text('Focus composer'), findsOneWidget);
    // No overrides yet: no reset affordances and no Reset all.
    expect(find.byTooltip('Reset to default'), findsNothing);
    expect(find.text('Reset all'), findsNothing);
  });

  testWidgets('per-row reset restores an action to its default chord', (
    tester,
  ) async {
    final controller = KeymapController.ephemeral(
      cmdIsPrimary: cmdIsPrimaryModifier,
    );
    final defaultChord = controller.current.chordFor(ShortcutAction.newSession);
    // Rebind to a distinct chord so the row is "modified".
    await controller.rebind(
      ShortcutAction.newSession,
      const KeyChord(LogicalKeyboardKey.keyM, meta: true),
    );
    await _pump(tester, controller);

    expect(find.text('Reset all'), findsOneWidget);
    expect(find.text('Modified'), findsWidgets);

    // The New session row shows a reset; tapping it reverts to the default.
    final row = find.ancestor(
      of: find.text('New session'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Reset to default')),
    );
    await tester.pump();

    expect(
      controller.current.chordFor(ShortcutAction.newSession),
      defaultChord,
    );
  });

  testWidgets('Reset all reverts every override', (tester) async {
    final controller = KeymapController.ephemeral(
      cmdIsPrimary: cmdIsPrimaryModifier,
    );
    final defaults = controller.current;
    await controller.rebind(
      ShortcutAction.newSession,
      const KeyChord(LogicalKeyboardKey.keyM, meta: true),
    );
    await _pump(tester, controller);

    await tester.tap(find.text('Reset all'));
    await tester.pump();

    expect(controller.current, defaults);
    expect(find.text('Reset all'), findsNothing);
  });
}
