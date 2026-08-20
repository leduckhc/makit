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
  /// is what an unbound action should look like. A chord AppKit cannot express
  /// also renders with no shortcut, rather than a broken one.
  static Map<String, Object?> _spec(ShortcutAction action, KeyChord? chord) {
    final key = chord == null ? null : _keyEquivalent(chord);
    return {
      'id': action.id,
      'label': action.label,
      if (chord != null && key != null) ...{
        'key': key,
        'modifiers': _modifiers(chord),
      },
    };
  }

  /// The Unicode character AppKit matches on, or null when it cannot be
  /// expressed.
  ///
  /// AppKit compares a key equivalent against the input one keypress produces.
  /// A special key therefore needs its function-key character, not the
  /// multi-character Flutter label (`Arrow Up`, `F1`). A label that is neither a
  /// single character nor a known special key returns null, so the menu shows no
  /// shortcut instead of one that can never fire. Flutter still handles the
  /// chord either way.
  static String? _keyEquivalent(KeyChord chord) {
    final special = _appKitSpecialKeys[chord.trigger.keyId];
    if (special != null) return special;
    final label = chord.trigger.keyLabel;
    // Lower case, because AppKit treats an upper-case equivalent as implying
    // Shift, which would double the modifier the chord already carries.
    if (label.length == 1) return label.toLowerCase();
    return null;
  }

  /// AppKit's function-key characters, from `NSEvent.h`.
  static final Map<int, String> _appKitSpecialKeys = {
    LogicalKeyboardKey.arrowUp.keyId: '\uF700',
    LogicalKeyboardKey.arrowDown.keyId: '\uF701',
    LogicalKeyboardKey.arrowLeft.keyId: '\uF702',
    LogicalKeyboardKey.arrowRight.keyId: '\uF703',
    LogicalKeyboardKey.home.keyId: '\uF729',
    LogicalKeyboardKey.end.keyId: '\uF72B',
    LogicalKeyboardKey.pageUp.keyId: '\uF72C',
    LogicalKeyboardKey.pageDown.keyId: '\uF72D',
    LogicalKeyboardKey.delete.keyId: '\uF728',
    LogicalKeyboardKey.insert.keyId: '\uF727',
    LogicalKeyboardKey.help.keyId: '\uF746',
    // Control characters, which AppKit takes verbatim.
    LogicalKeyboardKey.enter.keyId: '\r',
    LogicalKeyboardKey.numpadEnter.keyId: '\u0003',
    LogicalKeyboardKey.tab.keyId: '\t',
    LogicalKeyboardKey.escape.keyId: '\u001B',
    LogicalKeyboardKey.backspace.keyId: '\u0008',
    LogicalKeyboardKey.space.keyId: ' ',
    // NSF1FunctionKey is 0xF704, and the rest follow in order.
    for (var i = 1; i <= 12; i++)
      _functionKeys[i - 1].keyId: String.fromCharCode(0xF703 + i),
  };

  static const List<LogicalKeyboardKey> _functionKeys = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ];

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

  /// Stops listening, and releases this bridge from the channel handler.
  ///
  /// The menu keeps its last pushed items. Call this when the owning scope goes
  /// away, or the handler keeps the bridge and its callback reachable.
  void dispose() => _channel.setMethodCallHandler(null);
}
