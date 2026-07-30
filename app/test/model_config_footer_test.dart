import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/composer_selectors.dart';

SessionConfigOption _select({
  required String id,
  required String name,
  String? category,
  required String currentValue,
  List<ConfigOptionValue> options = const [],
  List<ConfigOptionGroup> groups = const [],
}) => SessionConfigOption(
  id: id,
  name: name,
  category: category,
  type: ConfigOptionType.select,
  currentValue: currentValue,
  options: options,
  groups: groups,
);

SessionConfigOption _boolean({
  required String id,
  required String name,
  String? category,
  required bool currentValue,
}) => SessionConfigOption(
  id: id,
  name: name,
  category: category,
  type: ConfigOptionType.boolean,
  currentValue: currentValue,
);

const _model = SessionConfigOption(
  id: 'model',
  name: 'Model',
  category: 'model',
  type: ConfigOptionType.select,
  currentValue: 'gpt-5',
  options: [
    ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
    ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
  ],
);

Future<void> _pumpFooter(
  WidgetTester tester, {
  required List<SessionConfigOption> options,
  Map<String, Object> values = const {},
  VoidCallback? onOpenModelMenu,
  void Function(String id, Object value)? onPick,
  double width = 800,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: ModelConfigFooter(
            options: options,
            values: values,
            agent: 'zed',
            onPick: onPick ?? (_, _) {},
            onOpenModelMenu: onOpenModelMenu ?? () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('partitionConfigOptions', () {
    test('splits model / model-scoped / standalone by category', () {
      final reasoning = _select(
        id: 'reasoning',
        name: 'Reasoning',
        category: 'thought_level',
        currentValue: 'high',
      );
      final context = _select(
        id: 'ctx',
        name: 'Context',
        category: 'model_config',
        currentValue: '256k',
      );
      final mode = _select(
        id: 'mode',
        name: 'Mode',
        category: 'mode',
        currentValue: 'code',
      );
      final unknown = _select(
        id: 'x',
        name: 'X',
        category: 'weird',
        currentValue: 'a',
      );
      final underscore = _select(
        id: 'y',
        name: 'Y',
        category: '_internal',
        currentValue: 'b',
      );

      final p = partitionConfigOptions([
        _model,
        reasoning,
        context,
        mode,
        unknown,
        underscore,
      ]);

      expect(p.model, same(_model));
      expect(p.modelScoped, [reasoning, context]);
      expect(p.standalone, [mode, unknown, underscore]);
    });

    test('missing model category yields a null model', () {
      final mode = _select(
        id: 'mode',
        name: 'Mode',
        category: 'mode',
        currentValue: 'code',
      );
      final p = partitionConfigOptions([mode]);
      expect(p.model, isNull);
      expect(p.modelScoped, isEmpty);
      expect(p.standalone, [mode]);
    });
  });

  group('ModelConfigFooter — with a model option', () {
    testWidgets('model pill shows the active model name + read-only chips', (
      tester,
    ) async {
      await _pumpFooter(
        tester,
        options: [
          _model,
          _select(
            id: 'reasoning',
            name: 'Reasoning',
            category: 'thought_level',
            currentValue: 'high',
          ),
          _select(
            id: 'ctx',
            name: 'Context',
            category: 'model_config',
            currentValue: '256k',
            options: const [
              ConfigOptionValue(value: '256k', name: '256k'),
              ConfigOptionValue(value: '1M', name: '1M'),
            ],
          ),
          _boolean(
            id: 'fast',
            name: 'fast',
            category: 'model_config',
            currentValue: true,
          ),
        ],
      );

      expect(find.text('GPT-5'), findsOneWidget);
      // Reasoning renders as the signal-bar glyph (not a text label).
      expect(find.byType(ThinkingSignal), findsOneWidget);
      // model_config select chip shows the current value's display name.
      expect(find.text('256k'), findsOneWidget);
      // boolean chip shown only when true.
      expect(find.text('fast'), findsOneWidget);
    });

    testWidgets('a false boolean chip is hidden', (tester) async {
      await _pumpFooter(
        tester,
        options: [
          _model,
          _boolean(
            id: 'fast',
            name: 'fast',
            category: 'model_config',
            currentValue: false,
          ),
        ],
      );
      expect(find.text('fast'), findsNothing);
    });

    testWidgets('mode stays a separate pill after the model pill', (
      tester,
    ) async {
      await _pumpFooter(
        tester,
        options: [
          _model,
          _select(
            id: 'mode',
            name: 'Mode',
            category: 'mode',
            currentValue: 'code',
            options: const [ConfigOptionValue(value: 'code', name: 'Code')],
          ),
        ],
      );
      final model = tester.getTopLeft(find.text('GPT-5'));
      final mode = tester.getTopLeft(find.text('Code'));
      expect(model.dx, lessThan(mode.dx));
    });

    testWidgets('tapping the model pill opens the menu', (tester) async {
      var opened = 0;
      await _pumpFooter(
        tester,
        options: [_model],
        onOpenModelMenu: () => opened++,
      );
      await tester.tap(find.text('GPT-5'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('renders without overflow in a narrow pane', (tester) async {
      // A realistic worst case: a thinking (thought_level) chip, a long
      // model_config value, and an on boolean chip all crammed beside the
      // model name in a ~160px pane. Before the Flexible-chip fix the fixed
      // chips pushed the Row past its box and RenderFlex overflowed.
      await _pumpFooter(
        tester,
        width: 160,
        options: [
          _model,
          _select(
            id: 'reasoning',
            name: 'Reasoning',
            category: 'thought_level',
            currentValue: 'high',
          ),
          _select(
            id: 'ctx',
            name: 'Context',
            category: 'model_config',
            currentValue: '1M',
            options: const [
              ConfigOptionValue(value: '1M', name: '1,000,000 tokens'),
            ],
          ),
          _boolean(
            id: 'fast',
            name: 'fast',
            category: 'model_config',
            currentValue: true,
          ),
        ],
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ModelConfigFooter — no model option (back-compat)', () {
    testWidgets('renders the flat ConfigOptionPickRow unchanged', (
      tester,
    ) async {
      await _pumpFooter(
        tester,
        options: [
          _select(
            id: 'mode',
            name: 'Mode',
            category: 'mode',
            currentValue: 'code',
            options: const [ConfigOptionValue(value: 'code', name: 'Code')],
          ),
        ],
      );
      expect(find.byType(ConfigOptionPickRow), findsOneWidget);
      expect(find.byType(ModelConfigPill), findsNothing);
      expect(find.text('Code'), findsOneWidget);
    });
  });
}
