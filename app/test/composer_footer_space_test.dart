import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/composer_selectors.dart';
import 'package:makit/ui/composer/context_usage.dart';

/// SPEC-40 — the composer footer at real widths, for the session shapes our
/// adapters actually emit.
///
/// This is the permanent home of the spec's evidence table: before the fix, a
/// 375pt pi session showed `anthropic/Cl…` (65.5pt of label) and a four-option
/// session threw `RenderFlex overflowed by 18 pixels`, because every
/// `footerActions` entry got an equal-share `Flexible` and the 36pt usage ring
/// wasted half the row.
///
/// It is regression coverage, not the test that drove the fix: its fixtures pass
/// the ring via `footerTrailing`, which did not exist beforehand. The driving RED
/// is the granted-constraint probe in `composer_test.dart`. To confirm this file
/// is not vacuous, move `ring` back into `footerActions` and watch the overflow
/// and the ellipsis return.
void _noop(String _) {}

SessionConfigOption _select(
  String id,
  String category,
  String current,
  List<String> values, {
  String? name,
}) => SessionConfigOption(
  id: id,
  name: name ?? id,
  category: category,
  type: ConfigOptionType.select,
  currentValue: current,
  options: [
    for (final v in values) ConfigOptionValue(value: v, name: v),
  ],
);

/// The name `pi-acp` produces: `${provider}/${name}` (`getModelState`).
const _piModel = 'anthropic/Claude Opus 4.6';
const _codexModel = 'gpt-5.6-codex';

/// pi over `pi-acp`: a model select plus a model-scoped thinking select, which
/// folds into the model pill as a read-only chip.
final _piShape = [
  _select('model', 'model', _piModel, [_piModel, 'openai/GPT-5.6']),
  _select('thought_level', 'thought_level', 'high', ['off', 'high']),
];

/// codex `app-server`: the same, plus a `model_config` chip.
final _codexShape = [
  _select('model', 'model', _codexModel, [_codexModel]),
  _select('thought_level', 'thought_level', 'high', ['off', 'high']),
  _select('context', 'model_config', '256k', ['128k', '256k']),
];

/// An ACP agent advertising only modes — one synthesised standalone pill.
final _modesShape = [
  _select('mode', 'mode', 'architect', ['architect', 'code']),
];

/// Not emitted by any adapter we ship, but ACP passes agent-supplied options
/// through unchanged, so it must not overflow: this is the shape that threw.
final _manyShape = [
  ..._piShape,
  _select('sandbox', 'sandbox', 'workspace-write', [
    'read-only',
    'workspace-write',
  ]),
  _select('approval', 'approval', 'on-request', ['never', 'on-request']),
];

/// A session with usage seeded on purpose: [ContextUsageButton] renders
/// `SizedBox.shrink()` until both halves of the ratio are known, so an unseeded
/// fixture would measure a 0pt ring and pass every assertion about it vacuously.
ProviderContainer _container(List<SessionConfigOption> options) =>
    ProviderContainer(
      overrides: [
        sessionMetaProvider('s1').overrideWithValue(
          SessionMeta(thinking: '', models: const [], configOptions: options),
        ),
        sessionsProvider.overrideWithValue(
          SessionsState([
            Session(
              id: 's1',
              projectId: 'p1',
              agent: 'pi',
              title: 'T',
              status: SessionStatus.idle,
              policy: ApprovalPolicy.askOnRisky,
              lastPreview: '',
              lastActivityAt: 0,
            ),
          ]),
        ),
        sessionUsageProvider('s1').overrideWithValue(
          const SessionUsage(
            contextTokens: 288000,
            contextWindow: 1000000,
            measuredAt: 1,
          ),
        ),
      ],
    );

/// The rendered paragraph for [finder]'s text.
RenderParagraph _paragraph(WidgetTester tester, Finder finder) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    );

/// True when [finder]'s text was clipped with an ellipsis.
bool _ellipsized(WidgetTester tester, Finder finder) =>
    _paragraph(tester, finder).didExceedMaxLines;

/// The width [text] wants when nothing constrains it, in the pill's own style —
/// the baseline "natural width" the spec's criterion 5 compares against.
Future<double> _naturalWidth(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Builder(
            builder: (context) => Text(
              text,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.getSize(find.text(text)).width;
}

void main() {
  /// Pumps the footer at [width] and runs [body] against it.
  Future<void> pumpFooter(
    WidgetTester tester,
    double width,
    List<SessionConfigOption> options,
  ) async {
    final c = _container(options);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: const Composer(
                  onSend: _noop,
                  alwaysExpanded: true,
                  footerActions: [
                    ComposerConfigOptions(sessionId: 's1'),
                  ],
                  footerTrailing: ContextUsageButton(sessionId: 's1'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The shapes our adapters emit today. These carry the hard guarantee.
  final shipping = <String, List<SessionConfigOption>>{
    'pi (model + thinking)': _piShape,
    'codex (model + thinking + chip)': _codexShape,
    'ACP modes-only': _modesShape,
  };

  group('SPEC-40 — shipping shapes: no overflow, visible ring, 320…700pt', () {
    for (final width in [320.0, 375.0, 700.0]) {
      for (final entry in shipping.entries) {
        testWidgets('${width.toInt()}pt · ${entry.key}', (tester) async {
          tester.view.physicalSize = Size(width, 812);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await pumpFooter(tester, width, entry.value);

          // Criterion 1.
          expect(
            tester.takeException(),
            isNull,
            reason: 'the footer must not overflow at ${width.toInt()}pt',
          );

          // Criterion 4: the ring is present at its full tap target. Guards
          // against a fixture that silently renders no ring at all.
          expect(find.byType(ContextUsageRing), findsOneWidget);
          expect(
            tester.getSize(find.byType(ContextUsageButton)).width,
            kUsageTargetSize,
          );
        });
      }
    }
  });

  group('SPEC-40 — a four-option shape (no adapter emits this today)', () {
    // ACP passes agent-supplied `configOptions` through unchanged, so a
    // third-party agent could advertise this. With the ring given its own
    // trailing slot AND the chips yielding, it fits at every supported width —
    // the chip-yield was what closed the last 4.7px at 320pt.
    for (final width in [320.0, 375.0, 700.0]) {
      testWidgets('${width.toInt()}pt does not overflow', (tester) async {
        tester.view.physicalSize = Size(width, 812);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpFooter(tester, width, _manyShape);
        expect(
          tester.takeException(),
          isNull,
          reason: 'four options must not overflow at ${width.toInt()}pt',
        );
        // Every control is still on screen. Without this, "does not overflow"
        // would also be satisfied by rendering none of them — a row that fits
        // because it dropped the user's controls is not a fix.
        expect(find.byType(ModelConfigPill), findsOneWidget);
        expect(find.byType(ConfigOptionPill), findsNWidgets(2));
        // Criterion 4 covers every shape, not just the shipping ones: the ring
        // must never be the thing that gets squeezed to make room.
        expect(find.byType(ContextUsageRing), findsOneWidget);
        expect(
          tester.getSize(find.byType(ContextUsageButton)).width,
          kUsageTargetSize,
        );
      });
    }
  });

  group('SPEC-40 — the model label is readable at 375pt (criterion 3)', () {
    // The layout fix alone leaves the label unellipsized only because it is
    // granted more room; the provider prefix still eats most of it. These are
    // the assertions that shortening exists to satisfy, at the footer level —
    // a unit test of `shortModelLabel` cannot prove the pill renders whole.
    testWidgets('pi shows the whole model name on a current phone (393pt)', (
      tester,
    ) async {
      // 393pt is the iPhone 15/16/17 logical width — what almost every user has.
      tester.view.physicalSize = const Size(393, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final shortWanted = await _naturalWidth(tester, 'Claude Opus 4.6');
      final longWanted = await _naturalWidth(tester, _piModel);
      expect(shortWanted, lessThan(longWanted));

      await pumpFooter(tester, 393, _piShape);

      // The label is the model; the provider is gone from the pill.
      expect(find.text('Claude Opus 4.6'), findsOneWidget);
      expect(find.text(_piModel), findsNothing);
      expect(_ellipsized(tester, find.text('Claude Opus 4.6')), isFalse);
      expect(
        _paragraph(tester, find.text('Claude Opus 4.6')).size.width,
        closeTo(shortWanted, 1),
      );
    });

    testWidgets('375pt (SE/mini) clips pi by a hair, not by a provider', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final shortWanted = await _naturalWidth(tester, 'Claude Opus 4.6');
      await pumpFooter(tester, 375, _piShape);

      // A 15-character name wants 187.5pt and the row can grant 183pt even with
      // the chips hidden — the remaining 4.5pt would have to come from the
      // avatar, [+], send or the ring, none of which are this spec's to shrink.
      // So it reads `Claude Opus 4…`: the model, recognisably, where it used to
      // read `anthropic/Cl…` at 18% of the string.
      final shown = _paragraph(tester, find.text('Claude Opus 4.6')).size.width;
      expect(shown / shortWanted, greaterThan(0.95));
      expect(find.text(_piModel), findsNothing);
    });

    testWidgets('codex reads `gpt-5.6-codex` whole — the chip yields', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpFooter(tester, 375, _codexShape);

      // With both chips shown this read `gpt-5.6…` — about half the name.
      expect(find.text(_codexModel), findsOneWidget);
      expect(_ellipsized(tester, find.text(_codexModel)), isFalse);
      // BOTH chips are hidden to afford it — all-or-nothing, because a single
      // surviving chip reads as though the other option were unset. The picker
      // sheet still shows every value.
      expect(find.text('256k'), findsNothing);
      expect(find.byType(ThinkingSignal), findsNothing);
    });

    testWidgets('a wide pane keeps the chips — nothing is hidden for free', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(700, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpFooter(tester, 700, _codexShape);

      expect(_ellipsized(tester, find.text(_codexModel)), isFalse);
      expect(find.text('256k'), findsOneWidget);
      expect(find.byType(ThinkingSignal), findsOneWidget);
    });

    testWidgets('the full provider/name stays in the tooltip', (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpFooter(tester, 375, _piShape);

      final tooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.text('Claude Opus 4.6'),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, _piModel);
    });
  });

  group('SPEC-40 — a wide pane leaves every pill at its natural width', () {
    // Criterion 5, table-driven: at 700pt nothing is constrained, so every
    // shape's label must occupy exactly the width it wants.
    for (final (name, shape, label) in <(String, List<SessionConfigOption>, String)>[
      ('pi', _piShape, 'Claude Opus 4.6'),
      ('codex', _codexShape, _codexModel),
      ('modes-only', _modesShape, 'architect'),
    ]) {
      testWidgets('700pt · $name', (tester) async {
        tester.view.physicalSize = const Size(700, 812);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final wanted = await _naturalWidth(tester, label);
        await pumpFooter(tester, 700, shape);

        expect(_ellipsized(tester, find.text(label)), isFalse);
        expect(
          _paragraph(tester, find.text(label)).size.width,
          closeTo(wanted, 1),
        );
      });
    }

    testWidgets('four options stay legal at 700pt, however they share it', (
      tester,
    ) async {
      // Criterion 5 covers the shapes our adapters emit, all of which fit. Four
      // pills' natural widths together exceed even a 700pt row, so they share it
      // — D3's intended degradation, and the reason the guarantee is "no
      // overflow" rather than "never clipped".
      //
      // Deliberately NOT asserting that it *does* ellipsize: whether four pills
      // happen to cross the line at exactly 700pt depends on font metrics, and a
      // theme change flipping it would fail this test for no user-visible reason.
      // The invariant worth guarding is that the row stays legal.
      tester.view.physicalSize = const Size(700, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpFooter(tester, 700, _manyShape);

      expect(tester.takeException(), isNull);
      expect(find.byType(ContextUsageRing), findsOneWidget);
      // Same guard as above: sharing the row must not mean dropping controls.
      expect(find.byType(ModelConfigPill), findsOneWidget);
      expect(find.byType(ConfigOptionPill), findsNWidgets(2));
    });

    testWidgets('D4 — the pill row is not scrollable at any width', (
      tester,
    ) async {
      // Scrolling would "fix" a narrow row by pushing the ring off-screen, and
      // the ring exists to be glanceable without a tap (SPEC-37).
      tester.view.physicalSize = const Size(320, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpFooter(tester, 320, _manyShape);
      expect(
        find.ancestor(
          of: find.byType(ModelConfigPill),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
    });
  });

  group('SPEC-40 — the chip gate measures what will actually be rendered', () {
    testWidgets('unbounded constraints keep the chips', (tester) async {
      // A shrink-wrap measuring pass has no width to fit into, so hiding chips
      // there would drop them from layouts that have room to spare.
      final c = _container(_codexShape);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ComposerConfigOptions(sessionId: 's1'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('256k'), findsOneWidget);
      expect(_ellipsized(tester, find.text(_codexModel)), isFalse);
    });

    // Not covered by a widget test: the accessibility bold-text setting. `Text`
    // thickens glyphs for it and `_measure` merges the same weight, but the test
    // font (Ahem) has weight-invariant metrics, so a bold/non-bold pair flips at
    // the identical width (286pt, measured) and the test could not fail for the
    // right reason. The scaling case below does exercise the same code path.
    testWidgets('accessibility text scaling makes the chips yield sooner', (
      tester,
    ) async {
      // The gate measures with the ambient TextScaler. Measuring at 1.0 while
      // the label renders at 1.6 would keep the chips and clip the name — the
      // exact failure this feature exists to prevent, for the users least able
      // to absorb it.
      tester.view.physicalSize = const Size(700, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final c = _container(_codexShape);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(2.4),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 260,
                    child: ComposerConfigOptions(sessionId: 's1'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // At 2.4x the name alone needs more than the 260pt on offer, so the chips
      // must be gone. (Measuring at 1.0 would have kept them.)
      expect(find.text('256k'), findsNothing);
      expect(find.byType(ThinkingSignal), findsNothing);
    });
  });
}
