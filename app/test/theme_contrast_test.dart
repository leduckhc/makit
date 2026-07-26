// WCAG contrast guard for the semantic/diff *label* colors. The vivid tokens
// (kDiffAdd/kStatus*) fail AA as small text on the light surface, so consumers
// use the brightness-resolved `ColorScheme` text variants — this test pins that
// those variants clear AA (4.5:1) on their own theme surface.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('semantic/diff label colors meet WCAG AA (4.5:1) on their surface', () {
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      final labels = {
        'diffAddText': cs.diffAddText,
        'diffDelText': cs.diffDelText,
        'statusWarningText': cs.statusWarningText,
        'statusCautionText': cs.statusCautionText,
      };
      labels.forEach((name, color) {
        expect(
          _contrast(color, cs.surface),
          greaterThanOrEqualTo(4.5),
          reason:
              '$name on ${theme.brightness.name} surface must clear WCAG AA',
        );
      });
    }
  });
}
