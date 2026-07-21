import 'package:flutter/widgets.dart';

/// Selected glyphs from the VS Code codicon font (`assets/fonts/codicon.ttf`,
/// declared as font family `codicon` in pubspec.yaml). Codepoints are stable
/// across codicon releases — see the upstream `dist/codicon.csv` mapping.
abstract final class Codicons {
  static const String _family = 'codicon';

  /// `comment-discussion` — stacked speech bubbles, for review threads.
  static const IconData commentDiscussion = IconData(
    0xeac7,
    fontFamily: _family,
  );
}
