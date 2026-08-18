import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A repository's stand-in mark: its initial on a hue derived from its name.
///
/// Deterministic, so the same repo shows the same colour on every device with no
/// state to sync and nothing to configure — which is the point. A custom image is
/// a byte-transfer path with size and type validation, not a settings row, so it
/// is deliberately not offered here (SPEC-per-repo-settings D14).
///
/// Shared with the repo list rather than reimplemented there: two independently
/// drawn marks for the same repo drift in colour and letter, and the Settings
/// sidebar plus the repo-centric home are exactly two such places (SPEC-per-repo-settings D15).
class RepoMonogram extends StatelessWidget {
  const RepoMonogram({required this.name, this.size = 22, this.hue, super.key});

  /// The repository name. Only its first character is drawn.
  final String name;

  /// Edge length of the (square, rounded) mark.
  final double size;

  /// Explicit palette index, when the user has chosen one. Null derives it from
  /// the name — which is the default precisely because two repos sharing a hue is
  /// the only reason to choose.
  final int? hue;

  /// Hue for [name], stable across runs and devices.
  ///
  /// A plain character-sum rather than a cryptographic hash: the requirement is
  /// determinism and spread across a small palette, not collision resistance. Two
  /// repos sharing a hue is a cosmetic coincidence, and pretending otherwise
  /// would mean testing a hash for a property that does not matter.
  static Color hueFor(String name) {
    if (name.isEmpty) return _palette.first;
    var sum = 0;
    for (final unit in name.codeUnits) {
      sum = (sum + unit) % 0xFFFF;
    }
    return _palette[sum % _palette.length];
  }

  /// The glyph drawn for [name] — its first character, or `?` when there is none.
  ///
  /// Uses `characters`-free logic deliberately kept simple: a name beginning with
  /// an emoji or a combining mark renders that first UTF-16 unit, which may be a
  /// replacement glyph but never throws and never renders empty.
  static String glyphFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final first = trimmed.substring(0, 1);
    // Upper-case a multi-word name's initial ("Diana"), leave a lone lowercase
    // project name as it is ("makit") — matching how the names actually read.
    return trimmed.contains(RegExp(r'[A-Z]')) ? first.toUpperCase() : first;
  }

  /// Palette entry [i], wrapped so a picker can show the choices without the
  /// palette becoming public mutable state.
  static Color paletteAt(int i) => _palette[i % _palette.length];

  /// How many hues a picker may offer.
  static int get paletteLength => _palette.length;

  static const List<Color> _palette = [
    Color(0xFF4ADE80),
    Color(0xFFA371F7),
    Color(0xFFE0A72E),
    Color(0xFF38BDF8),
    Color(0xFFE07B39),
    Color(0xFFF472B6),
  ];

  @override
  Widget build(BuildContext context) {
    final tint = hue == null ? hueFor(name) : paletteAt(hue!);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(kRadius6),
      ),
      child: Text(
        glyphFor(name),
        style: TextStyle(
          // Dark ink on a saturated tile: the palette is light enough that white
          // text on it fails contrast, which the mockup's dark-on-green shows.
          color: const Color(0xFF0E0E0E),
          fontSize: size * 0.5,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}
