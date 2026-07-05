// Widget test for the CLI-missing banner's actionable recovery.
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/desktop/desktop_app.dart';

void main() {
  testWidgets(
    'CliMissingBanner shows the message + action and fires onInstall',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CliMissingBanner(onInstall: () => taps++)),
        ),
      );

      expect(find.textContaining('pino CLI was not found'), findsOneWidget);
      expect(find.text('Copy install command'), findsOneWidget);

      await tester.tap(find.text('Copy install command'));
      expect(taps, 1);
    },
  );

  test('pinoInstallCommand is the documented curl installer', () {
    expect(pinoInstallCommand, startsWith('curl'));
    expect(pinoInstallCommand, contains('install.sh'));
  });
}
