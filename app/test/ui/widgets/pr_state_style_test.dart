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

PullRequest _pr(String state) =>
    PullRequest(number: 1, url: '', state: state, title: 't', isDraft: false);

PullRequest _openPr({bool isDraft = false, String rollup = 'none'}) =>
    PullRequest(
      number: 1,
      url: '',
      state: 'OPEN',
      title: 't',
      isDraft: isDraft,
      checkRollup: rollup,
    );

void main() {
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

  // prPillColors — the decision the three PR pills (desktop composer, mobile
  // session chip, home worktree row) each used to make for themselves. One of
  // them made it differently, so an open failing PR read red on two surfaces and
  // brand-blue on the third.
  group('prPillColors', () {
    test('an open PR is tinted by its CI verdict, not its state', () {
      expect(prPillColors(cs, _openPr(rollup: 'fail')).icon, isNot(cs.primary));
      expect(
        prPillColors(cs, _openPr(rollup: 'fail')).icon,
        prRollupColor(cs, 'fail'),
      );
      expect(
        prPillColors(cs, _openPr(rollup: 'pass')).icon,
        prRollupColor(cs, 'pass'),
      );
      expect(
        prPillColors(cs, _openPr(rollup: 'pending')).icon,
        prRollupColor(cs, 'pending'),
      );
    });

    test('an open PR with no checks falls back to the muted outline', () {
      // `prRollupColor` maps an unknown/absent rollup to cs.outline; the pill
      // must not paint a verdict it does not have.
      expect(prPillColors(cs, _openPr()).icon, cs.outline);
    });

    test('a draft is grey whatever CI says — it is not up for review yet', () {
      final colors = prPillColors(cs, _openPr(isDraft: true, rollup: 'fail'));
      expect(colors.icon, cs.outline);
      expect(colors.label, cs.outline);
    });

    test('a merged PR reads by state, so stale checks cannot look live', () {
      final colors = prPillColors(cs, _pr('MERGED'));
      expect(colors.icon, kPrMerged);
      // Labels need AA (4.5:1), which the vivid hue misses as small text.
      expect(colors.label, cs.prMergedText);
    });

    test('a closed PR reads by state', () {
      expect(prPillColors(cs, _pr('CLOSED')).icon, cs.error);
    });

    test('state beats draft once the PR is no longer open', () {
      // The draft-grey rule is an *open*-PR rule: a closed draft is closed, and
      // reads like it. Worth pinning because the home row used to test `isDraft`
      // first and so painted a closed draft grey, unlike the other two pills.
      const closedDraft = PullRequest(
        number: 1,
        url: '',
        state: 'CLOSED',
        title: 't',
        isDraft: true,
      );
      expect(prPillColors(cs, closedDraft).icon, cs.error);
      expect(prPillColors(cs, closedDraft).icon, isNot(cs.outline));
    });

    test('an open PR uses one colour for glyph and label', () {
      final colors = prPillColors(cs, _openPr(rollup: 'fail'));
      expect(colors.label, colors.icon);
    });
  });
}
