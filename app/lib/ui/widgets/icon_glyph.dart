import 'package:flutter/widgets.dart';

/// A tintable glyph — either a font [IconData] or a monochrome PNG asset — that
/// renders like an [Icon], with the same `size` and `color` semantics. Asset
/// glyphs are drawn via [ImageIcon], which tints an alpha PNG with `color`
/// (BlendMode.srcIn), so a black-on-transparent export recolours cleanly.
///
/// Used for the composer's PR actions/situations: most are font icons, but
/// Push/Pull are PNGs exported from the codicon `repo-push`/`repo-pull` SVGs.
class IconGlyph {
  const IconGlyph.font(IconData icon) : _icon = icon, _asset = null;
  const IconGlyph.asset(String asset) : _asset = asset, _icon = null;

  final IconData? _icon;
  final String? _asset;

  Widget build({double? size, Color? color}) {
    final asset = _asset;
    if (asset != null) {
      return ImageIcon(AssetImage(asset), size: size, color: color);
    }
    return Icon(_icon, size: size, color: color);
  }
}
