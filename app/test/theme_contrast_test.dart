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

  // `primary` is the brand green and is used as small *label* text ("New
  // session", "New worktree", links) as well as for dots and icons, so it has
  // to clear AA as a foreground — not just the 3:1 UI-component floor.
  test('primary meets WCAG AA (4.5:1) as a label on its own surface', () {
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      expect(
        _contrast(cs.primary, cs.surface),
        greaterThanOrEqualTo(4.5),
        reason:
            'primary on the ${theme.brightness.name} surface must clear WCAG AA',
      );
    }
  });

  test('content on a primary fill meets WCAG AA (4.5:1)', () {
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      expect(
        _contrast(cs.onPrimary, cs.primary),
        greaterThanOrEqualTo(4.5),
        reason:
            'onPrimary on primary (${theme.brightness.name}) must clear WCAG AA',
      );
    }
  });

  // Dark mode shows the logo green itself. `fromSeed` maps the seed to a pale
  // sage (#98d4a3) that reads washed out against the neutral ramp, and there is
  // nothing to buy by desaturating it — the brand green already clears AA on
  // #171717. Pinned here so a future palette change can't quietly undo it.
  test('dark primary is the brand green', () {
    expect(makitDarkTheme.colorScheme.primary, kMakitAccent);
  });

  // Light mode cannot: the brand green is ~1.7:1 on #FAFAFA. It keeps the
  // seed-derived dark green, which is why `primary` is resolved per mode rather
  // than pinned to one constant everywhere.
  test('light primary is NOT the brand green, which would fail AA there', () {
    expect(makitLightTheme.colorScheme.primary, isNot(kMakitAccent));
    expect(
      _contrast(kMakitAccent, makitLightTheme.colorScheme.surface),
      lessThan(4.5),
      reason: 'documents why light mode may not use the brand green directly',
    );
  });
}
