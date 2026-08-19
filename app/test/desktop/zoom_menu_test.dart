// SPEC-pane-zoom D7/D8: the native View menu is rendered by Swift, but Dart owns
// the bindings. These tests pin the payload contract between the two halves —
// the id, the label, the AppKit key equivalent and the modifier mask — and the
// click coming back.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/zoom_menu.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap.dart';
import 'package:makit/shortcuts/shortcut_action.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ZoomMenuBridge.channelName);
  late List<MethodCall> toPlatform;
  late List<ShortcutAction> invoked;
  late ZoomMenuBridge bridge;

  setUp(() {
    toPlatform = [];
    invoked = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          toPlatform.add(call);
          return null;
        });
    bridge = ZoomMenuBridge(onInvoke: invoked.add);
  });

  tearDown(() {
    bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Sends an `invoke` from the platform side, as Swift does on a click.
  Future<void> click(String id) => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        ZoomMenuBridge.channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall('invoke', id)),
        (_) {},
      );

  /// The item maps of the single `setItems` call made so far.
  List<Map<Object?, Object?>> published() =>
      (toPlatform.single.arguments as List).cast<Map<Object?, Object?>>();

  group('publish', () {
    test('sends the three items in menu order', () async {
      await bridge.publish(Keymap.defaults(cmdIsPrimary: true));
      expect(toPlatform.single.method, 'setItems');
      expect(published().map((i) => i['id']), [
        'zoomIn',
        'zoomOut',
        'zoomReset',
      ]);
    });

    test('carries the labels the menu shows', () async {
      await bridge.publish(Keymap.defaults(cmdIsPrimary: true));
      expect(published().map((i) => i['label']), [
        'Zoom in',
        'Zoom out',
        // Not "Zoom": Window > Zoom already means maximise the window (D9).
        'Actual size',
      ]);
    });

    test('maps the default chords to AppKit key equivalents', () async {
      await bridge.publish(Keymap.defaults(cmdIsPrimary: true));
      expect(published().map((i) => i['key']), ['=', '-', '0']);
      // 1 << 20 is NSEvent.ModifierFlags.command.
      expect(published().map((i) => i['modifiers']), [
        1 << 20,
        1 << 20,
        1 << 20,
      ]);
    });

    test('uses control as the primary modifier off macOS', () async {
      await bridge.publish(Keymap.defaults(cmdIsPrimary: false));
      // 1 << 18 is NSEvent.ModifierFlags.control.
      expect(published().map((i) => i['modifiers']), [
        1 << 18,
        1 << 18,
        1 << 18,
      ]);
    });

    test(
      'follows a rebind, so the menu never shows a stale shortcut',
      () async {
        final rebound = Keymap.defaults(cmdIsPrimary: true).rebind(
          ShortcutAction.zoomIn,
          const KeyChord(LogicalKeyboardKey.keyK, meta: true, shift: true),
        );
        await bridge.publish(rebound);
        expect(published().first['key'], 'k');
        expect(published().first['modifiers'], (1 << 20) | (1 << 17));
      },
    );

    test(
      'lower-cases the key, since AppKit reads upper case as +Shift',
      () async {
        final rebound = Keymap.defaults(cmdIsPrimary: true).rebind(
          ShortcutAction.zoomReset,
          const KeyChord(LogicalKeyboardKey.keyG, meta: true),
        );
        await bridge.publish(rebound);
        expect(published().last['key'], 'g');
      },
    );
  });

  group('invoke', () {
    test('turns a click into the matching action', () async {
      await click('zoomIn');
      await click('zoomReset');
      expect(invoked, [ShortcutAction.zoomIn, ShortcutAction.zoomReset]);
    });

    test(
      'ignores an unknown id rather than throwing on the platform thread',
      () async {
        await click('nonsense');
        expect(invoked, isEmpty);
      },
    );

    test('ignores an action that is not a zoom action', () async {
      await click('newSession');
      expect(invoked, isEmpty);
    });
  });
}
