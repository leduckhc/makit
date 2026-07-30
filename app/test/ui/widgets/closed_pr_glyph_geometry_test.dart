// The closed-PR glyph family is *parametric*: every weight shares the node
// columns (x=72 / x=200) and ring centre radius (24) from Phosphor's 256 grid,
// and differs only in stroke width. These tests read the shipped SVGs straight
// out of the asset bundle so a hand-edit that breaks the family is caught here
// rather than by eye.
//
// Deliberately free of `testWidgets`: reading `rootBundle` needs the binding,
// and `testWidgets` initialises it as a side effect of being declared — which
// would silently mask a missing `ensureInitialized` below.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/widgets/pr_state_style.dart';

/// Weight → the stroke width Phosphor uses on its 256 grid for that weight.
const _outlineWeights = {'thin': 8, 'light': 12, 'regular': 16, 'bold': 24};

String _asset(String weight) =>
    'assets/icons/git-pull-request-closed-$weight.svg';

void main() {
  // `rootBundle` reaches through ServicesBinding, so the binding must exist
  // before the first asset read.
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final MapEntry(key: weight, value: stroke) in _outlineWeights.entries) {
    test('the $weight variant keeps the shared grid at $stroke/256', () async {
      final svg = await rootBundle.loadString(_asset(weight));

      expect(
        svg,
        contains('stroke-width="$stroke"'),
        reason: "$weight must use Phosphor's $stroke/256 stroke",
      );
      expect(svg, contains('viewBox="0 0 256 256"'));
      expect(svg, contains('<circle cx="72" cy="64" r="24"/>'));
      expect(svg, contains('<circle cx="72" cy="192" r="24"/>'));
      expect(svg, contains('<circle cx="200" cy="192" r="24"/>'));
      // The ✕ replacing Phosphor's merge arrowhead is weight-independent.
      expect(svg, contains('M176 40l48 48m0-48l-48 48'));
    });
  }

  test('the fill variant uses solid nodes on the same columns', () async {
    final svg = await rootBundle.loadString(_asset('fill'));

    expect(svg, contains('<circle cx="72" cy="64" r="16"/>'));
    expect(svg, contains('<circle cx="200" cy="192" r="16"/>'));
    expect(svg, contains('M176 40l48 48m0-48l-48 48'));
  });

  test('prStateStyle points at the Light variant', () {
    // Every glyph the app renders is PhosphorIconsLight, so the closed marker
    // has to be the Light weight or it reads heavier than its neighbours.
    expect(kClosedPrAsset, _asset('light'));
  });
}
