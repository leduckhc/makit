import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots with test pairing and shows project/session snapshots', (
    tester,
  ) async {
    await launchMakit(tester);

    // AppBar title.
    expect(find.text('makit'), findsWidgets);
    // Session from the stub adapter — proves the WS snapshot hydrated.
    expect(find.text('new session'), findsOneWidget);
    // Paired + connected: the ConnectionChip hides itself on the happy path,
    // so the offline / reconnecting affordances must be absent.
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
    expect(find.byIcon(Icons.sync_problem_outlined), findsNothing);
  });
}
