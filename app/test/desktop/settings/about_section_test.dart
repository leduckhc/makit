import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/sections/about_section.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(home: Scaffold(body: AboutSection())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders app identity, protocol version, and docs link', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Makit'), findsOneWidget);
    expect(find.text('Protocol version'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget); // protocolVersion == 1
    expect(find.text('Documentation & source'), findsOneWidget);
  });
}
