// The closed-PR glyph ships in the full Phosphor weight range (`assets/icons/`
// is bundled wholesale, so every file here reaches users). `prStateStyle` wires
// up Light; the rest exist so a future surface can match a heavier/lighter
// Phosphor set without redrawing the mark. These tests are the guard that each
// shipped variant still parses and tints — the grid/weight assertions live in
// closed_pr_glyph_geometry_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/widgets/icon_glyph.dart';

import '../../support/svg_asset_finder.dart';

String _asset(String weight) =>
    'assets/icons/git-pull-request-closed-$weight.svg';

void main() {
  for (final weight in ['thin', 'light', 'regular', 'bold', 'fill']) {
    testWidgets('the $weight variant parses and tints', (tester) async {
      final asset = _asset(weight);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: IconGlyph.svg(
              asset,
            ).build(size: 16, color: const Color(0xFFC7331F)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(findSvgAsset(asset), findsOneWidget);
    });
  }
}
