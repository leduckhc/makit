import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/desktop/settings/settings_window.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Proves the Settings overlay is modal to keyboard input: window-scope
/// shortcuts do not leak through to the chat underneath, and Escape closes it.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<KeymapController> controller() async {
    final prefs = await SharedPreferences.getInstance();
    return KeymapController.load(prefs, cmdIsPrimary: false);
  }

  Future<void> pumpShell(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopKeymapScope(
            onOpenSettings: () =>
                container.read(settingsOpenProvider.notifier).state = true,
            child: const DesktopWindowBody(
              child: Scaffold(body: Text('shell')),
            ),
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

  testWidgets('window shortcuts do not fire while Settings is open', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpShell(tester, container);

    container.read(settingsOpenProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.byType(SettingsWindow), findsOneWidget);

    // Ctrl+B (toggle sidebar) must be swallowed by the modal overlay.
    expect(container.read(sidebarCollapsedProvider), isFalse);
    await pressCtrl(tester, LogicalKeyboardKey.keyB);
    expect(container.read(sidebarCollapsedProvider), isFalse);
  });

  testWidgets('Escape closes the Settings overlay', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpShell(tester, container);

    container.read(settingsOpenProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.byType(SettingsWindow), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(settingsOpenProvider), isFalse);
    expect(find.byType(SettingsWindow), findsNothing);
  });

  testWidgets('open-settings chord toggles the overlay closed', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpShell(tester, container);

    container.read(settingsOpenProvider.notifier).state = true;
    await tester.pumpAndSettle();

    await pressCtrl(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(container.read(settingsOpenProvider), isFalse);
  });
}
