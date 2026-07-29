import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A tintable glyph — a font [IconData], a monochrome PNG, or an SVG asset —
/// that renders like an [Icon], with the same `size` and `color` semantics.
/// PNG glyphs are drawn via [ImageIcon], which tints an alpha PNG with `color`
/// (BlendMode.srcIn), so a black-on-transparent export recolours cleanly; SVG
/// glyphs go through [SvgPicture] with the same source-in tint.
///
/// Used for the composer's PR actions/situations (most are font icons, but
/// Push/Pull are PNGs exported from the codicon `repo-push`/`repo-pull` SVGs)
/// and for PR-state glyphs (see `prStateStyle`, whose closed-PR mark is an SVG
/// Phosphor doesn't ship).
@immutable
class IconGlyph {
  const IconGlyph.font(IconData icon)
    : _icon = icon,
      _asset = null,
      _isSvg = false;
  const IconGlyph.asset(String asset)
    : _asset = asset,
      _icon = null,
      _isSvg = false;
  const IconGlyph.svg(String asset)
    : _asset = asset,
      _icon = null,
      _isSvg = true;

  final IconData? _icon;
  final String? _asset;
  final bool _isSvg;

  Widget build({double? size, Color? color}) {
    final asset = _asset;
    if (asset == null) return Icon(_icon, size: size, color: color);
    if (!_isSvg) {
      return ImageIcon(AssetImage(asset), size: size, color: color);
    }
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IconGlyph &&
      other._icon == _icon &&
      other._asset == _asset &&
      other._isSvg == _isSvg;

  @override
  int get hashCode => Object.hash(_icon, _asset, _isSvg);
}
