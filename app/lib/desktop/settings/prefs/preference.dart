/// A single, typed desktop preference.
///
/// Generalizes the keymap "diff-only" storage pattern: each entry declares a
/// stable [id], a code-defined [defaultValue], and a JSON [encode]/[decode]
/// codec. The [PreferencesController] persists only entries whose value differs
/// from [defaultValue], so "modified from default" and "reset" fall out for
/// free.
///
/// Pure Dart — no Flutter or storage dependencies — so entries are trivial to
/// unit test and to declare `const`.
class PreferenceEntry<T> {
  /// Creates a preference entry. [encode] turns a value into a JSON-encodable
  /// object; [decode] returns the value for a stored object, or `null` when the
  /// stored object is missing/corrupt (the controller then falls back to
  /// [defaultValue]).
  const PreferenceEntry({
    required this.id,
    required this.defaultValue,
    required this.encode,
    required this.decode,
  });

  /// Stable identifier used as the key inside the persisted overrides map.
  final String id;

  /// The code-defined default. Setting a value equal to this removes the
  /// override so future default changes reach existing users.
  final T defaultValue;

  /// Serializes [value] to a JSON-encodable object.
  final Object? Function(T value) encode;

  /// Deserializes a stored [json] object, or returns `null` when it cannot be
  /// interpreted (corrupt / wrong type).
  final T? Function(Object? json) decode;
}
