/// The five rules of the expanded tool body
/// (`mockups/tool-expanded-body.html` §5). Each one existed as a defect first:
/// a heading in a code face, a box inside a box, a fact rendered as source
/// code, a 72 px key gutter, and a panel painted in the highlighter's own
/// blue-grey instead of the app's ramp.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/tool_call_card.dart';
import 'package:makit/ui/session/diff_view.dart' show DiffLineRow;
import 'package:makit/ui/session/tool_renderers.dart';
import 'package:makit/ui/session/tool_result_text.dart' show kToolFactMaxChars;

ToolCallItem _item(
  String name,
  Map<String, dynamic> args, {
  String? output,
  int exitCode = 0,
}) => ToolCallItem(
  seq: 1,
  ts: 0,
  callId: 'c1',
  name: name,
  args: args,
  output: output,
  ended: true,
  exitCode: exitCode,
);

/// Pump a renderer's inline body the way the expanded row does.
Future<void> _pumpBody(WidgetTester tester, ToolCallItem item) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: Builder(
          builder: (ctx) =>
              ListView(children: rendererFor(item)!.body(ctx, item)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The resolved style behind a piece of text. `find.text` on a [SelectableText]
/// matches its inner [EditableText], not the [SelectableText] itself.
TextStyle? _styleOf(WidgetTester tester, String label) {
  final widget = tester.widgetList(find.text(label)).first;
  return switch (widget) {
    Text(:final style) => style,
    EditableText(:final style) => style,
    _ => null,
  };
}

/// The frames the body draws — one per payload, by construction.
List<ToolPanel> _panels(WidgetTester tester) =>
    tester.widgetList<ToolPanel>(find.byType(ToolPanel)).toList();

void main() {
  group('rule 1 — a caption, not a heading', () {
    testWidgets('captions are labelSmall, uppercase, onSurfaceVariant', (
      tester,
    ) async {
      await _pumpBody(
        tester,
        _item('bash', {'command': 'echo hi'}, output: 'one\ntwo'),
      );
      final caption = tester.widget<Text>(find.text('COMMAND'));
      final theme = makitDarkTheme;
      expect(caption.style?.fontSize, theme.textTheme.labelSmall?.fontSize);
      expect(caption.style?.color, theme.colorScheme.onSurfaceVariant);
      // Never the old titleSmall.mono heading.
      expect(caption.style?.fontWeight, isNot(FontWeight.w600));
      expect(caption.style?.fontFamily, isNot(kMonoFontFamily));
    });

    testWidgets('a single-payload body has no caption at all', (tester) async {
      await _pumpBody(
        tester,
        _item('read', {
          'path': 'lib/main.dart',
        }, output: 'line one\nline two\nline three'),
      );
      expect(find.byType(ToolCaption), findsNothing);
      // …and certainly not the old section titles.
      expect(find.text('Arguments'), findsNothing);
      expect(find.text('Content'), findsNothing);
    });
  });

  group('rule 2 — one frame per payload', () {
    testWidgets('a read body draws exactly one panel', (tester) async {
      await _pumpBody(
        tester,
        _item('read', {'path': 'lib/main.dart'}, output: 'a\nb\nc'),
      );
      expect(_panels(tester).length, 1);
    });

    // A diff is a payload like any other. It used to borrow its frame from
    // ToolSection's container; with that gone it rendered as full-bleed tinted
    // bands while every neighbour had a rounded hairline panel.
    testWidgets('a diff payload is framed exactly like a code payload', (
      tester,
    ) async {
      await _pumpBody(
        tester,
        _item('edit', {
          'path': 'lib/a.dart',
          'oldText': 'final x = 1;',
          'newText': 'final x = 2;',
        }),
      );
      expect(_panels(tester).length, 1);
      expect(find.byType(DiffLineRow), findsWidgets);
    });

    testWidgets('an agent-supplied diff is framed too', (tester) async {
      await _pumpBody(
        tester,
        _item('apply_patch', {
          'changes': [
            {'path': 'a.dart', 'kind': 'update', 'diff': '@@ -1 +1 @@\n-a\n+b'},
          ],
        }),
      );
      expect(_panels(tester).length, 1);
    });

    testWidgets('a bash body draws one panel per payload, not four', (
      tester,
    ) async {
      await _pumpBody(
        tester,
        _item('bash', {'command': 'echo hi'}, output: 'one\ntwo'),
      );
      expect(_panels(tester).length, 2);
    });
  });

  group('rule 3 — facts are text, payloads are blocks', () {
    testWidgets('a short result renders as a fact, never a code block', (
      tester,
    ) async {
      await _pumpBody(
        tester,
        _item('read', {'path': 'lib/main.dart'}, output: '307 lines'),
      );
      expect(find.byType(ToolCodeBlock), findsNothing);
      expect(find.byType(ToolFacts), findsOneWidget);
      expect(find.text('307 lines'), findsOneWidget);
    });

    testWidgets('a multi-line result renders as a payload', (tester) async {
      await _pumpBody(
        tester,
        _item('read', {'path': 'lib/main.dart'}, output: 'a\nb'),
      );
      expect(find.byType(ToolCodeBlock), findsOneWidget);
    });

    testWidgets('grep puts its arguments in the facts strip', (tester) async {
      await _pumpBody(
        tester,
        _item('grep', {
          'pattern': 'TODO',
          'glob': '*.dart',
        }, output: 'lib/a.dart:1: TODO\nlib/b.dart:2: TODO'),
      );
      expect(find.byType(ToolFacts), findsOneWidget);
      expect(find.text('TODO'), findsOneWidget);
      expect(find.text('*.dart'), findsOneWidget);
    });
  });

  // The board promised "failure keeps its one splash of colour". That held for a
  // multi-line error (an error-tinted payload) but not for a SHORT one, which
  // becomes a fact — and facts had no tone. Seen in the real app: a failing
  // `sed` row whose body was entirely grey.
  group('a failure is coloured wherever it lands', () {
    testWidgets('a short error renders as an error-toned fact', (tester) async {
      await _pumpBody(
        tester,
        _item(
          'bash',
          {'command': 'sed -i q x'},
          output: 'sed: 1: invalid command code R',
          exitCode: 1,
        ),
      );
      final cs = makitDarkTheme.colorScheme;
      expect(
        find.byType(ToolCodeBlock),
        findsOneWidget,
        reason: 'command only',
      );
      for (final label in ['error', 'sed: 1: invalid command code R']) {
        expect(_styleOf(tester, label)?.color, cs.error, reason: label);
      }
    });

    testWidgets('a successful result keeps the quiet tone', (tester) async {
      await _pumpBody(tester, _item('bash', {'command': 'true'}, output: 'ok'));
      final cs = makitDarkTheme.colorScheme;
      expect(_styleOf(tester, 'ok')?.color, cs.onSurfaceVariant);
    });
  });

  group('rule 4 — no fixed key gutter', () {
    // Font-agnostic: widget tests render Ahem, where every glyph is one em, so
    // absolute widths mean nothing. What matters is that a value starts right
    // after ITS OWN key — the old ParamRow started every value at x + 72.
    testWidgets('a value starts right after its own key, not at a fixed x', (
      tester,
    ) async {
      await _pumpBody(
        tester,
        _item('grep', {'pattern': 'TODO', 'glob': '*.dart'}, output: 'a\nb'),
      );
      double gapAfter(String key, String value) =>
          tester.getTopLeft(find.text(value)).dx -
          (tester.getTopLeft(find.text(key)).dx +
              tester.getSize(find.text(key)).width);

      expect(gapAfter('pattern', 'TODO'), moreOrLessEquals(4, epsilon: 0.5));
      expect(gapAfter('glob', '*.dart'), moreOrLessEquals(4, epsilon: 0.5));
      // And the two pairs do not share a column start.
      expect(
        tester.getTopLeft(find.text('TODO')).dx,
        isNot(moreOrLessEquals(tester.getTopLeft(find.text('*.dart')).dx)),
      );
    });
  });

  group('rule 5 — the payload sits in the app ramp', () {
    testWidgets('a payload panel uses surfaceContainerLowest', (tester) async {
      await _pumpBody(
        tester,
        _item('bash', {'command': 'echo hi'}, output: 'one\ntwo'),
      );
      final cs = makitDarkTheme.colorScheme;
      for (final panel in _panels(tester)) {
        final box = tester.widget<Container>(
          find
              .descendant(
                of: find.byWidget(panel),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (box.decoration as BoxDecoration).color,
          cs.surfaceContainerLowest,
        );
      }
    });

    // Found on the real app: the container above was already correct and the
    // block still rendered atom-one-dark's #282C34, because HighlightView paints
    // `theme['root'].backgroundColor` INSIDE it. Colouring the container is not
    // enough — the highlight theme's own panel has to be stripped.
    testWidgets('the highlight theme contributes no background of its own', (
      tester,
    ) async {
      for (final theme in [makitDarkTheme, makitLightTheme]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(body: ToolCodeBlock('final x = 1;')),
          ),
        );
        await tester.pumpAndSettle();
        final view = tester.widget<HighlightView>(find.byType(HighlightView));
        expect(
          view.theme['root']?.backgroundColor,
          anyOf(isNull, Colors.transparent),
          reason:
              '${theme.brightness.name}: the panel is the app\'s, not the '
              'highlighter\'s',
        );
      }
    });
  });

  group('the header keeps its subject while expanded', () {
    testWidgets('expanding does not shrink the row to the bare verb', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: makitDarkTheme,
            home: Scaffold(
              body: ToolCallCard(
                item: _item('read', {
                  'path': 'lib/main.dart',
                }, output: 'a\nb\nc'),
                expansionKey: 'k',
              ),
            ),
          ),
        ),
      );
      final line = find.text('Read lib/main.dart', findRichText: true);
      expect(line, findsOneWidget);
      await tester.tap(line);
      await tester.pumpAndSettle();
      // The subject stays — which is why the body needs no arguments section.
      expect(line, findsOneWidget);
      expect(find.text('Read', findRichText: true), findsNothing);
    });
  });

  // Found by running the harness: an 80-character fact (the isFactResult limit)
  // in a 430 pt pane overflowed its Row by 147 px — the value could not shrink.
  group('a fact never overflows its pane', () {
    // The reported case, verbatim: an expanded bash row in a 430 pt pane whose
    // one-line output is a 62-char fact. Exercised through the whole row (card +
    // body + scroll view), not just ToolFacts in isolation, because the widget
    // under test is only ever seen inside that stack.
    testWidgets('the reported row (bash, 62-char result, 430 pt) is clean', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430 * 2, 700 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: makitDarkTheme,
            home: Scaffold(
              body: ListView(
                children: [
                  ToolCallCard(
                    item: _item(
                      'bash',
                      {
                        'command':
                            'cd /Users/le/.worktrees/makit/feat-chat-content && '
                            'grep -rn "risk" server/src | head -20',
                      },
                      output:
                          'server/src/pi-sessions.ts:259:function classifyRisk',
                    ),
                    expansionKey: 'k',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Run grep, head', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('classifyRisk'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // The class of bug, not the instance: the longest fact `isFactResult` will
    // ever admit, through the whole row, at every pane width the app uses —
    // 320 pt (smallest phone), 430 (phone), 560 (split desktop pane), 760
    // (kReadableContentMaxWidth).
    for (final width in const [320.0, 430.0, 560.0, 760.0]) {
      testWidgets('a max-length fact is clean at ${width.toInt()} pt', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width * 2, 700 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: makitDarkTheme,
              home: Scaffold(
                body: ListView(
                  children: [
                    ToolCallCard(
                      item: _item('bash', {
                        'command': 'grep -rn x .',
                      }, output: 'y' * kToolFactMaxChars),
                      expansionKey: 'k',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Run grep', findRichText: true));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a maximum-length fact wraps instead of overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430 * 2, 400 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: makitDarkTheme,
          home: Scaffold(
            body: ListView(
              children: [
                ToolFacts([ToolFact('result', 'x' * kToolFactMaxChars)]),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // The copy affordance rode every block at full strength. On a pointer it is
  // hover-revealed like the row's disclosure caret; on touch there is no hover,
  // so it stays.
  group('the copy button is quiet until wanted', () {
    Future<void> pump(WidgetTester tester, TargetPlatform platform) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: makitDarkTheme.copyWith(platform: platform),
          home: const Scaffold(body: ToolCodeBlock('final x = 1;')),
        ),
      );
      await tester.pumpAndSettle();
    }

    double opacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byIcon(PhosphorIconsLight.copy),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    testWidgets('hidden until hover on a pointer platform', (tester) async {
      await pump(tester, TargetPlatform.macOS);
      expect(opacity(tester), 0);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(ToolCodeBlock)));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
    });

    testWidgets('always visible on touch', (tester) async {
      await pump(tester, TargetPlatform.iOS);
      expect(opacity(tester), 1);
    });
  });
}
