// A finder for a tinted SVG glyph by its asset path. [IconGlyph.svg] renders via
// `SvgPicture.asset`, which carries the path on its `SvgAssetLoader` — so tests
// can match the asset without production code holding a `Key` just to be found.
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Finder findSvgAsset(String assetName) => find.byWidgetPredicate((w) {
  if (w is! SvgPicture) return false;
  final loader = w.bytesLoader;
  return loader is SvgAssetLoader && loader.assetName == assetName;
}, description: 'SvgPicture("$assetName")');
