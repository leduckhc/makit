import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/shortcuts/shortcut_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget-level proof that [DesktopKeymapScope] turns a persisted [Keymap] into
/// live global shortcuts. Uses Ctrl-primary defaults (cmdIsPrimary: false) so
/// the combos are deterministic regardless of the test host platform.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<KeymapController> controller() async {
    final prefs = await SharedPreferences.getInstance();
    return KeymapController.load(prefs, cmdIsPrimary: false);
  }

  Future<void> pumpScope(
    WidgetTester tester, {
    required KeymapController keymap,
    required VoidCallback onOpenSettings,
    required ProviderContainer container,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopKeymapScope(
            onOpenSettings: onOpenSettings,
            child: const Scaffold(body: Text('shell')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('Ctrl+B toggles the sidebar', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    expect(container.read(sidebarCollapsedProvider), isFalse);
    await pressCtrl(tester, LogicalKeyboardKey.keyB);
    expect(container.read(sidebarCollapsedProvider), isTrue);
    await pressCtrl(tester, LogicalKeyboardKey.keyB);
    expect(container.read(sidebarCollapsedProvider), isFalse);
  });

  testWidgets('Ctrl+, invokes the open-settings callback', (tester) async {
    final keymap = await controller();
    var opened = 0;
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () => opened++,
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.comma);
    expect(opened, 1);
  });

  testWidgets('rebinding is reflected live in the scope', (tester) async {
    final keymap = await controller();
    var opened = 0;
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () => opened++,
      container: container,
    );

    // Rebind open-settings to Ctrl+P, then that combo should fire it.
    await keymap.rebind(
      ShortcutAction.openSettings,
      const KeyChord(LogicalKeyboardKey.keyP, control: true),
    );
    await tester.pump();
    await pressCtrl(tester, LogicalKeyboardKey.keyP);
    expect(opened, 1);
  });
}
