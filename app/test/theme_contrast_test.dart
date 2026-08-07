// WCAG contrast guard for the semantic/diff *label* colors. The vivid tokens
// (kDiffAdd/kStatus*) fail AA as small text on the light surface, so consumers
// use the brightness-resolved `ColorScheme` text variants — this test pins that
// those variants clear AA (4.5:1) on their own theme surface.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/ui/widgets/pr_signals.dart';
import 'package:makit/ui/widgets/pr_tone.dart';

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

  // Chips tint their own background with the very colour they print on it, which
  // pulls the background toward the text and lowers real contrast below what a
  // check against the bare surface suggests. Light lands at ~4.8:1 — passing, but
  // with little room, so it is pinned rather than assumed.
  test('a primary-tinted chip still clears AA for its own label', () {
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      // Matches PrPill / the repo card's open-PR pill: primary @14% over the card.
      final chipBg = Color.alphaBlend(
        cs.primary.withValues(alpha: 0.14),
        cs.surfaceContainerLow,
      );
      expect(
        _contrast(cs.primary, chipBg),
        greaterThanOrEqualTo(4.5),
        reason:
            'the ${theme.brightness.name} PR pill label sits on its own tint',
      );
    }
  });

  // SPEC-38's tone-coloured surfaces. `prToneColor` returns dot/wash tokens —
  // `kCheckFail` prints at 3.2:1 and `kCheckPending` at 2.4:1 on the light
  // surface — so text uses `prToneTextColor`, the same split `prStateStyle`
  // already makes between `color` and `textColor`.
  test('a tone label clears AA on the surface it is printed on', () {
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      for (final tone in PrTone.values) {
        expect(
          _contrast(prToneTextColor(cs, tone), cs.surface),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness.name} ${tone.name} label',
        );
      }
    }
  });

  test('a solid tone fill clears AA for the label printed on it', () {
    // The *direct* CTA is a full-strength tone fill. The scheme's own pairing is
    // not good enough here — `cs.onError` on `kCheckFail` is 3.35:1 — so
    // `onPrToneFill` measures instead of assuming.
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      for (final tone in PrTone.values) {
        expect(
          _contrast(onPrToneFill(cs, tone), prToneColor(cs, tone)),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness.name} ${tone.name} filled CTA label',
        );
      }
    }
  });

  test('a destructive CTA fill clears AA for its own label', () {
    // The muted error tint replaces the CI red on the one irreversible button
    // (SPEC-38 §8 D13), so its pairing has to be measured too.
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      final fill = prDirectCtaFill(cs, PrTone.blocking, destructive: true);
      expect(
        _contrast(fill.fg, fill.bg),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness.name} destructive CTA label',
      );
    }
  });

  // A tinted chip is the one surface that does NOT reach 4.5:1, and cannot with
  // the current tokens: the tint pulls `surfaceContainerHigh` towards the label,
  // and even at 4% alpha the worst pair sits at 3.85. Reaching AA needs a darker
  // text token per tone per theme — a palette decision, not a code fix, so this
  // pins the floor it does hold (3:1, AA for non-text and large text) to stop it
  // drifting further while that is decided.
  test('a tone-tinted chip label holds at least 3:1', () {
    for (final theme in [makitLightTheme, makitDarkTheme]) {
      final cs = theme.colorScheme;
      for (final tone in PrTone.values) {
        for (final alpha in [0.14, 0.18, 0.20]) {
          final bg = Color.alphaBlend(
            prToneColor(cs, tone).withValues(alpha: alpha),
            cs.surfaceContainerHigh,
          );
          expect(
            _contrast(prToneTextColor(cs, tone), bg),
            greaterThanOrEqualTo(3.0),
            reason:
                '${theme.brightness.name} ${tone.name} label on its own '
                '${(alpha * 100).round()}% tint',
          );
        }
      }
    }
  });

  // `kStatusWarning` is a dot/wash token: ~2:1 as small text on the light
  // surface. Anything printing it as a label must use the AA-safe variant, which
  // is why ServerRow colours its dot and its label separately.
  test('the vivid warning token is not AA-safe as text, its variant is', () {
    final cs = makitLightTheme.colorScheme;
    expect(_contrast(kStatusWarning, cs.surface), lessThan(4.5));
    expect(
      _contrast(cs.statusWarningText, cs.surface),
      greaterThanOrEqualTo(4.5),
    );
  });
}
