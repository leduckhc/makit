// Unit tests for the single source of truth behind every worktree/PR glyph:
// the desktop sidebar row, the composer status pill, the window title strip and
// the mobile worktree pill all resolve their icon + colour through
// [prStateStyle], so a merged or closed PR can never keep reading as a live one
// in one place but not another.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/widgets/icon_glyph.dart';
import 'package:makit/ui/widgets/pr_state_style.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/ui/widgets/pr_signals.dart';
import 'package:makit/ui/widgets/pr_tone.dart';

PullRequest _pr(String state) =>
    PullRequest(number: 1, url: '', state: state, title: 't', isDraft: false);

void main() {
  _toneHuesTests();
  final cs = ColorScheme.fromSeed(seedColor: kMakitAccent);

  test('no PR → plain branch icon, muted', () {
    final style = prStateStyle(cs, null);
    expect(style.glyph, const IconGlyph.font(PhosphorIconsLight.gitBranch));
    expect(style.color, cs.outline);
    expect(style.textColor, cs.outline);
  });

  test('open PR → pull-request icon, accent', () {
    final style = prStateStyle(cs, _pr('OPEN'));
    expect(
      style.glyph,
      const IconGlyph.font(PhosphorIconsLight.gitPullRequest),
    );
    expect(style.color, cs.primary);
    // M3's primary already clears AA as text: no separate label variant.
    expect(style.textColor, cs.primary);
  });

  test('merged PR → merge icon, merged purple', () {
    final style = prStateStyle(cs, _pr('MERGED'));
    expect(style.glyph, const IconGlyph.font(PhosphorIconsLight.gitMerge));
    expect(style.color, kPrMerged);
  });

  test('merged label uses the AA-safe purple, not the vivid icon hue', () {
    // The vivid #8957E5 only reaches 4.4:1 on the light surface — below AA for
    // small text — so labels get the darker/lighter per-mode variant while the
    // icon keeps the vivid hue (icons only need 3:1).
    final lightCs = ColorScheme.fromSeed(seedColor: kMakitAccent);
    final darkCs = ColorScheme.fromSeed(
      seedColor: kMakitAccent,
      brightness: Brightness.dark,
    );
    expect(
      prStateStyle(lightCs, _pr('MERGED')).textColor,
      lightCs.prMergedText,
    );
    expect(prStateStyle(darkCs, _pr('MERGED')).textColor, darkCs.prMergedText);
    expect(lightCs.prMergedText, isNot(darkCs.prMergedText));
    expect(lightCs.prMergedText, isNot(kPrMerged));
  });

  test('closed PR → dedicated closed-PR glyph, error red', () {
    final style = prStateStyle(cs, _pr('CLOSED'));
    expect(style.glyph, const IconGlyph.svg(kClosedPrAsset));
    expect(style.color, cs.error);
  });

  test('state matching is case-insensitive', () {
    expect(
      prStateStyle(cs, _pr('merged')).glyph,
      const IconGlyph.font(PhosphorIconsLight.gitMerge),
    );
    expect(
      prStateStyle(cs, _pr('open')).glyph,
      const IconGlyph.font(PhosphorIconsLight.gitPullRequest),
    );
  });

  test('unknown state falls back to the plain branch icon', () {
    final style = prStateStyle(cs, _pr('SOMETHING_NEW'));
    expect(style.glyph, const IconGlyph.font(PhosphorIconsLight.gitBranch));
    expect(style.color, cs.outline);
  });
}

// The next-step bar tints its facts by [PrTone]; the sheet tints each CI check by
// its bucket. Those are different vocabularies for the same underlying states, so
// they read from one set of hues — this pins that, because two files each holding
// `0xFFF85149` is precisely how the old pills drifted apart.
void _toneHuesTests() {
  const cs = ColorScheme.dark();

  group('tone hues are the check hues', () {
    test('blocking is the failing-check red', () {
      expect(prToneColor(cs, PrTone.blocking), prCheckBucketColor(cs, 'fail'));
    });

    test('attention is the pending-check amber', () {
      expect(
        prToneColor(cs, PrTone.attention),
        prCheckBucketColor(cs, 'pending'),
      );
    });

    test('landed is the AA-safe merged purple, not the vivid icon hue', () {
      // The tone tints text as well as the dot, so it must clear AA (4.5:1).
      expect(prToneColor(cs, PrTone.landed), cs.prMergedText);
      expect(prToneColor(cs, PrTone.landed), isNot(kPrMerged));
    });

    test('quiet recedes to the muted outline', () {
      expect(prToneColor(cs, PrTone.quiet), cs.outline);
    });

    test('the attention *label* keeps the amber on dark, darkens on light', () {
      // The dot and the sentence sit 6px apart, so a label in a second amber read
      // as a second verdict. Only the light theme needs the swap (kCheckPending is
      // 2.1:1 there); dark keeps the dot's own hue at 7.1:1.
      expect(
        prToneTextColor(makitDarkTheme.colorScheme, PrTone.attention),
        kCheckPending,
      );
      expect(
        prToneTextColor(makitLightTheme.colorScheme, PrTone.attention),
        makitLightTheme.colorScheme.statusCautionText,
      );
    });

    test('a destructive direct CTA is the error container, not the CI red', () {
      for (final theme in [makitLightTheme, makitDarkTheme]) {
        final scheme = theme.colorScheme;
        final fill = prDirectCtaFill(
          scheme,
          PrTone.blocking,
          destructive: true,
        );
        expect(fill.bg, scheme.errorContainer);
        expect(fill.bg, isNot(kCheckFail), reason: 'not the failing-build red');
        expect(fill.fg, scheme.onErrorContainer);
      }
      // Everything else still gets the full-strength tone.
      expect(
        prDirectCtaFill(cs, PrTone.landed, destructive: false).bg,
        prToneColor(cs, PrTone.landed),
      );
    });
  });

  // The dot legend (mockup §2). Same argument as the tones above: the dot sits
  // beside real CI colours, so it reads the same `kCheck*` tokens rather than
  // re-typing the literals.
  group('dot hues are the check hues', () {
    test('pass is the passing-check green', () {
      expect(
        prDotColor(cs, PrDot.pass, PrTone.quiet),
        prCheckBucketColor(cs, 'pass'),
      );
    });

    test('fail is the failing-check red', () {
      expect(
        prDotColor(cs, PrDot.fail, PrTone.quiet),
        prCheckBucketColor(cs, 'fail'),
      );
    });

    test('the arc is the pending-check amber', () {
      expect(
        prDotColor(cs, PrDot.pending, PrTone.quiet),
        prCheckBucketColor(cs, 'pending'),
      );
    });

    test('landed is the merged purple', () {
      expect(prDotColor(cs, PrDot.landed, PrTone.quiet), cs.prMergedText);
    });

    test('a ring and a muted dot are grey whatever the fact says', () {
      // The whole point of both: "nothing to report" and "not up for review".
      // Tinting either would report something.
      for (final tone in PrTone.values) {
        expect(prDotColor(cs, PrDot.none, tone), cs.outline);
        expect(prDotColor(cs, PrDot.muted, tone), cs.outline);
      }
    });

    test('PrDot.tone defers to the loud fact', () {
      for (final tone in PrTone.values) {
        expect(prDotColor(cs, PrDot.tone, tone), prToneColor(cs, tone));
      }
    });
  });
}
