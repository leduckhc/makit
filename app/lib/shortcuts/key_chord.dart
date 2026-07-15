import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;

/// A single key combination: a trigger key plus the modifiers that must be
/// held. Serializable to/from JSON so it can be persisted in
/// [SharedPreferences], and convertible to a Flutter [SingleActivator] for use
/// in a [Shortcuts] map.
///
/// Modifier semantics match [SingleActivator]: a `false` modifier means that
/// modifier must **not** be held. This is what makes ⇧+Enter distinct from a
/// plain Enter — a plain-Enter chord (`shift: false`) will not fire while Shift
/// is down, so the other chord can claim it.
@immutable
class KeyChord {
  /// Creates a chord for [trigger] with the given modifier requirements.
  const KeyChord(
    this.trigger, {
    this.meta = false,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  /// The key that triggers the chord (e.g. [LogicalKeyboardKey.enter]).
  final LogicalKeyboardKey trigger;

  /// Whether Command (macOS ⌘) must be held.
  final bool meta;

  /// Whether Control (⌃) must be held.
  final bool control;

  /// Whether Option/Alt (⌥) must be held.
  final bool alt;

  /// Whether Shift (⇧) must be held.
  final bool shift;

  /// True when this chord carries no non-shift modifier — i.e. it is a bare
  /// key or a Shift+key. Used to reject unmodified global shortcuts that would
  /// swallow ordinary typing.
  bool get hasNonShiftModifier => meta || control || alt;

  /// Builds the Flutter activator for a [Shortcuts] map.
  SingleActivator toActivator() => SingleActivator(
    trigger,
    meta: meta,
    control: control,
    alt: alt,
    shift: shift,
  );

  /// JSON representation: the logical key id plus modifier flags.
  Map<String, dynamic> toJson() => {
    'key': trigger.keyId,
    if (meta) 'meta': true,
    if (control) 'control': true,
    if (alt) 'alt': true,
    if (shift) 'shift': true,
  };

  /// Parses a chord from [json]; returns null when the payload is malformed.
  static KeyChord? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['key'];
    if (id is! int) return null;
    return KeyChord(
      LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id),
      meta: json['meta'] == true,
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
    );
  }

  /// A human-readable label using macOS-style modifier symbols in the
  /// canonical ⌃⌥⇧⌘ order followed by the key (e.g. `⇧↵`, `⌘,`).
  String get label {
    final b = StringBuffer();
    if (control) b.write('⌃');
    if (alt) b.write('⌥');
    if (shift) b.write('⇧');
    if (meta) b.write('⌘');
    b.write(_triggerLabel);
    return b.toString();
  }

  String get _triggerLabel {
    final special = _specialLabels[trigger.keyId];
    if (special != null) return special;
    final kl = trigger.keyLabel;
    if (kl.isNotEmpty) return kl.length == 1 ? kl.toUpperCase() : kl;
    return trigger.debugName ?? 'key';
  }

  static final Map<int, String> _specialLabels = {
    LogicalKeyboardKey.enter.keyId: '↵',
    LogicalKeyboardKey.numpadEnter.keyId: '↵',
    LogicalKeyboardKey.space.keyId: 'Space',
    LogicalKeyboardKey.tab.keyId: '⇥',
    LogicalKeyboardKey.escape.keyId: '⎋',
    LogicalKeyboardKey.backspace.keyId: '⌫',
    LogicalKeyboardKey.delete.keyId: '⌦',
    LogicalKeyboardKey.arrowUp.keyId: '↑',
    LogicalKeyboardKey.arrowDown.keyId: '↓',
    LogicalKeyboardKey.arrowLeft.keyId: '←',
    LogicalKeyboardKey.arrowRight.keyId: '→',
    LogicalKeyboardKey.comma.keyId: ',',
    LogicalKeyboardKey.period.keyId: '.',
    LogicalKeyboardKey.slash.keyId: '/',
    LogicalKeyboardKey.backslash.keyId: '\\',
    LogicalKeyboardKey.bracketLeft.keyId: '[',
    LogicalKeyboardKey.bracketRight.keyId: ']',
  };

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.trigger == trigger &&
      other.meta == meta &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(trigger, meta, control, alt, shift);

  @override
  String toString() => 'KeyChord($label)';
}
