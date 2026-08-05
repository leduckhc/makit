import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/slash_palette.dart';

void _noop(String _) {}

void main() {
  const commands = [
    SlashCmd(
      name: 'fix-tests',
      description: 'Repair failing tests',
      source: 'prompt',
    ),
    SlashCmd(
      name: 'skill:review',
      description: 'Review a diff',
      source: 'skill',
    ),
  ];

  group('filterSlashCommands', () {
    test('empty query lists builtins and agent commands, deduped', () {
      final all = filterSlashCommands('/', commands);
      final names = all.map((c) => c.name).toList();
      // Builtins (client-side) plus the agent-provided ones.
      expect(names, contains('compact'));
      expect(names, contains('fix-tests'));
      expect(names, contains('skill:review'));
      expect(names.toSet().length, names.length);
    });

    test('prefix matches sort ahead of description-only matches', () {
      final matches = filterSlashCommands('/fix', commands);
      expect(matches.first.name, 'fix-tests');
    });

    test('matches on description too', () {
      final matches = filterSlashCommands('/diff', commands);
      expect(matches.map((c) => c.name), contains('skill:review'));
    });
  });

  group('slash palette in the composer', () {
    Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: ColoredBox(color: Color(0xFF000000))),
            child,
          ],
        ),
      ),
    );

    Future<void> openPalette(WidgetTester tester) async {
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
    }

    testWidgets('floats over the chat without moving the composer', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      // Baseline *after* focusing: focus alone expands the composer, so measure
      // from the focused state to isolate the palette's effect.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.byType(TextField));

      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();

      expect(find.byType(SlashPalette), findsOneWidget);
      // The palette is an overlay: the composer (and therefore the transcript
      // above it) must not shift by a single pixel when it opens.
      expect(tester.getTopLeft(find.byType(TextField)), before);
    });

    testWidgets('stays inside the viewport so the top row is reachable', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await openPalette(tester);

      final rect = tester.getRect(find.byType(SlashPalette));
      expect(rect.top, greaterThanOrEqualTo(0.0));
      expect(rect.height, lessThanOrEqualTo(kSlashPaletteMaxHeight));
    });

    testWidgets('shrinks to the free space on a short viewport', (
      tester,
    ) async {
      // A landscape phone with a hardware keyboard: barely any room above the
      // composer. The popover must fit under the status bar + top bar instead
      // of overflowing the screen (it renders in the Overlay, above them).
      tester.view.physicalSize = const Size(800, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await openPalette(tester);

      final rect = tester.getRect(find.byType(SlashPalette));
      expect(rect.top, greaterThanOrEqualTo(kToolbarHeight));
    });

    testWidgets('arrow keys move the highlight and Tab picks it', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await openPalette(tester);

      final matches = filterSlashCommands('/', commands);
      // First row starts highlighted.
      expect(selectedCommandName(tester), matches.first.name);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selectedCommandName(tester), matches[1].name);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(selectedCommandName(tester), matches.first.name);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      // Tab selects the highlighted command into the field and closes.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '${matches[1].invocation} ',
      );
      expect(find.byType(SlashPalette), findsNothing);
    });

    testWidgets('arrowing past the visible window fully reveals the row', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await openPalette(tester);

      // Walk past the five visible rows, so the list has to scroll.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }

      final row = tester.getRect(find.byKey(kSlashSelectedRowKey));
      final list = tester.getRect(find.byType(ListView));
      // Fully revealed — not clipped by a hair at either edge (the list's own
      // vertical padding is part of its scroll extent).
      expect(row.top, greaterThanOrEqualTo(list.top));
      expect(row.bottom, lessThanOrEqualTo(list.bottom));
    });

    testWidgets('escape dismisses the palette, leaving the text alone', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await openPalette(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SlashPalette), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/',
      );
    });

    testWidgets('closes when the field loses focus', (tester) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await openPalette(tester);
      expect(find.byType(SlashPalette), findsOneWidget);

      // Leaving the composer (tapping the transcript) must take the popover
      // with it — there is nothing left to type into.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byType(SlashPalette), findsNothing);
    });

    testWidgets('tapping a row still picks it', (tester) async {
      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/fix');
      await tester.pumpAndSettle();

      await tester.tap(find.text('/fix-tests'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/fix-tests ',
      );
    });

    testWidgets('clicking a row picks it on desktop, where a pointer down '
        'outside a TextField unfocuses it', (tester) async {
      // The palette lives in the Overlay, i.e. outside the field's TapRegion.
      // On macOS/Windows/Linux the field's default onTapOutside unfocuses on
      // pointer DOWN, which (via the focus-loss dismissal) tore the row out
      // from under the click before it could fire.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      await tester.pumpWidget(
        wrap(const Composer(onSend: _noop, commands: commands)),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/fix');
      await tester.pumpAndSettle();

      // A real click has frames between pointer-down and pointer-up; `tap()`
      // synthesises both without pumping, which is exactly what hid this bug.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('/fix-tests')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/fix-tests ',
      );
      // And the caret stays in the field, ready for the command's arguments.
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      // Reset inside the body: the binding asserts no debug var is left set,
      // and it checks that before addTearDown callbacks run.
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

/// The command name of the currently highlighted palette row.
String selectedCommandName(WidgetTester tester) {
  final text = tester.widget<Text>(
    find
        .descendant(
          of: find.byKey(kSlashSelectedRowKey),
          matching: find.byType(Text),
        )
        .first,
  );
  return text.data!.substring(1); // strip the leading '/'
}
