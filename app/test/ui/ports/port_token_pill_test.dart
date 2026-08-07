// The tinted port token pill (mockup `open-ports.html` 111–118). The pill is
// the ONE place a port's severity turns into colour, so these tests pin the two
// properties that make it trustworthy: the tone drives the paint, and colour is
// never the only carrier of the verdict.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/ui/ports/port_token_pill.dart';
import 'package:makit/ui/ports/ports_vocabulary.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String label,
    required PortTone tone,
    bool dot = true,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: Center(
          child: PortTokenPill(
            label: label,
            sentence: 'the explanation for $label',
            tone: tone,
            showDot: dot,
          ),
        ),
      ),
    ),
  );

  Color? fillOf(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(PortTokenPill),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return (box.decoration as BoxDecoration).color;
  }

  Color? textColorOf(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style?.color;

  group('tone drives the paint', () {
    testWidgets('ok, warn and err each get a distinct fill and foreground', (
      tester,
    ) async {
      final fills = <PortTone, Color?>{};
      final fgs = <PortTone, Color?>{};
      for (final tone in [PortTone.ok, PortTone.warn, PortTone.err]) {
        await pump(tester, label: 'x', tone: tone);
        fills[tone] = fillOf(tester);
        fgs[tone] = textColorOf(tester, 'x');
      }
      // Three verdicts that mean three different things must not paint alike —
      // this is the bug the popover shipped with: 200 and 404 rendered
      // identically, so health was encoded in text only.
      expect(fills.values.toSet().length, 3, reason: 'fills collide: $fills');
      expect(fgs.values.toSet().length, 3, reason: 'foregrounds collide: $fgs');
    });

    testWidgets('an idle token is neutral, not a verdict colour', (
      tester,
    ) async {
      await pump(tester, label: 'not probed', tone: PortTone.idle);
      final cs = makitDarkTheme.colorScheme;
      expect(textColorOf(tester, 'not probed'), cs.onSurfaceVariant);
      expect(fillOf(tester), cs.surfaceContainerHigh);
    });

    testWidgets('the fill is a wash, never the opaque foreground hue', (
      tester,
    ) async {
      // A fully opaque green pill would swamp the row; the mockup washes it to
      // 14% so the surface still reads through.
      await pump(tester, label: '200', tone: PortTone.ok);
      expect(fillOf(tester)!.a, lessThan(0.3));
    });
  });

  group('colour is never the only signal', () {
    testWidgets('the label text survives every tone', (tester) async {
      for (final tone in PortTone.values) {
        await pump(tester, label: 'exposed', tone: tone);
        expect(find.text('exposed'), findsOneWidget);
      }
    });

    testWidgets('a token speaks its sentence exactly once, not twice', (
      tester,
    ) async {
      // Guards the same regression as the sheet test: Tooltip's own semantics
      // plus the explicit Semantics(label:) would read the sentence twice.
      final handle = tester.ensureSemantics();
      await pump(tester, label: 'loopback', tone: PortTone.idle);
      final spoken = tester.getSemantics(find.byType(PortTokenPill)).label;
      expect(
        RegExp(
          RegExp.escape('the explanation for loopback'),
        ).allMatches(spoken).length,
        1,
        reason: 'the sentence is spoken twice: $spoken',
      );
      handle.dispose();
    });

    testWidgets('the status dot is decorative — it adds no spoken text', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, label: '200', tone: PortTone.ok, dot: true);
      final withDot = tester.getSemantics(find.byType(PortTokenPill)).label;
      await pump(tester, label: '200', tone: PortTone.ok, dot: false);
      final withoutDot = tester.getSemantics(find.byType(PortTokenPill)).label;
      expect(withDot, withoutDot);
      handle.dispose();
    });

    testWidgets('an idle token draws no dot even when asked for one', (
      tester,
    ) async {
      // "not probed" is the absence of a reading; a pulse there would claim a
      // live check happened.
      Finder dots() => find.descendant(
        of: find.byType(PortTokenPill),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      );

      await pump(tester, label: '200', tone: PortTone.ok, dot: true);
      expect(dots(), findsOneWidget);

      await pump(tester, label: 'not probed', tone: PortTone.idle, dot: true);
      expect(dots(), findsNothing);
    });
  });
}
