import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/composer_selectors.dart' show ThinkingSignal;
import 'package:makit/ui/composer/model_picker_menu.dart';

const _modelOption = SessionConfigOption(
  id: 'model',
  name: 'Model',
  category: 'model',
  type: ConfigOptionType.select,
  currentValue: 'gpt-5',
  options: [
    ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
    ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
    ConfigOptionValue(value: 'gemini', name: 'Gemini 2.5 Pro'),
  ],
);

const _reasoning = SessionConfigOption(
  id: 'reasoning',
  name: 'Reasoning',
  category: 'thought_level',
  type: ConfigOptionType.select,
  currentValue: 'high',
  options: [
    ConfigOptionValue(value: 'low', name: 'low'),
    ConfigOptionValue(value: 'high', name: 'high'),
  ],
);

const _context = SessionConfigOption(
  id: 'ctx',
  name: 'Context',
  category: 'model_config',
  type: ConfigOptionType.select,
  currentValue: '256k',
  options: [
    ConfigOptionValue(value: '128k', name: '128k'),
    ConfigOptionValue(value: '256k', name: '256k'),
  ],
);

const _fast = SessionConfigOption(
  id: 'fast',
  name: 'Fast',
  category: 'model_config',
  type: ConfigOptionType.boolean,
  currentValue: true,
);

Future<void> _pumpMenu(
  WidgetTester tester, {
  String activeValue = 'gpt-5',
  List<String> recent = const ['gpt-5', 'opus'],
  List<SessionConfigOption> modelScoped = const [_reasoning, _context, _fast],
  Map<String, Object> values = const {
    'reasoning': 'high',
    'ctx': '256k',
    'fast': true,
  },
  void Function(String value)? onSelectModel,
  void Function(String id, Object value)? onPickOption,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ModelPickerMenu(
          modelOption: _modelOption,
          activeValue: activeValue,
          recent: recent,
          modelScoped: modelScoped,
          values: values,
          agent: 'zed',
          onSelectModel: onSelectModel ?? (_) {},
          onPickOption: onPickOption ?? (_, _) {},
        ),
      ),
    ),
  );
}

void main() {
  group('ModelPickerMenu — recent state', () {
    testWidgets('empty query lists recent models with the active one marked', (
      tester,
    ) async {
      await _pumpMenu(tester);
      expect(find.text('GPT-5'), findsOneWidget);
      expect(find.text('Claude Opus'), findsOneWidget);
      // Only the active model exposes the flyout caret.
      expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
      // The active model is checked.
      expect(find.byIcon(kModelActiveCheckIcon), findsOneWidget);
    });

    testWidgets('the active model is always shown even if not in recent', (
      tester,
    ) async {
      await _pumpMenu(tester, activeValue: 'gpt-5', recent: const ['opus']);
      expect(find.text('GPT-5'), findsOneWidget);
      expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
    });

    testWidgets('empty query shows All models section after Recent', (
      tester,
    ) async {
      // The recent list is [gpt-5, opus]; the catalog has 3 (gpt-5, opus,
      // gemini). After Recent header + 2 rows, there should be an "All models"
      // header showing the count of remaining (1 = gemini).
      await _pumpMenu(tester);
      expect(find.text('RECENT'), findsOneWidget);
      expect(find.text('ALL MODELS · 1'), findsOneWidget);
      expect(find.text('Gemini 2.5 Pro'), findsOneWidget);
    });

    testWidgets(
      'the active model stays reachable even when absent from the catalog',
      (tester) async {
        // The catalog no longer lists the active value; it must still render
        // (raw-value fallback) and expose its flyout caret.
        await _pumpMenu(
          tester,
          activeValue: 'retired-model',
          recent: const ['opus'],
        );
        expect(find.text('retired-model'), findsOneWidget);
        expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
        expect(find.byIcon(kModelActiveCheckIcon), findsOneWidget);
      },
    );

    testWidgets('tapping a non-active recent row selects it exactly once', (
      tester,
    ) async {
      final picks = <String>[];
      await _pumpMenu(tester, onSelectModel: picks.add);
      await tester.tap(find.text('Claude Opus'));
      await tester.pump();
      expect(picks, ['opus']);
    });

    testWidgets(
      're-emitting a new active value moves the caret to the new row',
      (tester) async {
        await _pumpMenu(tester);
        expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
        // Agent re-emits with opus active.
        await _pumpMenu(tester, activeValue: 'opus');
        // The caret is on the opus row now — still exactly one caret.
        expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
        final caret = tester.getTopLeft(find.byIcon(kModelFlyoutCaretIcon));
        final opus = tester.getTopLeft(find.text('Claude Opus'));
        final gpt = tester.getTopLeft(find.text('GPT-5'));
        // The caret sits on the opus row (below the gpt-5 row).
        expect((caret.dy - opus.dy).abs(), lessThan((caret.dy - gpt.dy).abs()));
      },
    );

    testWidgets(
      'selecting a non-active row fires once, then the re-emitted active row '
      'reveals its flyout in place',
      (tester) async {
        final picks = <String>[];
        // Start with gpt-5 active; opus is a non-active recent row.
        await _pumpMenu(tester, onSelectModel: picks.add);
        // The active row (gpt-5) is the only expandable one to begin with.
        expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
        expect(find.byIcon(kModelActiveCheckIcon), findsOneWidget);

        // Tapping the non-active opus row selects it exactly once (no pop, no
        // active flip yet — the host owns activeValue).
        await tester.tap(find.text('Claude Opus'));
        await tester.pump();
        expect(picks, ['opus']);

        // The host re-emits with opus now active (replacement props).
        await _pumpMenu(tester, activeValue: 'opus', onSelectModel: picks.add);

        // Exactly one row is expandable/active, and it is the opus row: its
        // `✓`+`›` are revealed in place.
        expect(find.byIcon(kModelActiveCheckIcon), findsOneWidget);
        expect(find.byIcon(kModelFlyoutCaretIcon), findsOneWidget);
        final check = tester.getTopLeft(find.byIcon(kModelActiveCheckIcon));
        final opus = tester.getTopLeft(find.text('Claude Opus'));
        final gpt = tester.getTopLeft(find.text('GPT-5'));
        expect((check.dy - opus.dy).abs(), lessThan((check.dy - gpt.dy).abs()));
        // No extra selection fired from the re-emit.
        expect(picks, ['opus']);
      },
    );
  });

  group('ModelPickerMenu — search state', () {
    testWidgets('typing filters the full catalog, selection-only', (
      tester,
    ) async {
      final picks = <String>[];
      await _pumpMenu(tester, onSelectModel: picks.add);
      await tester.enterText(find.byType(TextField), 'gemini');
      await tester.pump();
      expect(find.text('Gemini 2.5 Pro'), findsOneWidget);
      expect(find.text('GPT-5'), findsNothing);
      // No flyout caret in results.
      expect(find.byIcon(kModelFlyoutCaretIcon), findsNothing);
      await tester.tap(find.text('Gemini 2.5 Pro'));
      await tester.pump();
      expect(picks, ['gemini']);
    });

    testWidgets('selecting the already-active model is a no-op', (
      tester,
    ) async {
      final picks = <String>[];
      await _pumpMenu(tester, onSelectModel: picks.add);
      await tester.enterText(find.byType(TextField), 'GPT');
      await tester.pump();
      // The active model is marked in the results with a check (not silent).
      expect(find.byIcon(kModelActiveCheckIcon), findsOneWidget);
      await tester.tap(find.text('GPT-5'));
      await tester.pump();
      expect(picks, isEmpty);
    });
  });

  group('ModelPickerMenu — flyout', () {
    testWidgets('opening the active row shows the model-scoped segments', (
      tester,
    ) async {
      await _pumpMenu(tester);
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();

      // Segment headers + values.
      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.text('Context'), findsOneWidget);
      expect(find.byType(ThinkingSignal), findsWidgets);
      // Select values are stacked; boolean is a toggle.
      expect(find.text('128k'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets('picking a value dispatches onPickOption', (tester) async {
      final picks = <({String id, Object value})>[];
      await _pumpMenu(
        tester,
        onPickOption: (id, value) => picks.add((id: id, value: value)),
      );
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('128k'));
      await tester.pump();
      expect(picks, [(id: 'ctx', value: '128k')]);
    });

    testWidgets('toggling a boolean dispatches the negated value', (
      tester,
    ) async {
      final picks = <({String id, Object value})>[];
      await _pumpMenu(
        tester,
        onPickOption: (id, value) => picks.add((id: id, value: value)),
      );
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(picks, [(id: 'fast', value: false)]);
    });

    testWidgets('the back affordance returns to the model list', (
      tester,
    ) async {
      await _pumpMenu(tester);
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      expect(find.text('Reasoning'), findsOneWidget);
      await tester.tap(find.byIcon(kModelFlyoutBackIcon));
      await tester.pumpAndSettle();
      expect(find.text('Reasoning'), findsNothing);
      expect(find.text('Claude Opus'), findsOneWidget);
    });
  });

  group('ModelFlyoutColumn — resilience', () {
    testWidgets('an option disappearing from the list does not crash', (
      tester,
    ) async {
      Widget column(List<SessionConfigOption> options) => MaterialApp(
        home: Scaffold(
          body: ModelFlyoutColumn(
            options: options,
            values: const {'reasoning': 'high', 'ctx': '256k'},
            onPickOption: (_, _) {},
          ),
        ),
      );
      await tester.pumpWidget(column(const [_reasoning, _context]));
      expect(find.text('Context'), findsOneWidget);
      // The agent re-emits a shorter list while the flyout is open.
      await tester.pumpWidget(column(const [_reasoning]));
      expect(tester.takeException(), isNull);
      expect(find.text('Context'), findsNothing);
      expect(find.text('Reasoning'), findsOneWidget);
    });

    testWidgets('strips the option-name prefix and puts the tick trailing', (
      tester,
    ) async {
      const prefixed = SessionConfigOption(
        id: 'reasoning',
        name: 'Thinking',
        category: 'thought_level',
        type: ConfigOptionType.select,
        currentValue: 'medium',
        options: [
          ConfigOptionValue(value: 'off', name: 'Thinking: off'),
          ConfigOptionValue(value: 'medium', name: 'Thinking: medium'),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ModelFlyoutColumn(
              options: [prefixed],
              values: {'reasoning': 'medium'},
              onPickOption: _noop,
            ),
          ),
        ),
      );
      // The redundant "Thinking: " prefix is stripped from the value rows.
      expect(find.text('off'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.textContaining('Thinking: '), findsNothing);
      // The active tick sits to the right of its row's label.
      final tick = tester.getCenter(find.byIcon(kModelActiveCheckIcon));
      final label = tester.getCenter(find.text('medium'));
      expect(tick.dx, greaterThan(label.dx));
    });
  });
}

void _noop(String id, Object value) {}
