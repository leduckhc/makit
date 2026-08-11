import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/cli_installer.dart';
import 'package:makit/desktop/screens/providers.dart' show cliInstallerProvider;
import 'package:makit/desktop/settings/sections/general_section.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';

Future<void> _pump(
  WidgetTester tester, {
  required CliInstaller installer,
  StatusCenter? statusCenter,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cliInstallerProvider.overrideWithValue(installer),
        if (statusCenter != null)
          statusCenterProvider.overrideWithValue(statusCenter),
      ],
      child: const MaterialApp(home: Scaffold(body: GeneralSection())),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cli_install_general'));
  tearDown(() => tmp.deleteSync(recursive: true));

  CliInstaller installerWithBundle({required bool bundled}) {
    final path = '${tmp.path}/Resources/makit/makit';
    if (bundled) {
      File(path).createSync(recursive: true);
    }
    return CliInstaller(bundledCliPath: () => path, homeDir: () => tmp.path);
  }

  testWidgets('Install CLI is shown here and installs on tap', (tester) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    await _pump(
      tester,
      installer: installerWithBundle(bundled: true),
      statusCenter: center,
    );

    final button = find.widgetWithText(OutlinedButton, 'Install CLI');
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pump();
    await tester.pump();

    expect(File('${tmp.path}/.local/bin/makit').existsSync(), isTrue);
    expect(center.events.single.title, startsWith('Installed makit CLI'));
  });

  testWidgets('the Install button is hidden without a bundled CLI', (
    tester,
  ) async {
    await _pump(tester, installer: installerWithBundle(bundled: false));
    expect(find.widgetWithText(OutlinedButton, 'Install CLI'), findsNothing);
    // The row itself still explains why.
    expect(
      find.text('This build has no bundled CLI to install.'),
      findsOneWidget,
    );
  });
}
