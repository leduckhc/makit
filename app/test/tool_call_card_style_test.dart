/// Pins the collapsed tool row's *appearance* — the things a human reviewer
/// will not re-check on every change, and that a refactor silently undoes.
///
/// The design rationale for every number here is in
/// `mockups/tool-one-liner.html` (§5 type, §6 density, §7 monochrome).
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/chat_metrics.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/tool_call_card.dart';

ToolCallItem _bash({
  String command = 'cd /repo && grep -rn x src | head -20',
  ToolRisk risk = ToolRisk.risky,
  int exitCode = 0,
}) => ToolCallItem(
  seq: 1,
  ts: 0,
  callId: 'c1',
  name: 'bash',
  args: {'command': command},
  risk: risk,
  ended: true,
  exitCode: exitCode,
  endedTs: 0,
);

Widget _app(ToolCallItem item) => ProviderScope(
  child: MaterialApp(
    theme: makitDarkTheme,
    home: Scaffold(
      body: ToolCallCard(item: item, expansionKey: 'k'),
    ),
  ),
);

/// The row's single rich line. Scoped under [Text] so the leading glyph — an
/// [Icon], which is itself a bare [RichText] — cannot be picked up instead.
RichText _line(WidgetTester tester) => tester.widget<RichText>(
  find.descendant(of: find.byType(Text), matching: find.byType(RichText)).first,
);

/// The leading glyph (first icon in the row).
Icon _glyph(WidgetTester tester) =>
    tester.widget<Icon>(find.byType(Icon).first);

void main() {
  testWidgets('the leading glyph is monochrome for a risky call', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_bash()));
    final cs = makitDarkTheme.colorScheme;
    expect(
      _glyph(tester).color,
      cs.onSurfaceVariant.withValues(alpha: kToolGlyphAlpha),
    );
    expect(_glyph(tester).size, kToolGlyph);
  });

  testWidgets('a destructive call keeps its tint', (tester) async {
    await tester.pumpWidget(_app(_bash(risk: ToolRisk.destructive)));
    expect(_glyph(tester).color, kToolDestructiveColor);
  });

  testWidgets('the line is sans, 13px, and full-opacity onSurfaceVariant', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_bash()));
    final style = _line(tester).text.style!;
    expect(style.fontFamily, kSansFontFamily);
    expect(style.fontSize, 13);
    expect(style.color, makitDarkTheme.colorScheme.onSurfaceVariant);
  });

  testWidgets('the verb is a weight heavier than its payload', (tester) async {
    await tester.pumpWidget(_app(_bash()));
    // Text.rich nests the given span under one carrying the base style, so
    // flatten to the leaves that actually paint glyphs.
    final leaves = <TextSpan>[];
    _line(tester).text.visitChildren((span) {
      if (span is TextSpan && span.text != null) leaves.add(span);
      return true;
    });
    expect(leaves.map((s) => s.text).join(), 'Run grep, head');
    expect(leaves.first.text, 'Run');
    expect(leaves.first.style?.fontWeight, kToolVerbWeight);
    // One step, not two: Semibold made the verb column read as headings.
    expect(kToolVerbWeight.value, FontWeight.w500.value);
    expect(leaves.last.text, 'grep, head');
    expect(leaves.last.style?.fontWeight, isNull);
  });

  testWidgets('a resolved tick is grey; a failure keeps the error hue', (
    tester,
  ) async {
    final cs = makitDarkTheme.colorScheme;
    await tester.pumpWidget(_app(_bash()));
    final ok = tester.widgetList<Icon>(find.byType(Icon)).toList()[1];
    expect(ok.color, cs.onSurfaceVariant.withValues(alpha: kToolGlyphAlpha));
    expect(ok.size, kToolStatusGlyph);

    await tester.pumpWidget(_app(_bash(exitCode: 1)));
    final failed = tester.widgetList<Icon>(find.byType(Icon)).toList()[1];
    expect(failed.color, cs.error);
  });

  testWidgets('the collapsed row is as tight as a thinking row', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_bash()));
    // 13px * 1.3 line + 2px padding either side. Anything ≥ 35 means the old
    // kSpace6 padding is back.
    expect(tester.getSize(find.byType(ToolCallCard)).height, lessThan(34));
  });

  testWidgets('a shell row carries the full command as a tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_bash()));
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'grep -rn x src | head -20',
    );
  });

  testWidgets('a non-shell row has no tooltip', (tester) async {
    await tester.pumpWidget(
      _app(
        ToolCallItem(
          seq: 1,
          ts: 0,
          callId: 'c2',
          name: 'read',
          args: const {'path': 'lib/main.dart'},
        ),
      ),
    );
    expect(find.byType(Tooltip), findsNothing);
  });

  // The brief's actual requirement: a tool row's glyph is the thinking row's
  // glyph. Pin it as one assertion so the two can never drift apart.
  testWidgets('the tool glyph and the thinking brain are the same glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: makitDarkTheme,
          home: Scaffold(
            body: Column(
              children: [
                ToolCallCard(item: _bash(), expansionKey: 'k'),
                const ThinkingLine(text: 'pondering', expansionKey: 't'),
              ],
            ),
          ),
        ),
      ),
    );
    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    final tool = icons.first;
    final brain = icons.firstWhere((i) => i.icon == PhosphorIconsLight.brain);
    expect(tool.size, brain.size);
    expect(tool.color, brain.color);
  });
}
