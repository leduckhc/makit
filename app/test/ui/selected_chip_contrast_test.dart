import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/composer_selectors.dart';

/// The brand green (`kMakitAccent`) is a fill/dot/wash token. As small *label
/// text* it is ~1.7:1 on the light surface, so selected labels must read from
/// `colorScheme.primary`, which resolves to an AA-safe green per mode.
///
/// Guards the one place that used the raw constant for text.
const _boolOn = SessionConfigOption(
  id: 'websearch',
  name: 'web search',
  type: ConfigOptionType.boolean,
  currentValue: true,
);

Future<Color?> _selectedLabelColor(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ModelConfigPill(
          model: const SessionConfigOption(
            id: 'model',
            name: 'model',
            type: ConfigOptionType.select,
            currentValue: 'gpt-5',
          ),
          modelScoped: const [_boolOn],
          values: const {'websearch': true},
          agent: 'pi',
          onTap: () {},
        ),
      ),
    ),
  );
  await tester.pump();

  final label = find.text('web search');
  expect(
    label,
    findsOneWidget,
    reason: 'the selected boolean chip must render',
  );
  return tester.widget<Text>(label).style?.color;
}

void main() {
  testWidgets('a selected config chip uses primary, not the raw brand green', (
    tester,
  ) async {
    final color = await _selectedLabelColor(tester, makitLightTheme);

    expect(
      color,
      makitLightTheme.colorScheme.primary,
      reason: 'selected label text must read from the theme',
    );
    expect(
      color,
      isNot(kMakitAccent),
      reason: 'the brand green is ~1.7:1 on the light surface',
    );
  });

  testWidgets('dark mode still shows the brand green, via primary', (
    tester,
  ) async {
    final color = await _selectedLabelColor(tester, makitDarkTheme);

    // Dark `primary` *is* the brand green, so the vivid accent survives — it
    // just arrives through the theme instead of a hardcoded constant.
    expect(color, makitDarkTheme.colorScheme.primary);
    expect(color, kMakitAccent);
  });
}
