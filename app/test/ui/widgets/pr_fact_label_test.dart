// The chip-sized `#142 · loud fact` fragment, shared by the home-row chip and the
// session subtitle chip.
//
// Written twice before this, the two had drifted the same way: both painted the
// whole string in the fact's tone and bolded all of it, so a merged worktree's
// number read purple and a failing one's red — while the desktop bar, from the
// same derivation, kept the number in the surface ink. The identity is not part of
// the verdict, so these pin which span carries what.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/widgets/pr_signals.dart';
import 'package:makit/ui/widgets/pr_tone.dart';

PrStatus _failing() => prStatus(
  pr: const PullRequest(
    number: 142,
    url: 'u',
    state: 'OPEN',
    title: 't',
    isDraft: false,
    checkRollup: 'fail',
    checks: [PrCheck(name: 'a', bucket: 'fail')],
  ),
  branch: 'feat/x',
);

Future<List<TextSpan>> _spans(WidgetTester tester, PrStatus status) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: Center(child: PrFactLabel(status: status)),
      ),
    ),
  );
  final text = tester.widget<Text>(find.byType(Text));
  return (text.textSpan! as TextSpan).children!.cast<TextSpan>();
}

void main() {
  testWidgets('the identity keeps the surface ink and the weight', (
    tester,
  ) async {
    final status = _failing();
    final spans = await _spans(tester, status);
    final cs = makitDarkTheme.colorScheme;

    expect(spans.first.text, '#142');
    expect(spans.first.style?.color, cs.onSurface);
    expect(spans.first.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('only the fact carries the tone, at the base weight', (
    tester,
  ) async {
    final status = _failing();
    final spans = await _spans(tester, status);
    final cs = makitDarkTheme.colorScheme;

    expect(spans.last.text, status.loud.label);
    expect(
      spans.last.style?.fontWeight,
      isNull,
      reason: 'inherits the base weight, so the number stands out',
    );
    // The tone rides the parent style, which is what the fact inherits.
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.style?.color, prToneTextColor(cs, status.tone));
  });

  testWidgets('the separator is quiet but present', (tester) async {
    final spans = await _spans(tester, _failing());
    expect(spans[1].text, ' · ');
    // Not `outlineVariant`: at 1.07:1 on the row it was not on screen at all.
    expect(
      spans[1].style?.color,
      makitDarkTheme.colorScheme.outline.withValues(alpha: 0.55),
    );
  });

  testWidgets('a branch with no PR shows the fact alone', (tester) async {
    // Nothing to separate: the row already carries the branch name.
    final spans = await _spans(
      tester,
      prStatus(pr: null, branch: 'feat/x', uncommittedFiles: 3),
    );
    expect(spans, hasLength(1));
    expect(spans.single.text, '3 files uncommitted');
  });
}
