import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../shortcuts/key_chord.dart';
import '../shortcuts/keymap.dart';
import '../shortcuts/shortcut_action.dart';

/// The Dart half of the native View-menu zoom items (SPEC-pane-zoom D7, D8).
///
/// Dart is the source of truth for the bindings, because the keymap is
/// rebindable in Settings → Shortcuts and macOS consumes a menu item's key
/// equivalent before Flutter sees the keystroke. So this pushes the labels and
/// key equivalents down to Swift on every keymap change, and turns a click back
/// into the matching action.
class ZoomMenuBridge {
  /// Binds the bridge to [channel], and reports a chosen item to [onInvoke].
  ZoomMenuBridge({required this.onInvoke, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handle);
  }

  /// The channel `ZoomMenu.swift` listens on.
  static const String channelName = 'makit/zoom_menu';

  /// The actions the menu shows, in the order macOS displays them.
  static const List<ShortcutAction> actions = [
    ShortcutAction.zoomIn,
    ShortcutAction.zoomOut,
    ShortcutAction.zoomReset,
  ];

  /// `NSEvent.ModifierFlags` raw values. Fixed by AppKit, so they are safe to
  /// hard-code and cheaper than another round trip to ask.
  static const int _shift = 1 << 17;
  static const int _control = 1 << 18;
  static const int _option = 1 << 19;
  static const int _command = 1 << 20;

  /// Called with the action a menu click chose.
  final void Function(ShortcutAction action) onInvoke;

  final MethodChannel _channel;

  /// Pushes the current [keymap]'s labels and key equivalents to the menu.
  ///
  /// Reads `bindings` rather than `chordFor`, which throws on an unbound action.
  /// A menu that renders without a shortcut beats a crash on startup.
  Future<void> publish(Keymap keymap) => _channel.invokeMethod<void>(
    'setItems',
    [for (final action in actions) _spec(action, keymap.bindings[action])],
  );

  /// One item as Swift expects it. A null chord renders with no shortcut, which
  /// is what an unbound action should look like.
  static Map<String, Object?> _spec(ShortcutAction action, KeyChord? chord) => {
    'id': action.id,
    'label': action.label,
    if (chord != null) ...{
      'key': _keyEquivalent(chord),
      'modifiers': _modifiers(chord),
    },
  };

  /// The single character AppKit matches on. Lower case, because AppKit treats
  /// an upper-case equivalent as implying Shift.
  static String _keyEquivalent(KeyChord chord) =>
      chord.trigger.keyLabel.toLowerCase();

  static int _modifiers(KeyChord chord) =>
      (chord.meta ? _command : 0) |
      (chord.control ? _control : 0) |
      (chord.alt ? _option : 0) |
      (chord.shift ? _shift : 0);

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'invoke') return null;
    final id = call.arguments;
    if (id is! String) return null;
    final action = ShortcutAction.byId(id);
    // An unknown id means the two halves disagree; ignore it rather than throw
    // on the platform thread.
    if (action == null || !actions.contains(action)) return null;
    onInvoke(action);
    return null;
  }

  /// Stops listening. The menu keeps its last pushed items.
  @visibleForTesting
  void dispose() => _channel.setMethodCallHandler(null);
}
